//! Recover only an unsolicited cancellation immediately after an accepted form.
//! Actual cancellation, a queued steer, or reported new work must never replay.
use crate::HarnessError;
use harness_proto::AgentEvent;
use serde_json::Value;
use std::collections::HashSet;
use std::sync::{
    Arc,
    atomic::{AtomicBool, Ordering},
};

pub(super) const PROMPT: &str = "[Harness recovery] Continue the current task using the answer already supplied in this conversation. Do not repeat the clarification. Check existing progress before doing anything again.";
pub(super) const NOTICE: &str =
    "\n[The agent stopped unexpectedly after your answer; continuing once.]\n";

#[derive(Default)]
pub(super) struct State {
    pub(super) answered: Arc<AtomicBool>,
    seen_tools: HashSet<String>,
}

fn source(response: &Value) -> Option<&str> {
    response
        .pointer("/_meta/graff~1cancelSource")
        .and_then(Value::as_str)
}

pub(super) fn cancellation_error(response: &Value) -> Option<String> {
    if matches!(
        source(response),
        Some("acp_cancel" | "json_cancel" | "ui_cancel" | "esc_key" | "force_steer")
    ) {
        return None;
    }
    Some(response.pointer("/_meta/graff~1cancelMessage")
        .and_then(Value::as_str)
        .unwrap_or("The agent stopped unexpectedly without a cancellation request. The task is incomplete.")
        .to_owned())
}

impl State {
    pub(super) fn steer(&self) {
        self.answered.store(false, Ordering::Release);
    }

    pub(super) fn observe(&mut self, event: &AgentEvent) {
        let progress = match event {
            AgentEvent::TextDelta { text } | AgentEvent::ReasoningDelta { text } => {
                !text.is_empty()
            }
            AgentEvent::ToolCall { id, .. } => self.seen_tools.insert(id.clone()),
            AgentEvent::ToolResult { id, .. } => !self.seen_tools.contains(id),
            AgentEvent::Steered { .. } => true,
            _ => false,
        };
        if progress {
            self.answered.store(false, Ordering::Release);
        }
    }

    pub(super) fn take_retry(
        &mut self,
        result: &Result<Value, HarnessError>,
        interrupted: bool,
        queued_steer: bool,
    ) -> bool {
        // Consume on every prompt outcome. Without a newly accepted form a
        // second failure cannot retry, nor can a later unrelated turn.
        let answered = self.answered.swap(false, Ordering::AcqRel);
        self.seen_tools.clear();
        answered
            && !interrupted
            && !queued_steer
            && result.as_ref().is_ok_and(|response| {
                response.get("stopReason").and_then(Value::as_str) == Some("cancelled")
                    && source(response).is_none_or(|s| s == "none")
            })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn explicit_interrupt_and_review_deadline_never_retry_an_answer() {
        for (interrupted, source) in [
            (true, "none"),
            (false, "review_deadline"),
            (false, "acp_cancel"),
        ] {
            let mut state = State::default();
            state.answered.store(true, Ordering::Release);
            let response =
                Ok(json!({"stopReason": "cancelled", "_meta": {"graff/cancelSource": source}}));
            assert!(!state.take_retry(&response, interrupted, false));
        }
    }
}
