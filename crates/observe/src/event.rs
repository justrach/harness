//! One trace line in, one [`Event`] out.
//!
//! graff writes one JSON object per line to `.graff/traces/<run-id>.jsonl`.
//! Every line starts with the run's `run_id`, `pid` and `session_id`, then
//! `t` (milliseconds since the run started) and `ev` (the event name). Only
//! the fields this crate reads are typed; a line whose fields drifted still
//! yields its event name instead of disappearing.

use serde::{Deserialize, Serialize};

/// The run identity graff stamps on every line.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Stamp {
    pub run_id: Option<String>,
    pub pid: Option<u32>,
    pub session_id: Option<String>,
}

/// One trace line.
#[derive(Debug, Clone, PartialEq)]
pub struct Event {
    /// Milliseconds since the run started. graff writes a few lines without it.
    pub t_ms: Option<u64>,
    pub kind: EventKind,
}

#[derive(Debug, Clone, PartialEq)]
pub enum EventKind {
    /// One model request by the agent labelled `agent` (`api`).
    Api {
        agent: String,
        model: String,
        ms: u64,
        context_tokens: u64,
        is_error: bool,
    },
    /// The server's token counts for the request just before it (`usage`).
    Usage(Usage),
    /// One finished tool call (`tool`). `from_sub` marks a call made by a
    /// sub-agent or one of graff's helper agents.
    Tool {
        name: String,
        ms: u64,
        is_error: bool,
        from_sub: bool,
        /// Bytes of output the tool produced, before graff's handle threshold.
        result_bytes: u64,
    },
    /// Time from sending a request to its first model output (`first_token`).
    FirstToken {
        agent: String,
        from_sub: bool,
        ms: u64,
    },
    /// The provider, model and effort a root turn starts with (`recipe`).
    Recipe {
        provider: String,
        model: String,
        effort: String,
        version: String,
    },
    /// One finished root turn (`recipe_outcome`).
    Turn(TurnOutcome),
    /// Startup progress (`startup_phase`); `startup_ms` is the total so far.
    Startup { startup_ms: u64 },
    /// One finished sub-agent (a `subagent` line that names its child).
    Subagent(SubagentRun),
    /// Any other event with a `detail` string (`retry`, `turn`, `acp_prompt`, …).
    Note { kind: String, detail: String },
    /// Any other event, by name.
    Other { kind: String },
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Usage {
    pub agent: String,
    pub from_sub: bool,
    pub provider: String,
    pub model: String,
    pub input: u64,
    pub cache_read: u64,
    pub cache_write: u64,
    pub output: u64,
    pub reasoning: u64,
    /// graff saw the cached prefix change before this request.
    pub prefix_bust: bool,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct TurnOutcome {
    pub provider: String,
    pub model: String,
    /// The root agent's effort when the turn ended.
    pub effort: String,
    pub success: bool,
    pub latency_ms: u64,
    pub model_calls: u64,
    pub tool_calls: u64,
    pub tool_errors: u64,
    /// Everything the turn spent, children and helpers included.
    pub cost_microusd: u64,
}

/// graff's line for one finished child:
/// `<id> <ok|failed> label=<label> ms=<n> tools=<n> context=<n> cached=<n> effort=<effort>`.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct SubagentRun {
    pub id: String,
    pub ok: bool,
    pub label: String,
    pub ms: u64,
    pub tools: u64,
    pub context_tokens: u64,
    pub cached_tokens: u64,
    pub effort: String,
}

impl SubagentRun {
    /// The label may contain spaces, so the fields after it are read from the right.
    pub fn parse(detail: &str) -> Option<Self> {
        let (head, rest) = detail.split_once(" label=")?;
        let mut head = head.split_whitespace();
        let id = head.next()?.to_string();
        let ok = match head.next()? {
            "ok" => true,
            "failed" => false,
            _ => return None,
        };
        let at = rest.rfind(" ms=")?;
        let mut run = SubagentRun {
            id,
            ok,
            label: rest[..at].to_string(),
            ..Default::default()
        };
        for pair in rest[at + 1..].split_whitespace() {
            let (key, value) = pair.split_once('=')?;
            match key {
                "ms" => run.ms = value.parse().ok()?,
                "tools" => run.tools = value.parse().ok()?,
                "context" => run.context_tokens = value.parse().ok()?,
                "cached" => run.cached_tokens = value.parse().ok()?,
                "effort" => run.effort = value.to_string(),
                _ => {}
            }
        }
        Some(run)
    }
}

/// The fields this crate reads. Everything else on a line is skipped.
#[derive(Deserialize, Default)]
#[serde(default)]
struct Raw {
    run_id: Option<String>,
    pid: Option<u64>,
    session_id: Option<String>,
    t: Option<i64>,
    ev: Option<String>,
    agent: Option<String>,
    model: Option<String>,
    provider: Option<String>,
    effort: Option<String>,
    name: Option<String>,
    detail: Option<String>,
    ms: Option<i64>,
    is_error: Option<bool>,
    from_sub: Option<bool>,
    context_tokens: Option<u64>,
    input_tokens: Option<u64>,
    cache_read_tokens: Option<u64>,
    cache_write_tokens: Option<u64>,
    output_tokens: Option<u64>,
    reasoning_tokens: Option<u64>,
    prefix_bust: Option<String>,
    result_bytes: Option<u64>,
    harness_version: Option<String>,
    success: Option<bool>,
    latency_ms: Option<u64>,
    model_calls: Option<u64>,
    tool_calls: Option<u64>,
    tool_errors: Option<u64>,
    cost_microusd: Option<u64>,
    startup_ms: Option<u64>,
}

/// Parses one trace line. `None` for blank lines, non-JSON (a line graff is
/// still writing) and objects without an event name.
pub fn parse_line(line: &str) -> Option<(Stamp, Event)> {
    let line = line.trim();
    if line.is_empty() {
        return None;
    }
    match serde_json::from_str::<Raw>(line) {
        Ok(raw) => typed(raw),
        Err(_) => untyped(line),
    }
}

fn typed(raw: Raw) -> Option<(Stamp, Event)> {
    let Raw {
        run_id,
        pid,
        session_id,
        t,
        ev,
        agent,
        model,
        provider,
        effort,
        name,
        detail,
        ms,
        is_error,
        from_sub,
        context_tokens,
        input_tokens,
        cache_read_tokens,
        cache_write_tokens,
        output_tokens,
        reasoning_tokens,
        prefix_bust,
        result_bytes,
        harness_version,
        success,
        latency_ms,
        model_calls,
        tool_calls,
        tool_errors,
        cost_microusd,
        startup_ms,
    } = raw;
    let stamp = Stamp {
        run_id,
        pid: pid.and_then(|p| u32::try_from(p).ok()),
        session_id,
    };
    let ev = ev?;
    let ms = ms.unwrap_or(0).max(0) as u64;
    let is_error = is_error.unwrap_or(false);
    let from_sub = from_sub.unwrap_or(false);
    let kind = match ev.as_str() {
        "api" => EventKind::Api {
            agent: agent.unwrap_or_default(),
            model: model.unwrap_or_default(),
            ms,
            context_tokens: context_tokens.unwrap_or(0),
            is_error,
        },
        "usage" => EventKind::Usage(Usage {
            agent: agent.unwrap_or_default(),
            from_sub,
            provider: provider.unwrap_or_default(),
            model: model.unwrap_or_default(),
            input: input_tokens.unwrap_or(0),
            cache_read: cache_read_tokens.unwrap_or(0),
            cache_write: cache_write_tokens.unwrap_or(0),
            output: output_tokens.unwrap_or(0),
            reasoning: reasoning_tokens.unwrap_or(0),
            prefix_bust: prefix_bust.is_some_and(|b| !b.is_empty()),
        }),
        "tool" => EventKind::Tool {
            name: name.unwrap_or_default(),
            ms,
            is_error,
            from_sub,
            result_bytes: result_bytes.unwrap_or(0),
        },
        "first_token" => EventKind::FirstToken {
            agent: agent.unwrap_or_default(),
            from_sub,
            ms,
        },
        "recipe" => EventKind::Recipe {
            provider: provider.unwrap_or_default(),
            model: model.unwrap_or_default(),
            effort: effort.unwrap_or_default(),
            version: harness_version.unwrap_or_default(),
        },
        "recipe_outcome" => EventKind::Turn(TurnOutcome {
            provider: provider.unwrap_or_default(),
            model: model.unwrap_or_default(),
            effort: effort.unwrap_or_default(),
            success: success.unwrap_or(false),
            latency_ms: latency_ms.unwrap_or(0),
            model_calls: model_calls.unwrap_or(0),
            tool_calls: tool_calls.unwrap_or(0),
            tool_errors: tool_errors.unwrap_or(0),
            cost_microusd: cost_microusd.unwrap_or(0),
        }),
        "startup_phase" => EventKind::Startup {
            startup_ms: startup_ms.unwrap_or(0),
        },
        "subagent" => match detail.as_deref().and_then(SubagentRun::parse) {
            Some(run) => EventKind::Subagent(run),
            None => note(ev, detail),
        },
        _ => note(ev, detail),
    };
    let t_ms = t.map(|t| t.max(0) as u64);
    Some((stamp, Event { t_ms, kind }))
}

/// A line whose typed fields did not match: keep its name, time and detail.
fn untyped(line: &str) -> Option<(Stamp, Event)> {
    let value: serde_json::Value = serde_json::from_str(line).ok()?;
    let obj = value.as_object()?;
    let text = |key: &str| obj.get(key).and_then(|v| v.as_str()).map(str::to_string);
    let stamp = Stamp {
        run_id: text("run_id"),
        pid: obj
            .get("pid")
            .and_then(|v| v.as_u64())
            .and_then(|p| u32::try_from(p).ok()),
        session_id: text("session_id"),
    };
    let kind = note(text("ev")?, text("detail"));
    let t_ms = obj
        .get("t")
        .and_then(|v| v.as_i64())
        .map(|t| t.max(0) as u64);
    Some((stamp, Event { t_ms, kind }))
}

fn note(kind: String, detail: Option<String>) -> EventKind {
    match detail {
        Some(detail) => EventKind::Note { kind, detail },
        None => EventKind::Other { kind },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const STAMP: &str = r#""run_id":"r1","pid":42,"session_id":"s1""#;

    fn parse(fields: &str) -> Event {
        let (stamp, event) = parse_line(&format!("{{{STAMP},{fields}}}")).expect("event");
        assert_eq!(stamp.run_id.as_deref(), Some("r1"));
        assert_eq!(stamp.pid, Some(42));
        event
    }

    #[test]
    fn api_and_usage_lines() {
        let api = parse(
            r#""t":1200,"ev":"api","turn":1,"agent":"main","model":"m1","ms":900,"req_bytes":10,"resp_bytes":20,"context_tokens":5000,"cache_read_tokens":4000,"is_error":false"#,
        );
        assert_eq!(api.t_ms, Some(1200));
        assert_eq!(
            api.kind,
            EventKind::Api {
                agent: "main".into(),
                model: "m1".into(),
                ms: 900,
                context_tokens: 5000,
                is_error: false
            }
        );
        let usage = parse(
            r#""t":1201,"ev":"usage","agent":"main","from_sub":false,"provider":"p","model":"m1","input_tokens":5000,"cache_read_tokens":4000,"cache_write_tokens":0,"output_tokens":80,"chained":true,"cache_ttl":null,"prefix_changed":false,"prefix_bust":null,"gap_ms":null,"cache_miss":null,"reasoning_tokens":null"#,
        );
        let EventKind::Usage(u) = usage.kind else {
            panic!("usage")
        };
        assert_eq!(
            (u.input, u.cache_read, u.output, u.reasoning),
            (5000, 4000, 80, 0)
        );
        assert!(!u.prefix_bust);
    }

    #[test]
    fn a_failed_api_line_has_no_usage_fields() {
        let api = parse(
            r#""t":5,"ev":"api","turn":1,"agent":"main","model":"m1","ms":30,"req_bytes":10,"resp_bytes":0,"is_error":true"#,
        );
        assert!(matches!(
            api.kind,
            EventKind::Api {
                is_error: true,
                context_tokens: 0,
                ..
            }
        ));
    }

    #[test]
    fn subagent_lines_keep_spaces_in_labels() {
        let run = SubagentRun::parse(
            "sa-3 ok label=Fix the ms=parser bug ms=41000 tools=14 context=52000 cached=48000 effort=high",
        )
        .expect("run");
        assert_eq!(run.id, "sa-3");
        assert!(run.ok);
        assert_eq!(run.label, "Fix the ms=parser bug");
        assert_eq!(
            (run.ms, run.tools, run.context_tokens, run.cached_tokens),
            (41000, 14, 52000, 48000)
        );
        assert_eq!(run.effort, "high");
        let failed =
            SubagentRun::parse("sa-4 failed label=x ms=5 tools=0 context=0 cached=0 effort=medium")
                .unwrap();
        assert!(!failed.ok);
        // graff's other `subagent` notes are plain notes.
        let pin = parse(r#""t":9,"ev":"subagent","detail":"effort pin applied""#);
        assert_eq!(
            pin.kind,
            EventKind::Note {
                kind: "subagent".into(),
                detail: "effort pin applied".into()
            }
        );
    }

    #[test]
    fn turn_recipe_and_startup_lines() {
        let recipe = parse(
            r#""t":3,"ev":"recipe","recipe_sha":"x","provider":"p","model":"m1","effort":"medium","prompt_sha":"y","toolset_sha":"z","task_class":"general","harness_version":"1.2.3""#,
        );
        assert_eq!(
            recipe.kind,
            EventKind::Recipe {
                provider: "p".into(),
                model: "m1".into(),
                effort: "medium".into(),
                version: "1.2.3".into()
            }
        );
        let turn = parse(
            r#""t":9000,"ev":"recipe_outcome","recipe_sha":"x","task_class":"general","provider":"p","model":"m1","effort":"high","success":true,"executed":true,"claimed":false,"verified":false,"latency_ms":8000,"model_calls":4,"tool_calls":6,"tool_errors":1,"uncached_tokens":10,"cache_read_tokens":90,"cache_permille":900,"cost_microusd":12000,"resp_blocks":1,"resp_types":"text","resp_text_len":40"#,
        );
        let EventKind::Turn(o) = turn.kind else {
            panic!("turn")
        };
        assert_eq!(
            (o.effort.as_str(), o.success, o.cost_microusd),
            ("high", true, 12000)
        );
        let startup =
            parse(r#""t":0,"ev":"startup_phase","phase":"ready","phase_ms":3,"startup_ms":410"#);
        assert_eq!(startup.kind, EventKind::Startup { startup_ms: 410 });
    }

    #[test]
    fn notes_lines_without_time_and_drifted_fields() {
        let note = parse(r#""t":7,"ev":"retry","detail":"server error (5xx) [main]""#);
        assert!(matches!(note.kind, EventKind::Note { ref kind, .. } if kind == "retry"));
        let cut =
            parse(r#""ev":"compact_cut","boundary":12,"preserved_images":0,"unresolved":false"#);
        assert_eq!(cut.t_ms, None);
        assert_eq!(
            cut.kind,
            EventKind::Other {
                kind: "compact_cut".into()
            }
        );
        // `ms` as a string no longer fits the typed shape; the event survives by name.
        let drifted = parse(r#""t":8,"ev":"tool","name":"bash","ms":"slow""#);
        assert_eq!(
            drifted.kind,
            EventKind::Other {
                kind: "tool".into()
            }
        );
        assert_eq!(drifted.t_ms, Some(8));
    }

    #[test]
    fn partial_and_blank_lines_are_skipped() {
        assert!(parse_line("").is_none());
        assert!(parse_line(r#"{"run_id":"r1","t":1,"ev":"to"#).is_none());
        assert!(parse_line(r#"{"run_id":"r1","t":1}"#).is_none());
    }
}
