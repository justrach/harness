//! Native graff peer mail for a working graff chat on this device
//! (codegraff#1803).
//!
//! graff steers only at turn boundaries, so `send_message` used to hold mail
//! for a busy graff chat in the prompt queue until its whole turn ended. graff
//! has its own device-local peer inbox that a running session reads while it
//! works; `graff peer send` posts there and wakes the session. The chat's ACP
//! session id is the address. Anything that cannot be delivered that way
//! (another device, no session id yet, a failed send) falls back to the queue.

use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;

use anyhow::{Context, anyhow, bail};
use async_trait::async_trait;
use harness_proto::{Chat, HarnessId, Session};
use tokio::io::AsyncWriteExt;

/// `graff peer send` posts to a local JSONL room and makes one bounded wake
/// attempt; it should never take long.
const SEND_TIMEOUT: Duration = Duration::from_secs(15);

/// The graff session that native peer mail reaches for `chat`: a graff chat
/// whose running session is hosted on this device, addressed by the ACP
/// session id the engine recorded at `SessionStarted`.
pub(crate) fn target<'a>(
    chat: &'a Chat,
    harness: HarnessId,
    session: Option<&Session>,
    local_device: &str,
) -> Option<&'a str> {
    if cfg!(windows) || harness != HarnessId::Graff {
        return None;
    }
    let session = session?;
    if session.device_id != local_device || chat.device_id != local_device {
        return None;
    }
    // An empty id is the engine's "do not resume" tombstone.
    chat.harness_session_id
        .as_deref()
        .filter(|id| !id.trim().is_empty())
}

/// Posts one message into a graff session's peer inbox.
#[async_trait]
pub trait PeerSend: Send + Sync {
    /// `from` names the sender in graff's rooms; `to` is the recipient's
    /// session id. Returns graff's confirmation line.
    async fn send(&self, from: &str, to: &str, text: &str) -> anyhow::Result<String>;
}

/// `graff peer send --as FROM --to TO --anyway`, the text on stdin.
pub struct GraffCli;

#[async_trait]
impl PeerSend for GraffCli {
    async fn send(&self, from: &str, to: &str, text: &str) -> anyhow::Result<String> {
        let program = graff_executable();
        let run = async {
            // --anyway: replies to Harness peer mail come back through
            // send_message, never this sender's graff inbox, so there is no
            // unread graff mail for the send to wait on.
            let mut child = tokio::process::Command::new(&program)
                .args(["peer", "send", "--as", from, "--to", to, "--anyway"])
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .kill_on_drop(true)
                .spawn()
                .with_context(|| format!("could not run {}", program.display()))?;
            // Stdin, not an argument: a body starting with `--` would parse as
            // a flag, and graff refuses an oversized one instead of cutting it.
            let mut stdin = child
                .stdin
                .take()
                .ok_or_else(|| anyhow!("graff peer send has no stdin"))?;
            stdin.write_all(text.as_bytes()).await?;
            drop(stdin);
            let output = child.wait_with_output().await?;
            let stdout = String::from_utf8_lossy(&output.stdout).trim().to_owned();
            if !output.status.success() {
                let stderr = String::from_utf8_lossy(&output.stderr).trim().to_owned();
                let reason = [stderr, stdout]
                    .into_iter()
                    .find(|s| !s.is_empty())
                    .unwrap_or_else(|| output.status.to_string());
                bail!("graff peer send failed: {reason}");
            }
            Ok(stdout)
        };
        tokio::time::timeout(SEND_TIMEOUT, run).await.map_err(|_| {
            anyhow!(
                "graff peer send timed out after {}s",
                SEND_TIMEOUT.as_secs()
            )
        })?
    }
}

/// `GRAFF_EXECUTABLE`, else the managed `~/.harness/bin/graff` Harness runs
/// chats with, else `graff` on PATH.
pub(super) fn graff_executable() -> PathBuf {
    if let Some(path) = std::env::var_os("GRAFF_EXECUTABLE").filter(|p| !p.is_empty()) {
        return path.into();
    }
    if let Some(home) = std::env::var_os("HOME") {
        let managed = Path::new(&home).join(".harness").join("bin").join("graff");
        if managed.is_file() {
            return managed;
        }
    }
    PathBuf::from("graff")
}
