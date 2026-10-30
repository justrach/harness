//! How the selected chat's context moved over the session: one sample per
//! context meter update, plus each compaction with its kind and sizes.
//!
//! Samples hold the reported total and the per-slot estimate from
//! [`breakdown`]; compactions come from the chips' [`CompactionMeta`]. The
//! recorder lives in memory for the app session only: it starts at the
//! first meter update seen and keeps the latest [`MAX_SAMPLES`].
use std::collections::VecDeque;

use harness_doc::{MessagePart, MessageRole, SessionMessageEntry};
use harness_proto::{CompactionKind, ContextUsage};
use serde::Serialize;

use crate::context_window::{Slot, breakdown};

/// Samples kept per chat.
pub const MAX_SAMPLES: usize = 240;

/// The context at one meter update.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Sample {
    /// User turns in the transcript at the time.
    pub turn: u32,
    pub tokens: u64,
    pub window: u64,
    /// The per-slot estimate, summing to `tokens`.
    pub slots: Vec<(String, u64)>,
    /// Finished compactions in the transcript at the time.
    pub compactions: usize,
}

/// One finished compaction.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Compaction {
    /// The chip's id.
    pub id: String,
    /// The user turn it followed.
    pub turn: u32,
    /// `opaque`, `summary`, or `unknown` for chips without a record.
    pub kind: &'static str,
    pub tokens_before: Option<u64>,
    pub tokens_after: Option<u64>,
    /// The opaque item's or summary's own size, when reported.
    pub item_tokens: Option<u64>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Trajectory {
    pub samples: VecDeque<Sample>,
    pub compactions: Vec<Compaction>,
}

fn slot_key(slot: Slot) -> &'static str {
    match slot {
        Slot::History => "history",
        Slot::Recent => "recent",
        Slot::Files => "files",
        Slot::Commands => "commands",
        Slot::Search => "search",
        Slot::Tools => "tools",
        Slot::System => "system",
    }
}

impl Trajectory {
    /// Record the meter `usage` against `transcript`. Returns whether
    /// anything new was recorded.
    pub fn observe(
        &mut self,
        usage: Option<ContextUsage>,
        transcript: &[SessionMessageEntry],
    ) -> bool {
        let mut changed = self.scan_compactions(transcript);
        let Some(b) = breakdown(usage, transcript) else {
            return changed;
        };
        let turn = turns(transcript, usize::MAX);
        let sample = Sample {
            turn,
            tokens: b.tokens,
            window: b.window,
            slots: b
                .items
                .iter()
                .map(|(slot, n)| (slot_key(*slot).to_owned(), *n))
                .collect(),
            compactions: transcript
                .iter()
                .flat_map(|e| &e.parts)
                .filter(|p| {
                    matches!(p, MessagePart::Tool { call, resolved: true, .. } if call.is_compaction())
                })
                .count(),
        };
        if self.samples.back() != Some(&sample) {
            if self.samples.len() == MAX_SAMPLES {
                self.samples.pop_front();
            }
            self.samples.push_back(sample);
            changed = true;
        }
        changed
    }

    fn scan_compactions(&mut self, transcript: &[SessionMessageEntry]) -> bool {
        let mut changed = false;
        for (index, entry) in transcript.iter().enumerate() {
            for part in &entry.parts {
                let MessagePart::Tool {
                    id, call, resolved, ..
                } = part
                else {
                    continue;
                };
                if !*resolved || !call.is_compaction() {
                    continue;
                }
                let meta = call.compaction();
                let record = Compaction {
                    id: id.clone(),
                    turn: turns(transcript, index),
                    kind: match meta.as_ref().map(|m| m.kind) {
                        Some(CompactionKind::Opaque) => "opaque",
                        Some(CompactionKind::Summary) => "summary",
                        None => "unknown",
                    },
                    tokens_before: meta.as_ref().and_then(|m| m.tokens_before),
                    tokens_after: meta.as_ref().and_then(|m| m.tokens_after),
                    item_tokens: meta.as_ref().and_then(|m| m.item_tokens),
                };
                match self.compactions.iter_mut().find(|c| c.id == record.id) {
                    Some(known) if *known == record => {}
                    Some(known) => {
                        *known = record;
                        changed = true;
                    }
                    None => {
                        self.compactions.push(record);
                        changed = true;
                    }
                }
            }
        }
        changed
    }

