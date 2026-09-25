//! Graff's own worktrees, from Harness's side: where a session actually
//! runs (reported in the session/new|load reply) and the `graff worktree`
//! lifecycle commands the UI's worktree card drives.

use std::path::Path;

use serde::Serialize;
use serde_json::Value;

use crate::HarnessError;

/// Where Graff runs the session, when that is one of its worktrees:
/// `_meta["graff/worktree"].path` (explicit `null` = the main checkout),
/// else, for builds before that field, the reply's non-spec root `cwd`.
pub(super) fn session_worktree(reply: &Value) -> Option<String> {
    if let Some(meta) = reply.get("_meta").and_then(|m| m.get("graff/worktree")) {
        return meta.get("path").and_then(Value::as_str).map(str::to_owned);
    }
    reply
        .get("cwd")
        .and_then(Value::as_str)
        .filter(|cwd| harness_proto::graff_worktree::GraffWorktree::from_path(cwd).is_some())
        .map(str::to_owned)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GraffWorktreeAction {
    /// Squash-land `worktree-<name>` onto the main checkout's branch.
    Merge,
    /// Remove the tree only if its work exists elsewhere.
    Archive,
    /// Remove the tree and branch; refuses unique work.
    Remove,
    /// Remove even with unique work (`--discard`).
    Discard,
}

impl GraffWorktreeAction {
    pub fn parse(action: &str) -> Option<Self> {
        Some(match action {
            "merge" => Self::Merge,
            "archive" => Self::Archive,
            "remove" => Self::Remove,
            "discard" => Self::Discard,
            _ => return None,
        })
    }

    fn args<'a>(self, name: &'a str) -> Vec<&'a str> {
        match self {
            Self::Merge => vec!["worktree", "merge", name],
            Self::Archive => vec!["worktree", "archive", name],
            Self::Remove => vec!["worktree", "remove", name],
            Self::Discard => vec!["worktree", "remove", name, "--discard"],
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum GraffWorktreeOutcome {
    /// The tree is gone (merged, archived or removed).
    Done,
    /// Graff kept the tree on purpose (dirty, unique commits, …).
    Kept,
    Failed,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GraffWorktreeResult {
    pub outcome: GraffWorktreeOutcome,
    /// Graff's own words, shown to the user as-is.
    pub message: String,
}

/// `graff worktree` exits 0 even when it refuses, so its leading marker is
/// the verdict: `✓` done, `kept`/`⚠` kept, `✗` (or anything else) failed.
pub fn classify_worktree_output(output: &str) -> GraffWorktreeOutcome {
    let first = output.lines().map(str::trim).find(|l| !l.is_empty()).unwrap_or("");
    if first.starts_with('✓') {
        GraffWorktreeOutcome::Done
    } else if first.starts_with("kept") || first.starts_with('⚠') {
        GraffWorktreeOutcome::Kept
    } else {
        GraffWorktreeOutcome::Failed
    }
}

/// Run a `graff worktree` lifecycle command for tree `name` from its main
/// checkout `root` (Graff resolves `.graff/worktrees/<name>` from there).
pub async fn run_graff_worktree_action(
    root: &Path,
    name: &str,
    action: GraffWorktreeAction,
) -> Result<GraffWorktreeResult, HarnessError> {
    if !harness_proto::graff_worktree::valid_name(name) {
        return Err(HarnessError::Protocol(format!("not a Graff worktree name: {name}")));
    }
    let (program, _) = super::AcpHarness::graff().resolve_program(false).await?;
    let output = tokio::process::Command::new(&program)
        .args(action.args(name))
        .current_dir(root)
        .env("NO_COLOR", "1")
        .stdin(std::process::Stdio::null())
        .output()
        .await
        .map_err(|e| HarnessError::Protocol(format!("could not run graff: {e}")))?;
    let mut text = String::from_utf8_lossy(&output.stdout).trim().to_owned();
    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_owned();
    if text.is_empty() {
        text = stderr;
    }
    let mut outcome = classify_worktree_output(&text);
    if !output.status.success() {
        outcome = GraffWorktreeOutcome::Failed;
    }
    if text.is_empty() {
        text = format!("graff worktree exited with {}", output.status);
    }
    Ok(GraffWorktreeResult { outcome, message: text })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn classifies_graff_worktree_markers() {
        use GraffWorktreeOutcome::*;
        // Real 0.0.302.x output (every one of these exited 0).
        let cases = [
            ("✓ landed worktree-x → current branch as one commit, removed the worktree", Done),
            ("kept /r/.graff/worktrees/x — has commits that exist ONLY on this branch", Kept),
            ("⚠ nothing to archive", Kept),
            ("✗ workspace has uncommitted files or could not be verified", Failed),
            ("", Failed),
            ("\n  ✓ removed\n", Done),
        ];
        for (text, want) in cases {
            assert_eq!(classify_worktree_output(text), want, "{text:?}");
        }
    }

    #[test]
    fn reads_the_session_worktree_from_meta_or_legacy_cwd() {
        let meta = json!({"sessionId": "s", "_meta": {"graff/worktree": {"path": "/r/.graff/worktrees/a"}}});
        assert_eq!(session_worktree(&meta).as_deref(), Some("/r/.graff/worktrees/a"));
        let main_checkout = json!({"sessionId": "s", "cwd": "/r/.graff/worktrees/a", "_meta": {"graff/worktree": null}});
        assert_eq!(session_worktree(&main_checkout), None, "explicit null wins over the legacy field");
        let legacy = json!({"sessionId": "s", "cwd": "/r/.graff/worktrees/b"});
        assert_eq!(session_worktree(&legacy).as_deref(), Some("/r/.graff/worktrees/b"));
        assert_eq!(session_worktree(&json!({"sessionId": "s", "cwd": "/r"})), None);
    }
}
