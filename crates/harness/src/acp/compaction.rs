//! ACP session compaction (`compaction_update` / `compaction_summary_chunk`):
//! the agent reports when it folds older context into a summary. Unstable in
//! protocol v1, where an agent sends these only to clients advertising
//! `clientCapabilities.session.compaction`; protocol v2 needs no capability,
//! so the mapping here never checks which version was negotiated.
//!
//! Each compaction is one chip keyed by its `compactionId`: opened by
//! `in_progress` (or the first chunk), fed the streamed summary as live
//! progress, and resolved by its terminal status. The result carries the
//! summary, so it persists with the chat.

use std::collections::{HashMap, HashSet};

use harness_proto::{AgentEvent, COMPACTION_TOOL_NAME, ToolCall};
use serde_json::{Value, json};

use super::normalize::{OUTPUT_CAP, cap_text, chunk_text, content_block_text};

/// `clientCapabilities.session`, advertised at `initialize`.
pub(super) fn session_capability() -> Value {
    json!({ "compaction": {} })
}

#[derive(Default)]
pub(super) struct CompactionTracker {
    /// Summary text streamed so far, per compaction still in progress.
    open: HashMap<String, String>,
    /// Resolved ids; the spec never reuses one, so a late frame is stale.
    finished: HashSet<String>,
}

fn chip_id(compaction: &str) -> String {
    format!("acp-compaction-{compaction}")
}

/// The completed update's `summary` (`ContentBlock[]`), text blocks only.
fn summary_text(update: &Value) -> Option<String> {
    let text = update
        .get("summary")?
        .as_array()?
        .iter()
        .filter_map(content_block_text)
        .filter(|text| !text.is_empty())
        .collect::<Vec<_>>()
        .join("\n\n");
    (!text.is_empty()).then_some(text)
}

impl CompactionTracker {
    pub(super) fn observe(&mut self, update: &Value) -> Vec<AgentEvent> {
        let kind = update.get("sessionUpdate").and_then(Value::as_str);
        if !matches!(kind, Some("compaction_update" | "compaction_summary_chunk")) {
            return Vec::new();
        }
        let Some(compaction) = update
            .get("compactionId")
            .and_then(Value::as_str)
            .filter(|id| !id.is_empty() && !self.finished.contains(*id))
        else {
            return Vec::new();
        };
        let mut events = self.open(compaction);
        if kind == Some("compaction_summary_chunk") {
            if let Some(text) = chunk_text(update) {
                let summary = self.open.entry(compaction.to_owned()).or_default();
                summary.push_str(&text);
                events.push(AgentEvent::ToolProgress {
                    id: chip_id(compaction),
                    output: cap_text(summary, OUTPUT_CAP),
                    state: None,
                });
            }
            return events;
        }
        let (is_error, output) = match update.get("status").and_then(Value::as_str) {
            Some("completed") => {
                let streamed = self.open.get(compaction).filter(|text| !text.is_empty());
                (false, summary_text(update).or_else(|| streamed.cloned()))
            }
            Some("failed") => (
                true,
                Some(
                    update
                        .get("error")
                        .and_then(Value::as_str)
                        .filter(|error| !error.is_empty())
                        .unwrap_or("Compaction failed")
                        .to_owned(),
                ),
            ),
            Some("cancelled") => (true, Some("Compaction cancelled".to_owned())),
            // `in_progress`, and statuses newer than this client, keep it open.
            _ => return events,
        };
        self.open.remove(compaction);
        self.finished.insert(compaction.to_owned());
        events.push(AgentEvent::ToolResult {
            id: chip_id(compaction),
            is_error,
            output: output.map(|text| cap_text(&text, OUTPUT_CAP)),
            diff: None,
        });
        events
    }

