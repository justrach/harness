//! Folds a run's events into a [`RunSummary`]. It works line by line, so the
//! same code serves a finished trace and one graff is still writing.

use std::collections::BTreeMap;
use std::fs::File;
use std::io::{self, BufRead, BufReader};
use std::path::Path;

use serde::Serialize;

use crate::delegation::{self, ChildRun, Delegation};
use crate::event::{Event, EventKind, Stamp, SubagentRun, parse_line};

/// graff's root agent: `main` in the TUI, ACP and `-p`; `repl` in scripted
/// `graff repl`; `root` in a few session paths.
const ROOT_LABELS: &[&str] = &["main", "repl", "root"];
/// graff's own side agents (titles, recaps, judges, side questions,
/// pre-compaction notes, reviews). They are not sub-agents.
const HELPER_LABELS: &[&str] = &[
    "title",
    "recap",
    "judge",
    "update",
    "btw",
    "note",
    "reflect",
    "publication-review",
    "?",
];

/// Whether graff offers `jev_effort` on this route, mirroring graff's own
/// rule. graff also needs a Codegraff login, which traces do not record.
pub fn jev_eligible(provider: &str, model: &str) -> bool {
    let gpt6 = model == "gpt-6" || model.starts_with("gpt-6-") || model.starts_with("gpt-6.");
    let mimo = model == "mimo-v2.6" || model.starts_with("mimo-v2.6-");
    match provider {
        "codex" | "openai" => gpt6,
        "xiaomi" => mimo,
        "codegraff" => gpt6 || mimo,
        _ => false,
    }
}

#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct RunSummary {
    pub run_id: String,
    pub pid: Option<u32>,
    /// graff's version, from the turn recipe.
    pub version: String,
    pub provider: String,
    /// The root agent's last model; `models` lists every switch.
    pub model: String,
    pub models: Vec<String>,
    /// The root agent's effort over the run, repeats collapsed (`medium`, `high`).
    pub efforts: Vec<String>,
    /// Last event time: how long the run has been going.
    pub span_ms: u64,
    pub turns: u64,
    pub turns_ok: u64,
    pub interrupts: u64,
    pub requests: Requests,
    pub tools: Tools,
    pub tokens: Tokens,
    /// cache_read / input over every request with usage; `None` without usage lines.
    pub cache_hit: Option<f64>,
    /// From the turn outcomes, so it covers finished turns only.
    pub cost_usd: f64,
    pub ttft_ms: Percentiles,
    pub request_ms: Percentiles,
    pub reliability: Reliability,
    pub jev: Jev,
    pub delegation: Delegation,
    pub startup_ms: Option<u64>,
    /// ACP session ids this run served (from `acp_prompt`).
    pub acp_sessions: Vec<String>,
    pub lines: u64,
    pub unreadable_lines: u64,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct Requests {
    pub root: u64,
    pub helpers: u64,
    pub children: u64,
    pub errors: u64,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct Tools {
    pub calls: u64,
    pub errors: u64,
    /// Calls made by sub-agents and helpers.
    pub from_children: u64,
    /// Most-called first.
    pub by_name: Vec<ToolStat>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct ToolStat {
    pub name: String,
    pub calls: u64,
    pub errors: u64,
    pub ms: u64,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize)]
pub struct Tokens {
    pub input: u64,
    pub cache_read: u64,
    pub cache_write: u64,
    pub output: u64,
    pub reasoning: u64,
    /// Requests whose cached prefix changed.
    pub prefix_busts: u64,
}

impl Tokens {
    pub fn add(&mut self, other: &Tokens) {
        self.input += other.input;
        self.cache_read += other.cache_read;
        self.cache_write += other.cache_write;
        self.output += other.output;
        self.reasoning += other.reasoning;
        self.prefix_busts += other.prefix_busts;
    }

    pub fn cache_hit(&self) -> Option<f64> {
        (self.input > 0).then(|| self.cache_read as f64 / self.input as f64)
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize)]
pub struct Percentiles {
    pub n: u64,
    pub p50: Option<u64>,
    pub p90: Option<u64>,
}

impl Percentiles {
    /// Nearest-rank percentiles.
    pub fn of(samples: &[u64]) -> Self {
        let mut sorted = samples.to_vec();
        sorted.sort_unstable();
        let rank = |p: f64| {
            let n = sorted.len();
            (n > 0).then(|| sorted[((p * n as f64).ceil() as usize).clamp(1, n) - 1])
        };
        Percentiles {
            n: sorted.len() as u64,
            p50: rank(0.5),
            p90: rank(0.9),
        }
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize)]
pub struct Reliability {
    pub retries: u64,
    pub stream_retries: u64,
    pub stall_reconnects: u64,
    pub stalls: u64,
    pub ws_errors: u64,
    pub context_trims: u64,
    pub compactions: u64,
    pub budget_stops: u64,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize)]