    /// Fill of the window per sample, 0 to 1, oldest first.
    pub fn fills(&self) -> Vec<f32> {
        self.samples
            .iter()
            .map(|s| (s.tokens as f32 / s.window.max(1) as f32).clamp(0.0, 1.0))
            .collect()
    }

    /// Indices of samples that are the first after a compaction, with that
    /// compaction's kind.
    pub fn compaction_points(&self) -> Vec<(usize, &'static str)> {
        let mut seen = self.samples.front().map_or(0, |s| s.compactions);
        let mut points = Vec::new();
        for (index, sample) in self.samples.iter().enumerate() {
            if sample.compactions > seen {
                let kind = self
                    .compactions
                    .get(sample.compactions - 1)
                    .map_or("unknown", |c| c.kind);
                points.push((index, kind));
            }
            seen = sample.compactions;
        }
        points
    }

    pub fn to_json(&self) -> serde_json::Value {
        serde_json::to_value(self).unwrap_or_default()
    }
}

/// User messages among the first `upto` entries.
fn turns(transcript: &[SessionMessageEntry], upto: usize) -> u32 {
    transcript
        .iter()
        .take(upto)
        .filter(|e| e.role == MessageRole::User)
        .count() as u32
}

#[cfg(test)]
mod tests {
    use super::*;
    use harness_proto::CompactionMeta;

    fn entry(role: MessageRole, parts: Vec<MessagePart>) -> SessionMessageEntry {
        SessionMessageEntry {
            id: "m".into(),
            role,
            parts,
            created_at: 0,
            device_id: "d".into(),
            status: None,
            continuation_of: None,
            duration_ms: None,
        }
    }

    fn text(n: usize) -> MessagePart {
        MessagePart::Text {
            id: "t".into(),
            text: "x".repeat(n),
        }
    }

    fn chip(id: &str, meta: &CompactionMeta, resolved: bool) -> MessagePart {
        serde_json::from_value(serde_json::json!({
            "kind": "tool", "id": id, "call": meta.call(), "resolved": resolved,
        }))
        .unwrap()
    }

    fn meter(tokens: u64) -> Option<ContextUsage> {
        Some(ContextUsage {
            tokens: Some(tokens),
            window: Some(100_000),
            ..Default::default()
        })
    }

    #[test]
    fn records_turns_meters_and_compactions() {
        let mut t = Trajectory::default();
        let mut transcript = vec![entry(MessageRole::User, vec![text(4_000)])];
        assert!(t.observe(meter(20_000), &transcript));
        // The same reading twice is one sample.
        assert!(!t.observe(meter(20_000), &transcript));

        let mut meta = CompactionMeta::new(CompactionKind::Opaque);
        meta.tokens_before = Some(90_000);
        transcript.push(entry(MessageRole::User, vec![text(4_000)]));
        transcript.push(entry(MessageRole::Assistant, vec![chip("c1", &meta, true)]));
        assert!(t.observe(meter(90_000), &transcript));
        meta.tokens_after = Some(12_000);
        transcript[2] = entry(MessageRole::Assistant, vec![chip("c1", &meta, true)]);
        assert!(t.observe(meter(12_000), &transcript));

        assert_eq!(
            t.samples
                .iter()
                .map(|s| (s.turn, s.tokens))
                .collect::<Vec<_>>(),
            vec![(1, 20_000), (2, 90_000), (2, 12_000)]
        );
        assert_eq!(
            t.samples[0].slots,
            vec![("history".into(), 1_000), ("system".into(), 19_000)]
        );
        assert_eq!(t.compactions.len(), 1);
        let c = &t.compactions[0];
        assert_eq!(
            (c.kind, c.turn, c.tokens_before, c.tokens_after),
            ("opaque", 2, Some(90_000), Some(12_000))
        );
        assert_eq!(t.fills(), vec![0.2, 0.9, 0.12]);
        assert_eq!(t.compaction_points(), vec![(1, "opaque")]);
        assert_eq!(t.to_json()["compactions"][0]["tokensAfter"], 12_000);
    }

    #[test]
    fn keeps_only_the_latest_samples() {
        let mut t = Trajectory::default();
        for n in 0..(MAX_SAMPLES as u64 + 10) {
            t.observe(meter(n + 1), &[]);
        }
        assert_eq!(t.samples.len(), MAX_SAMPLES);
        assert_eq!(t.samples.front().map(|s| s.tokens), Some(11));
    }
}
