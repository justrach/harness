//! Codex compaction chips. Codex compacts through OpenAI's Responses API,
//! which returns an encrypted `compaction` item; Codex keeps it in its own
//! rollout and sends it back on later turns. The app-server reports only a
//! `contextCompaction` item with an id, so Harness never holds the item and
//! records just its sizes: the context before (the last meter reading) and
//! after (the first reading once it lands).

use harness_proto::{AgentEvent, CompactionKind, CompactionMeta};
use serde_json::Value;

use super::normalize::{Phase, item_type};

#[derive(Default)]
pub(super) struct CompactionChips {
    /// The latest context reading, from `thread/tokenUsage/updated`.
    last_tokens: Option<u64>,
    /// Compactions opened and not yet resolved, by chip id.
    open: Vec<(String, CompactionMeta)>,
    /// A resolved compaction still waiting for its after-size.
    awaiting: Option<(String, CompactionMeta)>,
}

fn chip_id(item: &Value) -> Option<String> {
    let id = item.get("id").and_then(Value::as_str)?;
    (!id.is_empty()).then(|| format!("codex-compaction-{id}"))
}

impl CompactionChips {
    /// `item/started` or `item/completed`; anything but `contextCompaction`
    /// yields nothing.
    pub(super) fn item(&mut self, phase: Phase, item: &Value) -> Vec<AgentEvent> {
        if item_type(item) != "contextCompaction" {
            return Vec::new();
        }
        let Some(id) = chip_id(item) else {
            return Vec::new();
        };
        let mut events = Vec::new();
        let meta = match self.open.iter().position(|(open, _)| *open == id) {
            Some(at) => self.open.remove(at).1,
            None => {
                let mut meta = CompactionMeta::new(CompactionKind::Opaque);
                meta.tokens_before = self.last_tokens;
                events.push(AgentEvent::ToolCall {
                    id: id.clone(),
                    call: meta.call(),
                });
                meta
            }
        };
        match phase {
            Phase::Started => self.open.push((id, meta)),
            Phase::Completed => {
                events.push(AgentEvent::ToolResult {
                    id: id.clone(),
                    is_error: false,
                    output: None,
                    diff: None,
                });
                self.awaiting = Some((id, meta));
            }
        }
        events
    }

    /// A context reading. The first one after a compaction lands is its
    /// after-size, re-stamped onto the chip.
    pub(super) fn context(&mut self, tokens: Option<u64>) -> Option<AgentEvent> {
        let tokens = tokens?;
        self.last_tokens = Some(tokens);
        let (id, mut meta) = self.awaiting.take()?;
        meta.tokens_after = Some(tokens);
        Some(AgentEvent::ToolCall {
            id,
            call: meta.call(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn compaction() -> Value {
        json!({"id": "k1", "type": "contextCompaction"})
    }

    fn meta(event: &AgentEvent) -> CompactionMeta {
        match event {
            AgentEvent::ToolCall { call, .. } => call.compaction().unwrap(),
            other => panic!("not a call: {other:?}"),
        }
    }

    #[test]
    fn records_the_context_before_and_after_an_opaque_compaction() {
        let mut chips = CompactionChips::default();
        assert_eq!(chips.context(Some(181_000)), None);
        let started = chips.item(Phase::Started, &compaction());
        assert_eq!(started.len(), 1);
        let opened = meta(&started[0]);
        assert_eq!(opened.kind, CompactionKind::Opaque);
        assert_eq!(opened.tokens_before, Some(181_000));
        let done = chips.item(Phase::Completed, &compaction());
        assert!(matches!(
            &done[..],
            [AgentEvent::ToolResult { id, is_error: false, output: None, .. }]
                if id == "codex-compaction-k1"
        ));
        let after = chips.context(Some(24_000)).unwrap();
        assert_eq!(meta(&after).tokens_after, Some(24_000));
        assert_eq!(meta(&after).freed(), Some(157_000));
        // Only the first reading belongs to the compaction.
        assert_eq!(chips.context(Some(30_000)), None);
    }

    #[test]
    fn a_bare_completion_opens_the_chip_and_other_items_are_ignored() {
        let mut chips = CompactionChips::default();
        let done = chips.item(Phase::Completed, &compaction());
        assert_eq!(done.len(), 2);
        assert_eq!(meta(&done[0]).tokens_before, None);
        let other = json!({"id": "m1", "type": "agentMessage"});
        assert!(chips.item(Phase::Started, &other).is_empty());
        let no_id = json!({"type": "contextCompaction"});
        assert!(chips.item(Phase::Started, &no_id).is_empty());
        assert_eq!(chips.context(None), None);
    }
}
