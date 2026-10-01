//! OpenTelemetry for graff runs: trace events in, OTLP spans out, named and
//! attributed after the OpenTelemetry GenAI semantic conventions so any OTel
//! backend (a collector, Jaeger, Tempo, Honeycomb, Langfuse, Phoenix…) can
//! show a run.
//!
//! One root turn is one trace:
//!
//! - `invoke_agent graff`: the turn, with its effort, cost and outcome.
//! - `chat {model}`: one model request, with token usage and time to first token.
//! - `execute_tool {name}`: one tool call.
//! - `invoke_agent {label}`: one sub-agent; its requests and tool calls nest under it.
//!
//! Notes (retries, stalls, compactions, interrupts) become events on the
//! turn. Content stays out: graff's traces hold no prompts, tool arguments
//! or results, and a note kind not known to be content-free is exported by
//! name only. Ids derive from the run id, so exporting a run twice yields
//! the same ids.

use std::collections::HashMap;

use crate::discover::TraceFile;
use crate::event::{Event, EventKind, SubagentRun, TurnOutcome, Usage, parse_line};
use crate::summary::{HELPER_LABELS, ROOT_LABELS};

/// Note kinds whose `detail` is operational text graff writes itself.
const CONTENT_FREE_NOTES: &[&str] = &[
    "retry",
    "stream_retry",
    "stall_budget",
    "stream_stall",
    "ws_api_error",
    "turn",
    "context",
    "compact",
    "budget",
    "pending_work",
    "ask_user_wait",
    "ask_user_outcome",
    "subagent",
    "subagent_retry",
    "route",
    "task_intent",
    "escalation",
    "fake_done",
    "summary_checkpoint",
    "turn_dedup",
    "session",
];

#[derive(Debug, Clone, PartialEq)]
pub enum AttrValue {
    Str(String),
    Int(i64),
    Double(f64),
    Bool(bool),
}

#[derive(Debug, Clone, PartialEq)]
pub struct Attr {
    pub key: &'static str,
    pub value: AttrValue,
}

pub(crate) fn s(key: &'static str, value: impl Into<String>) -> Attr {
    Attr {
        key,
        value: AttrValue::Str(value.into()),
    }
}

fn n(key: &'static str, value: u64) -> Attr {
    Attr {
        key,
        value: AttrValue::Int(i64::try_from(value).unwrap_or(i64::MAX)),
    }
}

fn f(key: &'static str, value: f64) -> Attr {
    Attr {
        key,
        value: AttrValue::Double(value),
    }
}