pub struct Jev {
    /// The root route is one graff offers `jev_effort` on (see [`jev_eligible`]).
    pub eligible_model: bool,
    pub calls: u64,
    pub child_calls: u64,
    pub errors: u64,
    pub ms: u64,
}

#[derive(Debug, Default)]
struct Label {
    requests: u64,
    first_start: Option<u64>,
    last_end: u64,
    from_sub: Option<bool>,
}

/// Incremental reader for one run.
#[derive(Debug, Default)]
pub struct Observer {
    stamp: Stamp,
    version: String,
    provider: String,
    model: String,
    models: Vec<String>,
    efforts: Vec<String>,
    pub(crate) turn_efforts: Vec<String>,
    last_t: u64,
    turns: u64,
    turns_ok: u64,
    interrupts: u64,
    cost_microusd: u64,
    labels: BTreeMap<String, Label>,
    request_errors: u64,
    root_spans: Vec<(u64, u64)>,
    pub(crate) root_request_ms: Vec<u64>,
    pub(crate) root_ttft_ms: Vec<u64>,
    tools: BTreeMap<String, ToolStat>,
    tool_calls: u64,
    tool_errors: u64,
    child_tool_calls: u64,
    tokens: Tokens,
    reliability: Reliability,
    jev: Jev,
    spawns: Vec<u64>,
    parent_wait_ms: u64,
    children: Vec<(u64, SubagentRun)>,
    startup_ms: Option<u64>,
    acp_sessions: Vec<String>,
    lines: u64,
    unreadable_lines: u64,
}

impl Observer {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn pid(&self) -> Option<u32> {
        self.stamp.pid
    }

    /// Parses one trace line and folds it in. Returns the event for live display.
    pub fn push_line(&mut self, line: &str) -> Option<Event> {
        if line.trim().is_empty() {
            return None;
        }
        self.lines += 1;
        let Some((stamp, event)) = parse_line(line) else {
            self.unreadable_lines += 1;
            return None;
        };
        if self.stamp.run_id.is_none() && stamp.run_id.is_some() {
            self.stamp = stamp;
        }
        self.push(&event);
        Some(event)
    }

