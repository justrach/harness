//! Relay depth for peer mail that never enters a Harness transcript
//! (codegraff#1803).
//!
//! Mail sent through graff's peer inbox reaches the recipient's model but not
//! its Harness transcript, so the recipient's next `send_message` would read
//! depth 0 and two busy graff chats could relay past the cap. The sender
//! records the depth it delivered at, keyed by recipient chat; the recipient
//! counts the larger of that and its transcript's depth.
//!
//! Each chat's `harness mcp` is its own process, so the ledger is a directory
//! of small files on this device (peer-inbox delivery is device-local too).
//! An entry stops counting after [`ENTRY_TTL_MS`], or once a person prompts
//! that chat after it was written.

use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

use anyhow::{Context, anyhow};
use serde::{Deserialize, Serialize};

use super::peer_messages::{self, MAX_DEPTH};
use crate::transcript::RenderedMessage;
use harness_doc::MessageRole;

pub(super) const ENTRY_TTL_MS: i64 = 30 * 60 * 1000;

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Entry {
    depth: u32,
    from: Option<String>,
    at_ms: i64,
}

pub(crate) struct RelayLedger {
    dir: Option<PathBuf>,
}

impl RelayLedger {
    /// `~/.harness/peer-relay`; without a home the ledger cannot record, so
    /// peer-inbox delivery is not used.
    pub(crate) fn on_device() -> Self {
        Self {
            dir: std::env::var_os("HOME")
                .map(|home| Path::new(&home).join(".harness").join("peer-relay")),
        }
    }

    #[cfg(test)]
    pub(crate) fn at(dir: PathBuf) -> Self {
        Self { dir: Some(dir) }
    }

    fn path(&self, chat_id: &str) -> anyhow::Result<PathBuf> {
        let dir = self
            .dir
            .as_ref()
            .ok_or_else(|| anyhow!("no home directory for the relay ledger"))?;
        let name: String = chat_id
            .chars()
            .map(|c| {
                if c.is_ascii_alphanumeric() || c == '-' || c == '_' {
                    c
                } else {
                    '_'
                }
            })
            .collect();
        Ok(dir.join(format!("{name}.json")))
    }

    /// Note that `chat_id` was sent peer mail at `depth`. Keeps a higher
    /// depth already recorded: a concurrent sender never lowers the count.
    pub(crate) fn record(
        &self,
        chat_id: &str,
        depth: u32,
        from: Option<&str>,
        now_ms: i64,
    ) -> anyhow::Result<()> {
        let path = self.path(chat_id)?;
        let kept = match self.read(&path) {
            Some((recorded, at)) if now_ms - at <= ENTRY_TTL_MS => {
                recorded.unwrap_or(MAX_DEPTH - 1)
            }
            _ => 0,
        };
        let entry = Entry {
            depth: depth.max(kept),
            from: from.map(str::to_owned),
            at_ms: now_ms,
        };
        let dir = path.parent().context("relay ledger path has no parent")?;
        std::fs::create_dir_all(dir)
            .with_context(|| format!("could not create {}", dir.display()))?;
        let tmp = dir.join(format!(".{}.tmp", uuid::Uuid::new_v4()));
        std::fs::write(&tmp, serde_json::to_vec(&entry)?)
            .with_context(|| format!("could not write {}", tmp.display()))?;
        std::fs::rename(&tmp, &path).inspect_err(|_| {
            let _ = std::fs::remove_file(&tmp);
        })?;
        Ok(())
    }

    /// A person's peer-inbox send starts a new chain for the recipient.
    pub(crate) fn clear(&self, chat_id: &str) {
        if let Ok(path) = self.path(chat_id) {
            let _ = std::fs::remove_file(path);
        }
    }

    /// The depth `chat_id` last received through the peer inbox, given its
    /// own transcript: 0 with no entry, an expired one, or a person's prompt
    /// since (those entries are removed). An entry that cannot be read
    /// counts as one hop below the cap: one more hop, no more.
    pub(crate) fn inbound(
        &self,
        chat_id: &str,
        transcript: &[RenderedMessage],
        now_ms: i64,
    ) -> u32 {
        let Ok(path) = self.path(chat_id) else {
            return 0;
        };
        let Some((depth, at)) = self.read(&path) else {
            return 0;
        };
        let prompted_since = transcript.iter().any(|m| {
            m.role == MessageRole::User
                && m.created_at > at
                && peer_messages::is_human_prompt(&m.text)
        });
        if now_ms - at > ENTRY_TTL_MS || prompted_since {
            let _ = std::fs::remove_file(&path);
            return 0;
        }
        depth.unwrap_or(MAX_DEPTH - 1)
    }

    /// `(depth, written at)`; the depth is `None` when the file is there but
    /// unreadable, dated by its modification time.
    fn read(&self, path: &Path) -> Option<(Option<u32>, i64)> {
        let bytes = std::fs::read(path).ok()?;
        if let Ok(entry) = serde_json::from_slice::<Entry>(&bytes) {
            return Some((Some(entry.depth), entry.at_ms));
        }
        let modified = std::fs::metadata(path)
            .and_then(|m| m.modified())
            .ok()
            .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
            .map_or(i64::MAX, |d| d.as_millis() as i64);
        Some((None, modified))
    }
}