fn b(key: &'static str, value: bool) -> Attr {
    Attr {
        key,
        value: AttrValue::Bool(value),
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SpanKind {
    Internal,
    Client,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Status {
    Unset,
    Error(String),
}

#[derive(Debug, Clone, PartialEq)]
pub struct SpanEvent {
    pub at_ms: u64,
    pub name: String,
    pub attrs: Vec<Attr>,
}

/// One finished span. Times are milliseconds since the run started.
#[derive(Debug, Clone, PartialEq)]
pub struct Span {
    pub trace_id: [u8; 16],
    pub span_id: [u8; 8],
    pub parent: Option<[u8; 8]>,
    pub name: String,
    pub kind: SpanKind,
    pub start_ms: u64,
    pub end_ms: u64,
    pub attrs: Vec<Attr>,
    pub events: Vec<SpanEvent>,
    pub status: Status,
}

impl Span {
    pub fn attr(&self, key: &str) -> Option<&AttrValue> {
        self.attrs.iter().find(|a| a.key == key).map(|a| &a.value)
    }
}

/// FNV-1a over the parts, then a splitmix finalizer: stable across runs and machines.
fn hash(seed: u64, parts: &[&str]) -> u64 {
    let mut h = 0xcbf2_9ce4_8422_2325 ^ seed.wrapping_mul(0x9e37_79b9_7f4a_7c15);
    for part in parts {
        for byte in part.bytes().chain([0xff]) {
            h ^= u64::from(byte);
            h = h.wrapping_mul(0x0000_0100_0000_01b3);
        }
    }
    h = (h ^ (h >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
    h = (h ^ (h >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
    h ^ (h >> 31)
}

fn span_id(parts: &[&str]) -> [u8; 8] {
    hash(1, parts).max(1).to_be_bytes()
}

fn trace_id(parts: &[&str]) -> [u8; 16] {
    let mut id = [0; 16];
    id[..8].copy_from_slice(&hash(2, parts).to_be_bytes());
    id[8..].copy_from_slice(&hash(3, parts).max(1).to_be_bytes());
    id
}

struct Turn {
    index: u64,
    trace_id: [u8; 16],
    span_id: [u8; 8],
    start_ms: u64,
    events: Vec<SpanEvent>,
    conversation: Option<String>,
}

/// A sub-agent whose requests have started and whose closing line has not arrived.
struct Child {
    trace_id: [u8; 16],
    parent: [u8; 8],
    span_id: [u8; 8],
    start_ms: u64,
    end_ms: u64,
    model: String,
}

/// Turns one run's events into spans as each span finishes, so the same code
/// serves a finished trace and one graff is still writing.
#[derive(Default)]
pub struct Converter {
    run_id: String,
    project: Option<String>,
    pid: Option<u32>,
    session_id: Option<String>,
    acp_session: Option<String>,
    version: String,
    provider: String,
    model: String,
    from_sub: HashMap<String, bool>,
    turns: u64,
    turn: Option<Turn>,
    last_turn: Option<([u8; 16], [u8; 8])>,
    early_events: Vec<SpanEvent>,
    /// Successful requests waiting for their `usage` line, by agent.
    waiting: HashMap<String, Span>,
    first_token: HashMap<String, u64>,
    children: HashMap<String, Child>,
    child_runs: HashMap<String, u64>,
    requests: u64,
    tools: u64,
    startup_ms: Option<u64>,
    last_t: u64,
    done: Vec<Span>,
}

impl Converter {
    pub fn new(file: &TraceFile) -> Self {
        Converter {
            run_id: file.run_id.clone(),
            project: file.project(),
            ..Default::default()
        }
    }

    pub fn push_line(&mut self, line: &str) -> Option<Event> {
        let (stamp, event) = parse_line(line)?;
        if self.pid.is_none() {
            self.pid = stamp.pid;
        }
        if self.session_id.is_none() {
            self.session_id = stamp.session_id.filter(|id| !id.is_empty());
        }
        self.push(&event);
        Some(event)
    }

    pub fn pid(&self) -> Option<u32> {
        self.pid
    }

    /// Milliseconds from the run's start to its latest event.
    pub fn last_t(&self) -> u64 {
        self.last_t
    }

    /// No model request and no tool call so far.
    pub fn is_empty(&self) -> bool {
        self.requests == 0 && self.tools == 0
    }

    /// Spans finished since the last call.
    pub fn take(&mut self) -> Vec<Span> {
        std::mem::take(&mut self.done)
    }

    /// Ends the run: requests still waiting for usage, children without a
    /// closing line (traces from before graff wrote one), and the open turn.
    pub fn finish(&mut self) -> Vec<Span> {
        self.flush_waiting();
        let mut children: Vec<(String, Child)> = self.children.drain().collect();
        children.sort_by_key(|(_, child)| child.start_ms);
        for (label, child) in children {
            let span = self.child_span(&label, child, None);
            self.done.push(span);
        }
        if let Some(turn) = self.turn.take() {
            let end = self.last_t;
            self.close_turn(turn, end, None);
        }
        self.take()
    }

    /// OTel resource attributes for this run.
    pub fn resource(&self) -> Vec<Attr> {
        let mut attrs = vec![
            s("service.name", "graff"),
            s("service.instance.id", self.run_id.clone()),
            s("graff.run_id", self.run_id.clone()),
        ];
        if !self.version.is_empty() {
            attrs.push(s("service.version", self.version.clone()));
        }
        if let Some(pid) = self.pid {
            attrs.push(n("process.pid", u64::from(pid)));
        }
        if let Some(project) = &self.project {
            attrs.push(s("graff.project", project.clone()));
        }
        attrs
    }

    pub fn push(&mut self, event: &Event) {
        let t = event.t_ms.unwrap_or(self.last_t);
        self.last_t = self.last_t.max(t);
        match &event.kind {
            EventKind::Api {
                agent,
                model,
                ms,
                context_tokens,
                is_error,
            } => self.request(agent, model, t, *ms, *context_tokens, *is_error),
            EventKind::Usage(usage) => self.usage(usage),
            EventKind::FirstToken {
                agent,
                from_sub,
                ms,
            } => {
                self.from_sub.insert(agent.clone(), *from_sub);
                self.first_token.insert(agent.clone(), *ms);
            }
            EventKind::Tool {
                name,
                ms,
                is_error,
                from_sub,
            } => self.tool(name, t, *ms, *is_error, *from_sub),
            EventKind::Subagent(run) => self.subagent(run, t),
            EventKind::Turn(outcome) => self.turn_done(outcome, t),
            EventKind::Recipe {
                provider,
                model,
                version,
                ..
            } => {
                set(&mut self.provider, provider);
                set(&mut self.model, model);
                set(&mut self.version, version);
            }
            EventKind::Startup { startup_ms } => {
                self.startup_ms = Some(self.startup_ms.unwrap_or(0).max(*startup_ms));
            }
            EventKind::Note { kind, detail } => self.note(kind, Some(detail.as_str()), t),
            EventKind::Other { kind } if kind == "compact_cut" => self.note("compaction", None, t),
            EventKind::Other { .. } => {}
        }
    }

    fn request(
        &mut self,
        agent: &str,
        model: &str,
        t: u64,
        ms: u64,
        context_tokens: u64,
        is_error: bool,
    ) {
        if let Some(earlier) = self.waiting.remove(agent) {
            self.done.push(earlier);
        }
        self.requests += 1;
        let start = t.saturating_sub(ms);
        let (trace_id, parent) = self.agent_parent(agent, model, start, t);
        let seq = self.requests.to_string();
        let mut span = Span {
            trace_id,
            span_id: span_id(&[&self.run_id, "chat", &seq]),
            parent: Some(parent),
            name: format!("chat {model}"),
            kind: SpanKind::Client,
            start_ms: start,
            end_ms: t,
            attrs: vec![
                s("gen_ai.operation.name", "chat"),
                s("gen_ai.request.model", model),
                s("graff.agent", agent),
                n("graff.context_tokens", context_tokens),
            ],
            events: Vec::new(),
            status: Status::Unset,
        };
        if !self.provider.is_empty() {
            span.attrs
                .push(s("gen_ai.provider.name", self.provider.clone()));
        }
        if let Some(ttft) = self.first_token.remove(agent) {
            span.attrs.push(f(
                "gen_ai.response.time_to_first_chunk",
                ttft as f64 / 1000.0,
            ));
            span.events.push(SpanEvent {
                at_ms: start + ttft.min(ms),
                name: "first_token".into(),
                attrs: Vec::new(),
            });
        }
        if is_error {
            span.status = Status::Error("model request failed".into());
            span.attrs.push(s("error.type", "request_failed"));
            self.done.push(span);
        } else {
            self.waiting.insert(agent.to_string(), span);
        }
    }

    fn usage(&mut self, u: &Usage) {
        self.from_sub.insert(u.agent.clone(), u.from_sub);
        if !u.from_sub {
            set_if_empty(&mut self.provider, &u.provider);
        }
        let Some(mut span) = self.waiting.remove(&u.agent) else {
            return;
        };
        if !u.provider.is_empty() {
            span.attrs.retain(|a| a.key != "gen_ai.provider.name");
            span.attrs
                .push(s("gen_ai.provider.name", u.provider.clone()));
        }
        span.attrs.extend([
            n("gen_ai.usage.input_tokens", u.input),
            n("gen_ai.usage.output_tokens", u.output),
            n("gen_ai.usage.cache_read.input_tokens", u.cache_read),
        ]);
        if u.cache_write > 0 {
            span.attrs
                .push(n("gen_ai.usage.cache_creation.input_tokens", u.cache_write));
        }
        if u.reasoning > 0 {
            span.attrs
                .push(n("gen_ai.usage.reasoning.output_tokens", u.reasoning));
        }
        if u.prefix_bust {
            span.attrs.push(b("graff.cache.prefix_bust", true));
        }
        self.done.push(span);
    }

    fn tool(&mut self, name: &str, t: u64, ms: u64, is_error: bool, from_sub: bool) {
        self.tools += 1;
        let start = t.saturating_sub(ms);
        // A child's tool line names no agent: nest it under the child when only one is running.
        let only_child = (from_sub && self.children.len() == 1)
            .then(|| {
                self.children
                    .values()
                    .next()
                    .map(|c| (c.trace_id, c.span_id))
            })
            .flatten();
        let (trace_id, parent) = match only_child {
            Some(ids) => ids,
            None => self.turn_ids(start),
        };
        let seq = self.tools.to_string();
        let mut span = Span {
            trace_id,
            span_id: span_id(&[&self.run_id, "tool", &seq]),
            parent: Some(parent),
            name: format!("execute_tool {name}"),
            kind: SpanKind::Internal,
            start_ms: start,
            end_ms: t,
            attrs: vec![
                s("gen_ai.operation.name", "execute_tool"),
                s("gen_ai.tool.name", name),
            ],
            events: Vec::new(),
            status: Status::Unset,
        };
        if from_sub {
            span.attrs.push(b("graff.from_sub", true));
        }
        if is_error {
            span.status = Status::Error("tool call failed".into());
            span.attrs.push(s("error.type", "tool_error"));
        }
        self.done.push(span);
    }

    fn subagent(&mut self, run: &SubagentRun, t: u64) {
        let start = t.saturating_sub(run.ms);
        let mut child = match self.children.remove(&run.label) {
            Some(child) => child,
            None => self.new_child(&run.label, "", start, t),
        };
        child.start_ms = child.start_ms.min(start);
        child.end_ms = t;
        *self.child_runs.entry(run.label.clone()).or_default() += 1;
        let span = self.child_span(&run.label, child, Some(run));
        self.done.push(span);
    }

    fn turn_done(&mut self, outcome: &TurnOutcome, t: u64) {
        set_if_empty(&mut self.provider, &outcome.provider);
        set_if_empty(&mut self.model, &outcome.model);
        self.turn_ids(t.saturating_sub(outcome.latency_ms));
        if let Some(turn) = self.turn.take() {
            self.close_turn(turn, t, Some(outcome));
        }
    }

    fn note(&mut self, kind: &str, detail: Option<&str>, t: u64) {
        match kind {
            // The ACP session id names the conversation of the turns that follow.
            "acp_prompt" => {
                self.acp_session = detail.map(str::to_string);
                return;
            }
            "ws" => return,
            _ => {}
        }
        let mut event = SpanEvent {
            at_ms: t,
            name: format!("graff.{kind}"),
            attrs: Vec::new(),
        };
        if let Some(detail) = detail.filter(|_| CONTENT_FREE_NOTES.contains(&kind)) {
            event.attrs.push(s("graff.detail", clip(detail, 300)));
        }
        match &mut self.turn {
            Some(turn) => turn.events.push(event),
            None => self.early_events.push(event),
        }
    }

    /// The trace and parent span for a request by `agent`: the turn for the
    /// root agent, the open (or last) turn for graff's helpers, and the
    /// child's own span for a sub-agent.
    fn agent_parent(
        &mut self,
        agent: &str,
        model: &str,
        start: u64,
        end: u64,
    ) -> ([u8; 16], [u8; 8]) {
        if ROOT_LABELS.contains(&agent) || self.from_sub.get(agent) == Some(&false) {
            return self.turn_ids(start);
        }
        if HELPER_LABELS.contains(&agent) {
            return match (&self.turn, self.last_turn) {
                (Some(turn), _) => (turn.trace_id, turn.span_id),
                (None, Some(last)) => last,
                (None, None) => self.turn_ids(start),
            };
        }
        if let Some(child) = self.children.get_mut(agent) {
            child.start_ms = child.start_ms.min(start);
            child.end_ms = child.end_ms.max(end);
            set(&mut child.model, model);
            return (child.trace_id, child.span_id);
        }
        let child = self.new_child(agent, model, start, end);
        let ids = (child.trace_id, child.span_id);
        self.children.insert(agent.to_string(), child);
        ids
    }

    fn new_child(&mut self, label: &str, model: &str, start: u64, end: u64) -> Child {
        let (trace_id, parent) = self.turn_ids(start);
        let generation = self.child_runs.get(label).copied().unwrap_or(0).to_string();
        Child {
            trace_id,
            parent,
            span_id: span_id(&[&self.run_id, "agent", label, &generation]),
            start_ms: start,
            end_ms: end,
            model: model.to_string(),
        }
    }

    /// The open turn's ids, opening the next turn when none is open.
    fn turn_ids(&mut self, start: u64) -> ([u8; 16], [u8; 8]) {
        if self.turn.is_none() {
            self.turns += 1;
            let index = self.turns.to_string();
            self.turn = Some(Turn {
                index: self.turns,
                trace_id: trace_id(&[&self.run_id, "turn", &index]),
                span_id: span_id(&[&self.run_id, "turn", &index]),
                start_ms: start,
                events: std::mem::take(&mut self.early_events),
                conversation: self.acp_session.clone().or_else(|| self.session_id.clone()),
            });
        }
        let turn = self.turn.as_mut().expect("opened above");
        turn.start_ms = turn.start_ms.min(start);
        (turn.trace_id, turn.span_id)
    }

    fn close_turn(&mut self, turn: Turn, end: u64, outcome: Option<&TurnOutcome>) {
        // A request whose usage never came still belongs to this turn.
        self.flush_waiting();
        let start = match outcome {
            Some(o) => turn.start_ms.min(end.saturating_sub(o.latency_ms)),
            None => turn.start_ms,
        };
        let mut span = Span {
            trace_id: turn.trace_id,
            span_id: turn.span_id,
            parent: None,
            name: "invoke_agent graff".into(),
            kind: SpanKind::Internal,
            start_ms: start,
            end_ms: end.max(start),
            attrs: vec![
                s("gen_ai.operation.name", "invoke_agent"),
                s("gen_ai.agent.name", "graff"),
                n("graff.turn", turn.index),
            ],
            events: turn.events,
            status: Status::Unset,
        };
        let (provider, model) = match outcome {
            Some(o) if !o.provider.is_empty() => (o.provider.clone(), o.model.clone()),
            _ => (self.provider.clone(), self.model.clone()),
        };
        if !provider.is_empty() {
            span.attrs.push(s("gen_ai.provider.name", provider));
        }
        if !model.is_empty() {
            span.attrs.push(s("gen_ai.request.model", model));
        }
        if let Some(conversation) = turn.conversation {
            span.attrs.push(s("gen_ai.conversation.id", conversation));
        }
        if let (1, Some(ms)) = (turn.index, self.startup_ms) {
            span.attrs.push(n("graff.startup_ms", ms));
        }
        match outcome {
            Some(o) => {
                if !o.effort.is_empty() {
                    span.attrs
                        .push(s("gen_ai.request.reasoning.level", o.effort.clone()));
                }
                span.attrs.extend([
                    b("graff.turn.success", o.success),
                    n("graff.turn.model_calls", o.model_calls),
                    n("graff.turn.tool_calls", o.tool_calls),
                    n("graff.turn.tool_errors", o.tool_errors),
                    f("graff.turn.cost_usd", o.cost_microusd as f64 / 1_000_000.0),
                ]);
            }
            None => span.attrs.push(b("graff.turn.incomplete", true)),
        }
        self.last_turn = Some((turn.trace_id, turn.span_id));
        self.done.push(span);
    }

    fn flush_waiting(&mut self) {
        let mut waiting: Vec<Span> = self.waiting.drain().map(|(_, span)| span).collect();
        waiting.sort_by_key(|span| span.start_ms);
        self.done.extend(waiting);
    }

    fn child_span(&self, label: &str, child: Child, run: Option<&SubagentRun>) -> Span {
        let model = if child.model.is_empty() {
            &self.model
        } else {
            &child.model
        };
        let mut span = Span {
            trace_id: child.trace_id,
            span_id: child.span_id,
            parent: Some(child.parent),
            name: format!("invoke_agent {label}"),
            kind: SpanKind::Internal,
            start_ms: child.start_ms,
            end_ms: child.end_ms.max(child.start_ms),
            attrs: vec![
                s("gen_ai.operation.name", "invoke_agent"),
                s("gen_ai.agent.name", label),
            ],
            events: Vec::new(),
            status: Status::Unset,
        };
        if !self.provider.is_empty() {
            span.attrs
                .push(s("gen_ai.provider.name", self.provider.clone()));
        }
        if !model.is_empty() {
            span.attrs.push(s("gen_ai.request.model", model.clone()));
        }
        match run {
            Some(run) => {
                span.attrs.extend([
                    s("graff.agent.id", run.id.clone()),
                    n("graff.agent.tool_calls", run.tools),
                    n("graff.agent.context_tokens", run.context_tokens),
                    n("graff.agent.cache_read_tokens", run.cached_tokens),
                ]);
                if !run.effort.is_empty() {
                    span.attrs
                        .push(s("gen_ai.request.reasoning.level", run.effort.clone()));
                }
                if !run.ok {
                    span.status = Status::Error("sub-agent failed".into());
                    span.attrs.push(s("error.type", "subagent_failed"));
                }
            }
            // Older traces: the span covers the child's own requests.
            None => span.attrs.push(b("graff.agent.inferred", true)),
        }
        span
    }
}

fn set(slot: &mut String, value: &str) {
    if !value.is_empty() {
        *slot = value.to_string();
    }
}

fn set_if_empty(slot: &mut String, value: &str) {
    if slot.is_empty() {
        set(slot, value);
    }
}

fn clip(text: &str, max_chars: usize) -> String {
    text.chars().take(max_chars).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::summary::tests::RUN;

    fn convert(text: &str) -> Vec<Span> {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("r1.jsonl");
        std::fs::write(&path, text).unwrap();
        let mut converter = Converter::new(&TraceFile::open(&path).unwrap());
        for line in text.lines() {
            converter.push_line(line);
        }
        let mut spans = converter.take();
        spans.extend(converter.finish());
        spans
    }

    fn named<'a>(spans: &'a [Span], name: &str) -> Vec<&'a Span> {
        spans.iter().filter(|s| s.name == name).collect()
    }

    fn text(span: &Span, key: &str) -> String {
        match span.attr(key) {
            Some(AttrValue::Str(v)) => v.clone(),
            other => panic!("{key} on {}: {other:?}", span.name),
        }
    }

    #[test]
    fn one_trace_per_turn_with_requests_tools_and_children_nested() {
        let spans = convert(RUN);
        let turns = named(&spans, "invoke_agent graff");
        assert_eq!(turns.len(), 2);
        let (first, second) = (turns[0], turns[1]);
        assert_ne!(first.trace_id, second.trace_id);
        assert_eq!((first.start_ms, first.end_ms), (100, 22_500));
        assert_eq!(text(first, "gen_ai.request.reasoning.level"), "high");
        assert_eq!(text(first, "gen_ai.conversation.id"), "s");
        assert_eq!(text(second, "gen_ai.conversation.id"), "session-1");
        assert_eq!(first.attr("graff.startup_ms"), Some(&AttrValue::Int(380)));
        assert_eq!(
            first.attr("graff.turn.cost_usd"),
            Some(&AttrValue::Double(0.041))
        );
        assert!(first.events.iter().any(|e| e.name == "graff.retry"
            && e.attrs[0].value == AttrValue::Str("server error (5xx) [main]".into())));
        assert!(second.events.iter().any(|e| e.name == "graff.turn"));
        assert!(second.events.iter().any(|e| e.name == "graff.compaction"));

        let chats: Vec<&Span> = spans
            .iter()
            .filter(|s| s.name.starts_with("chat "))
            .collect();
        assert_eq!(chats.len(), 5);
        let root_chat = chats.iter().find(|s| s.start_ms == 100).unwrap();
        assert_eq!(root_chat.parent, Some(first.span_id));
        assert_eq!(root_chat.kind, SpanKind::Client);
        assert_eq!(
            root_chat.attr("gen_ai.usage.input_tokens"),
            Some(&AttrValue::Int(1000))
        );
        assert_eq!(
            root_chat.attr("gen_ai.usage.reasoning.output_tokens"),
            Some(&AttrValue::Int(20))
        );
        assert_eq!(
            root_chat.attr("gen_ai.response.time_to_first_chunk"),
            Some(&AttrValue::Double(1.5))
        );
        assert_eq!(text(root_chat, "gen_ai.provider.name"), "codex");

        let parser = named(&spans, "invoke_agent Fix parser")[0];
        assert_eq!(
            (parser.trace_id, parser.parent),
            (first.trace_id, Some(first.span_id))
        );
        assert_eq!((parser.start_ms, parser.end_ms), (7200, 17_200));
        assert_eq!(text(parser, "gen_ai.request.reasoning.level"), "high");
        let child_chat = chats
            .iter()
            .find(|s| text(s, "graff.agent") == "Fix parser")
            .unwrap();
        assert_eq!(child_chat.parent, Some(parser.span_id));
        let bash = named(&spans, "execute_tool bash")[0];
        assert_eq!(bash.parent, Some(parser.span_id));
        assert_eq!(bash.status, Status::Error("tool call failed".into()));
        let lexer = named(&spans, "invoke_agent Fix lexer")[0];
        assert_eq!(lexer.status, Status::Error("sub-agent failed".into()));
        let title = chats
            .iter()
            .find(|s| text(s, "graff.agent") == "title")
            .unwrap();
        assert_eq!(title.parent, Some(first.span_id));
        assert_eq!(named(&spans, "execute_tool jev_effort").len(), 2);
        assert_eq!(spans.len(), 15);
    }

    #[test]
    fn ids_are_stable_and_never_zero() {
        let (a, b) = (convert(RUN), convert(RUN));
        assert_eq!(a, b);
        let mut ids: Vec<[u8; 8]> = a.iter().map(|s| s.span_id).collect();
        ids.sort();
        ids.dedup();
        assert_eq!(ids.len(), a.len());
        assert!(
            a.iter()
                .all(|s| s.span_id != [0; 8] && s.trace_id != [0; 16])
        );
    }

    #[test]
    fn notes_that_may_carry_user_text_go_out_by_name_only() {
        let retry = r#""ev":"retry","detail":"server error (5xx) [main]"}"#;
        let private = r#"{"run_id":"r1","pid":7,"session_id":"s","t":22200,"ev":"ultracode","detail":"private words"}"#;
        let spans = convert(&RUN.replace(retry, &format!("{retry}\n{private}")));
        let first = spans
            .iter()
            .find(|s| s.attr("graff.turn") == Some(&AttrValue::Int(1)))
            .unwrap();
        let note = first
            .events
            .iter()
            .find(|e| e.name == "graff.ultracode")
            .unwrap();
        assert!(note.attrs.is_empty());
        let retry = first
            .events
            .iter()
            .find(|e| e.name == "graff.retry")
            .unwrap();
        assert_eq!(retry.attrs.len(), 1);
    }

    #[test]
    fn older_traces_get_inferred_child_spans() {
        let old: String = RUN
            .lines()
            .filter(|l| !l.contains(r#""ev":"subagent""#))
            .collect::<Vec<_>>()
            .join("\n");
        let spans = convert(&old);
        let parser = named(&spans, "invoke_agent Fix parser")[0];
        assert_eq!(
            parser.attr("graff.agent.inferred"),
            Some(&AttrValue::Bool(true))
        );
        assert_eq!((parser.start_ms, parser.end_ms), (7500, 9500));
        assert!(named(&spans, "invoke_agent Fix lexer").is_empty());
    }
}