    pub fn push(&mut self, event: &Event) {
        let t = event.t_ms.unwrap_or(self.last_t);
        self.last_t = self.last_t.max(t);
        match &event.kind {
            EventKind::Api {
                agent,
                model,
                ms,
                is_error,
                ..
            } => {
                let start = t.saturating_sub(*ms);
                let root = self.is_root(agent);
                let label = self.labels.entry(agent.clone()).or_default();
                label.requests += 1;
                label.first_start = Some(label.first_start.map_or(start, |s| s.min(start)));
                label.last_end = label.last_end.max(t);
                self.request_errors += u64::from(*is_error);
                if root {
                    self.root_spans.push((start, t));
                    if !is_error {
                        self.root_request_ms.push(*ms);
                    }
                    if !model.is_empty() && self.models.last() != Some(model) {
                        self.models.push(model.clone());
                    }
                }
            }
            EventKind::Usage(u) => {
                self.tokens.add(&Tokens {
                    input: u.input,
                    cache_read: u.cache_read,
                    cache_write: u.cache_write,
                    output: u.output,
                    reasoning: u.reasoning,
                    prefix_busts: u64::from(u.prefix_bust),
                });
                self.labels.entry(u.agent.clone()).or_default().from_sub = Some(u.from_sub);
                if !u.from_sub {
                    if self.provider.is_empty() {
                        self.provider = u.provider.clone();
                    }
                    self.jev.eligible_model |= jev_eligible(&u.provider, &u.model);
                }
            }
            EventKind::Tool {
                name,
                ms,
                is_error,
                from_sub,
            } => {
                self.tool_calls += 1;
                self.tool_errors += u64::from(*is_error);
                self.child_tool_calls += u64::from(*from_sub);
                let stat = self.tools.entry(name.clone()).or_insert_with(|| ToolStat {
                    name: name.clone(),
                    ..Default::default()
                });
                stat.calls += 1;
                stat.errors += u64::from(*is_error);
                stat.ms += ms;
                match name.as_str() {
                    "jev_effort" => {
                        self.jev.calls += 1;
                        self.jev.child_calls += u64::from(*from_sub);
                        self.jev.errors += u64::from(*is_error);
                        self.jev.ms += ms;
                    }
                    "subagent" if !from_sub => self.spawns.push(t),
                    "agent_output" if !from_sub => self.parent_wait_ms += ms,
                    _ => {}
                }
            }
            EventKind::FirstToken {
                agent,
                from_sub,
                ms,
            } => {
                self.labels.entry(agent.clone()).or_default().from_sub = Some(*from_sub);
                if !from_sub {
                    self.root_ttft_ms.push(*ms);
                }
            }
            EventKind::Recipe {
                provider,
                model,
                effort,
                version,
            } => {
                set_if_some(&mut self.provider, provider);
                set_if_some(&mut self.model, model);
                set_if_some(&mut self.version, version);
                self.jev.eligible_model |= jev_eligible(provider, model);
                push_collapsed(&mut self.efforts, effort);
            }
            EventKind::Turn(o) => {
                self.turns += 1;
                self.turns_ok += u64::from(o.success);
                self.cost_microusd += o.cost_microusd;
                if self.provider.is_empty() {
                    set_if_some(&mut self.provider, &o.provider);
                }
                if self.model.is_empty() {
                    set_if_some(&mut self.model, &o.model);
                }
                self.jev.eligible_model |= jev_eligible(&o.provider, &o.model);
                self.turn_efforts.push(o.effort.clone());
                push_collapsed(&mut self.efforts, &o.effort);
            }
            EventKind::Startup { startup_ms } => {
                self.startup_ms = Some(self.startup_ms.unwrap_or(0).max(*startup_ms));
            }
            EventKind::Subagent(run) => self.children.push((t, run.clone())),
            EventKind::Note { kind, detail } => self.note(kind, detail),
            EventKind::Other { kind } => {
                if kind == "compact_cut" {
                    self.reliability.compactions += 1;
                }
            }
        }
    }

    fn note(&mut self, kind: &str, detail: &str) {
        let r = &mut self.reliability;
        match kind {
            "retry" => r.retries += 1,
            "stream_retry" => r.stream_retries += 1,
            "stall_budget" => r.stall_reconnects += 1,
            "stream_stall" => r.stalls += 1,
            "ws_api_error" => r.ws_errors += 1,
            "context" => r.context_trims += 1,
            "budget" => r.budget_stops += 1,
            "turn" if detail.starts_with("interrupted") => self.interrupts += 1,
            "acp_prompt" if !self.acp_sessions.iter().any(|s| s == detail) => {
                self.acp_sessions.push(detail.to_string())
            }
            _ => {}
        }
    }

    fn is_root(&self, label: &str) -> bool {
        ROOT_LABELS.contains(&label)
            || self.labels.get(label).and_then(|l| l.from_sub) == Some(false)
    }

    fn is_child(&self, label: &str) -> bool {
        !self.is_root(label) && !HELPER_LABELS.contains(&label)
    }

    /// A run that never made a request or a tool call (`graff --version`, a
    /// process that exited during startup).
    pub fn is_empty(&self) -> bool {
        self.labels.is_empty() && self.tool_calls == 0 && self.turns == 0
    }

    pub fn summary(&self) -> RunSummary {
        let mut requests = Requests {
            errors: self.request_errors,
            ..Default::default()
        };
        for (name, label) in &self.labels {
            if self.is_root(name) {
                requests.root += label.requests;
            } else if self.is_child(name) {
                requests.children += label.requests;
            } else {
                requests.helpers += label.requests;
            }
        }
        let mut by_name: Vec<ToolStat> = self.tools.values().cloned().collect();
        by_name.sort_by(|a, b| b.calls.cmp(&a.calls).then_with(|| a.name.cmp(&b.name)));
        RunSummary {
            run_id: self.stamp.run_id.clone().unwrap_or_default(),
            pid: self.stamp.pid,
            version: self.version.clone(),
            provider: self.provider.clone(),
            model: self
                .models
                .last()
                .cloned()
                .unwrap_or_else(|| self.model.clone()),
            models: self.models.clone(),
            efforts: self.efforts.clone(),
            span_ms: self.last_t,
            turns: self.turns,
            turns_ok: self.turns_ok,
            interrupts: self.interrupts,
            requests,
            tools: Tools {
                calls: self.tool_calls,
                errors: self.tool_errors,
                from_children: self.child_tool_calls,
                by_name,
            },
            tokens: self.tokens,
            cache_hit: self.tokens.cache_hit(),
            cost_usd: self.cost_microusd as f64 / 1_000_000.0,
            ttft_ms: Percentiles::of(&self.root_ttft_ms),
            request_ms: Percentiles::of(&self.root_request_ms),
            reliability: self.reliability,
            jev: self.jev,
            delegation: delegation::split(
                &self.spawns,
                &self.root_spans,
                self.child_runs(),
                self.parent_wait_ms,
            ),
            startup_ms: self.startup_ms,
            acp_sessions: self.acp_sessions.clone(),
            lines: self.lines,
            unreadable_lines: self.unreadable_lines,
        }
    }

