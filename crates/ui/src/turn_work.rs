//! What the agent's latest turn did, reduced for the chat's work cues: the
//! "N files changed" card that opens the Changes pane, and the floating
//! "Running ..." pill shown while a command runs.

use harness_doc::{MessagePart, MessageRole, SessionMessageEntry};
use harness_proto::ToolCall;

mod card;
pub use card::changes_cue;

/// Files the latest agent turn edited, with summed line counts.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TurnChanges {
    /// Edited paths in first-touch order, each once.
    pub files: Vec<String>,
    pub additions: u64,
    pub deletions: u64,
}

impl TurnChanges {
    /// "1 file changed" / "3 files changed".
    pub fn title(&self) -> String {
        match self.files.len() {
            1 => "1 file changed".to_string(),
            n => format!("{n} files changed"),
        }
    }

    /// Up to three file names (not full paths), then "+N more".
    pub fn names(&self) -> String {
        let mut names: Vec<&str> = self
            .files
            .iter()
            .take(3)
            .map(|path| path.rsplit('/').next().unwrap_or(path))
            .collect();
        let more = self.files.len().saturating_sub(3);
        let more_label = format!("+{more} more");
        if more > 0 {
            names.push(&more_label);
        }
        names.join(", ")
    }
}

/// The entries of the latest turn: everything after the last user prompt.
fn latest_turn(entries: &[SessionMessageEntry]) -> &[SessionMessageEntry] {
    let start = entries
        .iter()
        .rposition(|entry| entry.role == MessageRole::User)
        .map_or(0, |ix| ix + 1);
    &entries[start..]
}

/// Successful file edits in the latest turn, or `None` when it changed none.
pub fn latest_turn_changes(entries: &[SessionMessageEntry]) -> Option<TurnChanges> {
    let mut changes = TurnChanges {
        files: Vec::new(),
        additions: 0,
        deletions: 0,
    };
    for part in latest_turn(entries).iter().flat_map(|entry| entry.parts.iter()) {
        let MessagePart::Tool {
            call,
            is_error,
            diff,
            diff_stats,
            ..
        } = part
        else {
            continue;
        };
        if *is_error {
            continue;
        }
        let path = match call {
            ToolCall::WriteFile { path, .. } | ToolCall::EditFile { path, .. } => Some(path.clone()),
            ToolCall::ApplyPatch { path } => path.clone(),
            _ => continue,
        };
        let stats: Vec<harness_doc::ToolDiffStat> = match (diff, diff_stats) {
            (Some(diff), _) => vec![harness_doc::diff_stat(diff)],
            (None, Some(stats)) => stats.clone(),
            (None, None) => Vec::new(),
        };
        let mut paths: Vec<String> = stats.iter().map(|stat| stat.path.clone()).collect();
        if paths.is_empty() {
            paths.extend(path);
        }
        for stat in &stats {
            changes.additions += stat.additions;
            changes.deletions += stat.deletions;
        }
        for path in paths {
            if !changes.files.contains(&path) {
                changes.files.push(path);
            }
        }
    }
    (!changes.files.is_empty()).then_some(changes)
}

/// The command the latest turn is running right now (an unresolved `Exec`),
/// trimmed to one short line for the floating pill.
pub fn running_command(entries: &[SessionMessageEntry]) -> Option<String> {
    latest_turn(entries)
        .iter()
        .flat_map(|entry| entry.parts.iter())
        .rev()
        .find_map(|part| match part {
            MessagePart::Tool {
                call: ToolCall::Exec { command },
                resolved: false,
                ..
            } => Some(short_command(command)),
            _ => None,
        })
}

/// First line of a command, at most 40 characters.
fn short_command(command: &str) -> String {
    let line = command.lines().next().unwrap_or("").trim();
    if line.chars().count() > 40 {
        let cut: String = line.chars().take(39).collect();
        format!("{cut}\u{2026}")
    } else {
        line.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(role: MessageRole, parts: Vec<MessagePart>) -> SessionMessageEntry {
        let mut entry: SessionMessageEntry = serde_json::from_value(serde_json::json!({
            "id": "e",
            "role": if role == MessageRole::User { "user" } else { "assistant" },
            "parts": [],
            "createdAt": 0,
            "deviceId": "d",
        }))
        .expect("minimal entry");
        entry.parts = parts;
        entry
    }

    fn tool(id: &str, call: ToolCall, resolved: bool, is_error: bool) -> MessagePart {
        serde_json::from_value(serde_json::json!({
            "kind": "tool",
            "id": id,
            "call": call,
            "resolved": resolved,
            "isError": is_error,
        }))
        .expect("tool part")
    }

    fn edit(path: &str) -> ToolCall {
        ToolCall::EditFile {
            path: path.into(),
            old_string: None,
            new_string: None,
        }
    }

    #[test]
    fn counts_only_the_latest_turn_and_skips_failed_edits() {
        let entries = vec![
            entry(MessageRole::User, vec![]),
            entry(MessageRole::Assistant, vec![tool("a", edit("old.rs"), true, false)]),
            entry(MessageRole::User, vec![]),
            entry(
                MessageRole::Assistant,
                vec![
                    tool("b", edit("src/a.rs"), true, false),
                    tool("c", edit("src/a.rs"), true, false),
                    tool("d", edit("src/b.rs"), true, true),
                    tool("e", ToolCall::Exec { command: "ls".into() }, true, false),
                ],
            ),
        ];
        let changes = latest_turn_changes(&entries).expect("one file");
        assert_eq!(changes.files, vec!["src/a.rs".to_string()]);
        assert_eq!(changes.title(), "1 file changed");
        assert_eq!(changes.names(), "a.rs");
    }

    #[test]
    fn no_edits_means_no_card() {
        let entries = vec![
            entry(MessageRole::User, vec![]),
            entry(
                MessageRole::Assistant,
                vec![tool("a", ToolCall::Exec { command: "ls".into() }, true, false)],
            ),
        ];
        assert_eq!(latest_turn_changes(&entries), None);
    }

    #[test]
    fn names_cap_at_three() {
        let changes = TurnChanges {
            files: ["a/x.rs", "y.rs", "z.rs", "w.rs"].map(String::from).to_vec(),
            additions: 0,
            deletions: 0,
        };
        assert_eq!(changes.title(), "4 files changed");
        assert_eq!(changes.names(), "x.rs, y.rs, z.rs, +1 more");
    }

    #[test]
    fn running_command_is_the_unresolved_exec() {
        let entries = vec![
            entry(MessageRole::User, vec![]),
            entry(
                MessageRole::Assistant,
                vec![
                    tool("a", ToolCall::Exec { command: "ls".into() }, true, false),
                    tool("b", ToolCall::Exec { command: "cargo test -p sgbus\nmore".into() }, false, false),
                ],
            ),
        ];
        let command = running_command(&entries).expect("running");
        assert_eq!(command, "cargo test -p sgbus");
        let done = vec![entries[0].clone(), entry(MessageRole::Assistant, vec![tool("a", ToolCall::Exec { command: "ls".into() }, true, false)])];
        assert_eq!(running_command(&done), None);
    }
}