    /// The chip's opening call, once per compaction.
    fn open(&mut self, compaction: &str) -> Vec<AgentEvent> {
        if self.open.contains_key(compaction) {
            return Vec::new();
        }
        self.open.insert(compaction.to_owned(), String::new());
        vec![AgentEvent::ToolCall {
            id: chip_id(compaction),
            call: ToolCall::Unknown {
                name: COMPACTION_TOOL_NAME.into(),
                input: None,
            },
        }]
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn opening(id: &str) -> AgentEvent {
        AgentEvent::ToolCall {
            id: chip_id(id),
            call: ToolCall::Unknown {
                name: COMPACTION_TOOL_NAME.into(),
                input: None,
            },
        }
    }

    fn update(id: &str, status: &str) -> Value {
        json!({ "sessionUpdate": "compaction_update", "compactionId": id, "status": status })
    }

    fn chunk(id: &str, text: &str) -> Value {
        json!({
            "sessionUpdate": "compaction_summary_chunk",
            "compactionId": id,
            "content": { "type": "text", "text": text },
        })
    }

    #[test]
    fn streamed_summary_becomes_the_completed_result() {
        let mut tracker = CompactionTracker::default();
        assert_eq!(
            tracker.observe(&update("c1", "in_progress")),
            vec![opening("c1")]
        );
        assert!(tracker.observe(&update("c1", "in_progress")).is_empty());
        assert_eq!(
            tracker.observe(&chunk("c1", "Fixed the ")),
            vec![AgentEvent::ToolProgress {
                id: chip_id("c1"),
                output: "Fixed the ".into(),
                state: None,
            }]
        );
        assert_eq!(
            tracker.observe(&chunk("c1", "parser.")),
            vec![AgentEvent::ToolProgress {
                id: chip_id("c1"),
                output: "Fixed the parser.".into(),
                state: None,
            }]
        );
        assert_eq!(
            tracker.observe(&update("c1", "completed")),
            vec![AgentEvent::ToolResult {
                id: chip_id("c1"),
                is_error: false,
                output: Some("Fixed the parser.".into()),
                diff: None,
            }]
        );
        // Resolved ids are never reopened by a late frame.
        assert!(tracker.observe(&chunk("c1", "late")).is_empty());
        assert!(tracker.observe(&update("c1", "completed")).is_empty());
    }

    #[test]
    fn materialized_summary_wins_and_a_bare_completion_opens_the_chip() {
        let mut tracker = CompactionTracker::default();
        let mut done = update("c2", "completed");
        done["summary"] = json!([
            { "type": "text", "text": "First." },
            { "type": "image", "data": "...", "mimeType": "image/png" },
            { "type": "text", "text": "Second." },
        ]);
        assert_eq!(
            tracker.observe(&done),
            vec![
                opening("c2"),
                AgentEvent::ToolResult {
                    id: chip_id("c2"),
                    is_error: false,
                    output: Some("First.\n\nSecond.".into()),
                    diff: None,
                },
            ]
        );
    }

    #[test]
    fn failure_and_cancellation_resolve_as_errors() {
        let mut tracker = CompactionTracker::default();
        tracker.observe(&update("c3", "in_progress"));
        let mut failed = update("c3", "failed");
        failed["error"] = json!("summary model timed out");
        assert_eq!(
            tracker.observe(&failed),
            vec![AgentEvent::ToolResult {
                id: chip_id("c3"),
                is_error: true,
                output: Some("summary model timed out".into()),
                diff: None,
            }]
        );
        tracker.observe(&update("c4", "in_progress"));
        assert!(matches!(
            &tracker.observe(&update("c4", "cancelled"))[..],
            [AgentEvent::ToolResult { is_error: true, output: Some(text), .. }]
                if text == "Compaction cancelled"
        ));
    }

    #[test]
    fn unknown_statuses_and_other_updates_are_ignored() {
        let mut tracker = CompactionTracker::default();
        assert_eq!(
            tracker.observe(&update("c5", "_graff_paused")),
            vec![opening("c5")]
        );
        assert!(tracker.observe(&update("c5", "_graff_paused")).is_empty());
        let no_id = json!({ "sessionUpdate": "compaction_update", "status": "completed" });
        assert!(tracker.observe(&no_id).is_empty());
        let usage = json!({ "sessionUpdate": "usage_update", "used": 1, "size": 2 });
        assert!(tracker.observe(&usage).is_empty());
    }
}