    /// graff's per-child lines when the trace has them, else each child label's requests.
    fn child_runs(&self) -> Vec<ChildRun> {
        if !self.children.is_empty() {
            return self
                .children
                .iter()
                .map(|(t, run)| ChildRun {
                    label: run.label.clone(),
                    start_ms: t.saturating_sub(run.ms),
                    end_ms: *t,
                    requests: self.labels.get(&run.label).map_or(0, |l| l.requests),
                    ok: Some(run.ok),
                    tools: Some(run.tools),
                    effort: Some(run.effort.clone()),
                })
                .collect();
        }
        let mut runs: Vec<ChildRun> = self
            .labels
            .iter()
            .filter(|(name, label)| self.is_child(name) && label.requests > 0)
            .map(|(name, label)| ChildRun {
                label: name.clone(),
                start_ms: label.first_start.unwrap_or(0),
                end_ms: label.last_end,
                requests: label.requests,
                ..Default::default()
            })
            .collect();
        runs.sort_by_key(|c| c.start_ms);
        runs
    }
}

fn set_if_some(slot: &mut String, value: &str) {
    if !value.is_empty() {
        *slot = value.to_string();
    }
}

fn push_collapsed(timeline: &mut Vec<String>, value: &str) {
    if !value.is_empty() && timeline.last().map(String::as_str) != Some(value) {
        timeline.push(value.to_string());
    }
}

/// Reads a whole trace file. A last line graff is still writing is skipped.
pub fn summarize(path: &Path) -> io::Result<RunSummary> {
    Ok(observe_file(path)?.summary())
}

