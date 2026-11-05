//! What a context-compaction chip records about the compaction it shows.
//!
//! Agents compact in one of two ways, and the client can tell them apart:
//!
//! - **Opaque**: the provider returns an encrypted compaction item the agent
//!   passes back on later turns without reading it (OpenAI's Responses API
//!   `compaction` item, which Codex keeps as `encrypted_content`). Nobody on
//!   the client side can read it, so only its size is ever shown.
//! - **Summary**: a readable summary replaces the older turns (ACP
//!   `compaction_update` summaries, Claude Code's `/compact`, Pi).
//!
//! The record rides in the chip's [`ToolCall::Unknown`] `input`, so it is
//! stored and synced with the chat like any other call, while the summary
//! text itself stays out of the doc with every other tool output.

use serde::{Deserialize, Serialize};

use crate::{COMPACTION_TOOL_NAME, ToolCall};

/// How the agent compacted.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CompactionKind {
    /// An encrypted item from the provider, passed back unread.
    Opaque,
    /// A readable summary of the older turns.
    Summary,
}

/// One compaction's sizes, as far as the agent reported them. Each count is
/// `None` when the agent did not say, never a guess.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CompactionMeta {
    pub kind: CompactionKind,
    /// Context tokens just before the compaction.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tokens_before: Option<u64>,
    /// Context tokens on the first measurement after it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tokens_after: Option<u64>,
    /// Tokens the compaction item or summary itself takes.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub item_tokens: Option<u64>,
    /// `auto` or `manual`, when the agent says which.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub trigger: Option<String>,
}

impl CompactionMeta {
    pub fn new(kind: CompactionKind) -> Self {
        Self {
            kind,
            tokens_before: None,
            tokens_after: None,
            item_tokens: None,
            trigger: None,
        }
    }

    /// The chip call carrying this record.
    pub fn call(&self) -> ToolCall {
        ToolCall::Unknown {
            name: COMPACTION_TOOL_NAME.into(),
            input: serde_json::to_value(self).ok(),
        }
    }

    /// Tokens the compaction freed, when both sides were measured.
    pub fn freed(&self) -> Option<u64> {
        Some(self.tokens_before?.saturating_sub(self.tokens_after?))
    }
}

/// Text at the usual ~4 bytes a token.
pub fn text_tokens(text: &str) -> u64 {
    (text.len() as u64).div_ceil(4)
}

impl ToolCall {
    /// Whether this is a context-compaction chip.
    pub fn is_compaction(&self) -> bool {
        matches!(self, ToolCall::Unknown { name, .. } if name == COMPACTION_TOOL_NAME)
    }

    /// The compaction record on a compaction chip. Chips from before the
    /// record existed, or from agents that report nothing, yield `None`.
    pub fn compaction(&self) -> Option<CompactionMeta> {
        match self {
            ToolCall::Unknown { name, input } if name == COMPACTION_TOOL_NAME => {
                serde_json::from_value(input.clone()?).ok()
            }
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_record_round_trips_through_the_chip() {
        let mut meta = CompactionMeta::new(CompactionKind::Opaque);
        meta.tokens_before = Some(180_000);
        meta.tokens_after = Some(30_000);
        let call = meta.call();
        assert!(call.is_compaction());
        assert_eq!(meta.freed(), Some(150_000));
        assert_eq!(call.compaction(), Some(meta));
        assert_eq!(
            serde_json::to_value(&call).unwrap()["input"],
            serde_json::json!({"kind": "opaque", "tokensBefore": 180_000, "tokensAfter": 30_000})
        );
    }

    #[test]
    fn chips_without_a_record_read_as_unknown() {
        let bare = ToolCall::Unknown {
            name: COMPACTION_TOOL_NAME.into(),
            input: None,
        };
        assert!(bare.is_compaction());
        assert_eq!(bare.compaction(), None);
        let other = ToolCall::Unknown {
            name: "Other".into(),
            input: Some(serde_json::json!({"kind": "opaque"})),
        };
        assert!(!other.is_compaction());
        assert_eq!(other.compaction(), None);
        assert_eq!(CompactionMeta::new(CompactionKind::Summary).freed(), None);
        assert_eq!(text_tokens("abcde"), 2);
    }
}