pub(crate) fn observe_file(path: &Path) -> io::Result<Observer> {
    let mut observer = Observer::new();
    let mut reader = BufReader::new(File::open(path)?);
    let mut line = Vec::new();
    loop {
        line.clear();
        if reader.read_until(b'\n', &mut line)? == 0 {
            break;
        }
        observer.push_line(&String::from_utf8_lossy(&line));
    }
    Ok(observer)
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    /// A synthetic run: two root turns, a Jev call by the root and one by a
    /// child, two children with per-child lines, one helper title request.
    pub(crate) const RUN: &str = r#"
{"run_id":"r1","pid":7,"session_id":"s","t":0,"ev":"startup_phase","phase":"ready","phase_ms":5,"startup_ms":380}
{"run_id":"r1","pid":7,"session_id":"s","t":10,"ev":"recipe","provider":"codex","model":"gpt-6-sol","effort":"medium","harness_version":"9.9.9","task_class":"general"}
{"run_id":"r1","pid":7,"session_id":"s","t":2000,"ev":"first_token","turn":1,"agent":"main","model":"gpt-6-sol","from_sub":false,"ms":1500}
{"run_id":"r1","pid":7,"session_id":"s","t":3000,"ev":"api","turn":1,"agent":"main","model":"gpt-6-sol","ms":2900,"req_bytes":1,"resp_bytes":1,"context_tokens":1000,"cache_read_tokens":0,"is_error":false}
{"run_id":"r1","pid":7,"session_id":"s","t":3001,"ev":"usage","agent":"main","from_sub":false,"provider":"codex","model":"gpt-6-sol","input_tokens":1000,"cache_read_tokens":0,"cache_write_tokens":0,"output_tokens":50,"reasoning_tokens":20,"prefix_bust":null}
{"run_id":"r1","pid":7,"session_id":"s","t":3600,"ev":"tool","turn":1,"call_id":1,"name":"jev_effort","ms":550,"result_bytes":60,"is_error":false,"from_sub":false}
{"run_id":"r1","pid":7,"session_id":"s","t":4000,"ev":"first_token","turn":1,"agent":"title","model":"gpt-6-sol","from_sub":true,"ms":300}
{"run_id":"r1","pid":7,"session_id":"s","t":4100,"ev":"api","turn":1,"agent":"title","model":"gpt-6-sol","ms":400,"req_bytes":1,"resp_bytes":1,"context_tokens":10,"cache_read_tokens":0,"is_error":false}
{"run_id":"r1","pid":7,"session_id":"s","t":7000,"ev":"api","turn":1,"agent":"main","model":"gpt-6-sol","ms":3000,"req_bytes":1,"resp_bytes":1,"context_tokens":2000,"cache_read_tokens":900,"is_error":false}
{"run_id":"r1","pid":7,"session_id":"s","t":7001,"ev":"usage","agent":"main","from_sub":false,"provider":"codex","model":"gpt-6-sol","input_tokens":2000,"cache_read_tokens":900,"cache_write_tokens":0,"output_tokens":70,"reasoning_tokens":30,"prefix_bust":"tools"}
{"run_id":"r1","pid":7,"session_id":"s","t":7100,"ev":"tool","turn":1,"call_id":2,"name":"subagent","ms":40,"result_bytes":60,"is_error":false,"from_sub":false}
{"run_id":"r1","pid":7,"session_id":"s","t":7200,"ev":"tool","turn":1,"call_id":3,"name":"subagent","ms":40,"result_bytes":60,"is_error":false,"from_sub":false}
{"run_id":"r1","pid":7,"session_id":"s","t":9000,"ev":"first_token","turn":1,"agent":"Fix parser","model":"gpt-6-sol","from_sub":true,"ms":800}
{"run_id":"r1","pid":7,"session_id":"s","t":9500,"ev":"api","turn":1,"agent":"Fix parser","model":"gpt-6-sol","ms":2000,"req_bytes":1,"resp_bytes":1,"context_tokens":900,"cache_read_tokens":0,"is_error":false}
{"run_id":"r1","pid":7,"session_id":"s","t":9600,"ev":"tool","turn":1,"call_id":4,"name":"bash","ms":100,"result_bytes":60,"is_error":true,"from_sub":true}
{"run_id":"r1","pid":7,"session_id":"s","t":9700,"ev":"tool","turn":1,"call_id":5,"name":"jev_effort","ms":500,"result_bytes":60,"is_error":false,"from_sub":true}
{"run_id":"r1","pid":7,"session_id":"s","t":17200,"ev":"subagent","detail":"sa-1 ok label=Fix parser ms=10000 tools=2 context=900 cached=0 effort=high"}
{"run_id":"r1","pid":7,"session_id":"s","t":19200,"ev":"subagent","detail":"sa-2 failed label=Fix lexer ms=12000 tools=5 context=800 cached=0 effort=medium"}
{"run_id":"r1","pid":7,"session_id":"s","t":19300,"ev":"tool","turn":1,"call_id":6,"name":"agent_output","ms":12000,"result_bytes":60,"is_error":false,"from_sub":false}
{"run_id":"r1","pid":7,"session_id":"s","t":22000,"ev":"api","turn":1,"agent":"main","model":"gpt-6-sol","ms":2500,"req_bytes":1,"resp_bytes":1,"context_tokens":2500,"cache_read_tokens":2000,"is_error":false}
{"run_id":"r1","pid":7,"session_id":"s","t":22100,"ev":"retry","detail":"server error (5xx) [main]"}
{"run_id":"r1","pid":7,"session_id":"s","t":22500,"ev":"recipe_outcome","provider":"codex","model":"gpt-6-sol","effort":"high","success":true,"latency_ms":22000,"model_calls":3,"tool_calls":5,"tool_errors":0,"cost_microusd":41000}
{"run_id":"r1","pid":7,"session_id":"s","t":30000,"ev":"turn","detail":"interrupted source=esc_key"}
{"run_id":"r1","pid":7,"session_id":"s","t":30100,"ev":"acp_prompt","detail":"session-1"}
{"ev":"compact_cut","boundary":4,"preserved_images":0,"unresolved":false}
{"run_id":"r1","pid":7,"session_id":"s","t":31000,"ev":"recipe_outcome","provider":"codex","model":"gpt-6-sol","effort":"high","success":false,"latency_ms":1000,"model_calls":0,"tool_calls":0,"tool_errors":0,"cost_microusd":1000}
{"run_id":"r1","pid":7,"session_id":"s","t":31500,"ev":"tool","turn":2,"name":"read_fi
"#;

    fn observe(text: &str) -> Observer {
        let mut observer = Observer::new();
        for line in text.lines() {
            observer.push_line(line);
        }
        observer
    }

    #[test]
    fn a_run_with_children_jev_and_a_helper() {
        let s = observe(RUN).summary();
        assert_eq!(
            (s.run_id.as_str(), s.pid, s.version.as_str()),
            ("r1", Some(7), "9.9.9")
        );
        assert_eq!(
            (s.provider.as_str(), s.model.as_str()),
            ("codex", "gpt-6-sol")
        );
        assert_eq!(s.efforts, ["medium", "high"]);
        assert_eq!((s.turns, s.turns_ok, s.interrupts), (2, 1, 1));
        assert_eq!(s.span_ms, 31_000);
        assert_eq!(
            s.requests,
            Requests {
                root: 3,
                helpers: 1,
                children: 1,
                errors: 0
            }
        );
        assert_eq!(
            (s.tools.calls, s.tools.errors, s.tools.from_children),
            (6, 1, 2)
        );
        assert_eq!(s.tools.by_name[0].name, "jev_effort");
        assert_eq!(s.tokens.input, 3000);
        assert_eq!(s.tokens.prefix_busts, 1);
        assert!((s.cache_hit.unwrap() - 0.3).abs() < 1e-9);
        assert!((s.cost_usd - 0.042).abs() < 1e-9);
        assert_eq!(s.ttft_ms.p50, Some(1500));
        assert_eq!(s.request_ms.n, 3);
        assert_eq!(s.request_ms.p90, Some(3000));
        assert_eq!(s.reliability.retries, 1);
        assert_eq!(s.reliability.compactions, 1);
        assert_eq!(s.startup_ms, Some(380));
        assert_eq!(s.acp_sessions, ["session-1"]);
        assert_eq!((s.lines, s.unreadable_lines), (27, 1));
    }

    #[test]
    fn jev_counts_root_and_child_calls_on_an_eligible_route() {
        let jev = observe(RUN).summary().jev;
        assert!(jev.eligible_model);
        assert_eq!(
            (jev.calls, jev.child_calls, jev.errors, jev.ms),
            (2, 1, 0, 1050)
        );
        assert!(!jev_eligible("openrouter", "gpt-6-sol"));
        assert!(jev_eligible("codex", "gpt-6.1-sol"));
        assert!(!jev_eligible("codex", "gpt-60"));
        assert!(jev_eligible("xiaomi", "mimo-v2.6-flash"));
    }

    #[test]
    fn children_come_from_the_per_child_lines() {
        let d = observe(RUN).summary().delegation;
        assert_eq!(d.spawns, 2);
        assert_eq!(d.children.len(), 2);
        let parser = &d.children[0];
        assert_eq!(
            (parser.label.as_str(), parser.start_ms, parser.end_ms),
            ("Fix parser", 7200, 17_200)
        );
        assert_eq!(
            (parser.ok, parser.tools, parser.requests),
            (Some(true), Some(2), 1)
        );
        assert_eq!(parser.effort.as_deref(), Some("high"));
        assert_eq!(d.children[1].ok, Some(false));
        assert_eq!(d.child_critical_ms, Some(12_000));
        assert_eq!(d.parent_wait_ms, 12_000);
        assert_eq!(d.tail_ms, Some(2800));
    }

    #[test]
    fn older_traces_fall_back_to_child_requests() {
        let old: String = RUN
            .lines()
            .filter(|l| !l.contains(r#""ev":"subagent""#))
            .collect::<Vec<_>>()
            .join("\n");
        let d = observe(&old).summary().delegation;
        assert_eq!(d.children.len(), 1);
        assert_eq!(d.children[0].label, "Fix parser");
        assert_eq!((d.children[0].start_ms, d.children[0].end_ms), (7500, 9500));
        assert_eq!(d.children[0].ok, None);
    }

    #[test]
    fn a_startup_only_run_is_empty() {
        let startup = observe(
            r#"{"run_id":"r2","pid":8,"t":0,"ev":"startup_phase","phase":"ready","startup_ms":12}"#,
        );
        assert!(startup.is_empty());
        assert!(!observe(RUN).is_empty());
    }

    #[test]
    fn percentiles_use_nearest_rank() {
        let p = Percentiles::of(&[5, 1, 4, 2, 3, 10, 9, 8, 7, 6]);
        assert_eq!((p.n, p.p50, p.p90), (10, Some(5), Some(9)));
        assert_eq!(Percentiles::of(&[]).p50, None);
        assert_eq!(Percentiles::of(&[42]).p90, Some(42));
    }
}
