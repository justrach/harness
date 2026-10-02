//! Harness tool calls as Codex thread items.
//!
//! The TUI renders by item type: `commandExecution` rows, grouped "Explored" reads and
//! searches (from `commandActions`), and `fileChange` items drawn as syntax-highlighted
//! diffs. Everything is mapped onto those so a tool call looks like it does in Codex.

use std::path::Path;

use harness_proto::{ToolCall, ToolDiff};
use serde_json::{Value, json};

/// How one tool call is shown while it runs.
pub enum Shape {
    /// A command row. `actions` turn reads and searches into grouped "Explored" lines.
    Command {
        command: String,
        actions: Vec<Value>,
    },
    /// A file edit. Nothing is shown until the result arrives, because the diff usually
    /// comes with it; `fallback` is what the call itself said about the change.
    Edit { path: String, fallback: Vec<Value> },
}

fn sh_quote(text: &str) -> String {
    format!("'{}'", text.replace('\'', r"'\''"))
}

/// The TUI shows the script of a `bash -lc` command as written and re-quotes anything else
/// word by word (turning a `|` into `'|'`), so every command is wrapped.
fn script(text: &str) -> String {
    format!("bash -lc {}", sh_quote(text))
}

fn command(text: &str, actions: Vec<Value>) -> Shape {
    Shape::Command {
        command: script(text),
        actions,
    }
}

fn clip(text: &str, max: usize) -> String {
    let one_line: String = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if one_line.chars().count() <= max {
        return one_line;
    }
    let cut: String = one_line.chars().take(max).collect();
    format!("{cut}…")
}

fn file_name(path: &str) -> String {
    Path::new(path)
        .file_name()
        .map_or_else(|| path.to_owned(), |n| n.to_string_lossy().into_owned())
}

/// Agents often send a replaced snippet, not whole files; ending both sides in a newline
/// keeps the diff to `-old` / `+new` instead of "no newline at end of file" noise.
fn line_terminated(text: &str) -> String {
    if text.is_empty() || text.ends_with('\n') {
        text.to_owned()
    } else {
        format!("{text}\n")
    }
}

/// A change row for the TUI: `Add` carries the file's content, `Update` a unified diff.
fn change(path: &str, old: Option<&str>, new: &str) -> Value {
    match old {
        None => json!({ "path": path, "kind": { "type": "add" }, "diff": new }),
        Some(old) => json!({
            "path": path,
            "kind": { "type": "update", "move_path": null },
            "diff": diffy::create_patch(&line_terminated(old), &line_terminated(new)).to_string(),
        }),
    }
}

pub fn shape(call: &ToolCall) -> Shape {
    match call {
        ToolCall::Exec { command: text } => command(text, vec![]),
        ToolCall::ReadFile { path } => {
            let text = format!("cat {}", sh_quote(path));
            let action = json!({
                "type": "read", "command": text, "name": file_name(path), "path": path,
            });
            command(&text, vec![action])
        }
        ToolCall::Search { pattern, path } => {
            let text = match path {
                Some(path) => format!("rg {} {}", sh_quote(pattern), sh_quote(path)),
                None => format!("rg {}", sh_quote(pattern)),
            };
            let action = json!({
                "type": "search", "command": text, "query": pattern, "path": path,
            });
            command(&text, vec![action])
        }
        ToolCall::Glob { pattern } => {
            let text = format!("ls {}", sh_quote(pattern));
            let action = json!({ "type": "listFiles", "command": text, "path": pattern });
            command(&text, vec![action])
        }
        ToolCall::WriteFile { path, content } => Shape::Edit {
            path: path.clone(),
            fallback: content
                .as_deref()
                .map(|content| change(path, None, content))
                .into_iter()
                .collect(),
        },
        ToolCall::EditFile {
            path,
            old_string,
            new_string,
        } => Shape::Edit {
            path: path.clone(),
            fallback: match (old_string, new_string) {
                (Some(old), Some(new)) => vec![change(path, Some(old), new)],
                _ => vec![],
            },
        },
        ToolCall::ApplyPatch { path } => Shape::Edit {
            path: path.clone().unwrap_or_else(|| "patch".into()),
            fallback: vec![],
        },
        ToolCall::WebFetch { url, .. } => command(&format!("fetch {url}"), vec![]),
        ToolCall::WebSearch { query } => {
            command(&format!("web search: {}", clip(query, 100)), vec![])
        }
        ToolCall::Todo { items } => {
            let done = items.iter().filter(|item| item.done).count();
            command(
                &format!("update todo list ({done}/{} done)", items.len()),
                vec![],
            )
        }
        ToolCall::Mcp {
            server,
            tool,
            input,
        } => command(&labelled(&format!("{server}.{tool}"), input), vec![]),
        ToolCall::Unknown { name, input } => command(&labelled(name, input), vec![]),
    }
}

fn labelled(name: &str, input: &Option<Value>) -> String {
    match input {
        Some(input) if !input.is_null() => format!("{name} {}", clip(&input.to_string(), 100)),
        _ => name.to_owned(),
    }
}

/// The changes to show for a finished edit: the result's own diff, else what the call said.
pub fn finished_changes(diff: Option<&ToolDiff>, fallback: Vec<Value>) -> Vec<Value> {
    match diff {
        Some(diff) => vec![change(&diff.path, diff.old_text.as_deref(), &diff.new_text)],
        None => fallback,
    }
}

/// A `commandExecution` item.
#[allow(clippy::too_many_arguments)]
pub fn command_item(
    id: &str,
    command: &str,
    actions: &[Value],
    cwd: &str,
    status: &str,
    output: Option<&str>,
    exit_code: Option<i32>,
    duration_ms: Option<i64>,
) -> Value {
    json!({
        "type": "commandExecution", "id": id, "command": command,
        "commandActions": actions, "cwd": cwd, "status": status,
        "aggregatedOutput": output, "exitCode": exit_code, "durationMs": duration_ms,
    })
}

pub fn file_change_item(id: &str, changes: Vec<Value>, status: &str) -> Value {
    json!({ "type": "fileChange", "id": id, "changes": changes, "status": status })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shell_commands_keep_their_pipes() {
        let Shape::Command { command, .. } = shape(&ToolCall::Exec {
            command: "ls /tmp | head -3".into(),
        }) else {
            panic!("exec is a command");
        };
        assert_eq!(command, "bash -lc 'ls /tmp | head -3'");
    }

    #[test]
    fn quotes_inside_a_script_survive() {
        assert_eq!(script("echo 'hi'"), r"bash -lc 'echo '\''hi'\'''");
    }

    #[test]
    fn reads_become_explored_actions() {
        let Shape::Command { actions, .. } = shape(&ToolCall::ReadFile {
            path: "/a/b.rs".into(),
        }) else {
            panic!("read is a command");
        };
        assert_eq!(actions[0]["type"], "read");
        assert_eq!(actions[0]["name"], "b.rs");
    }

    #[test]
    fn a_new_file_carries_its_content_and_an_edit_a_unified_diff() {
        let added = change("a.txt", None, "hello\n");
        assert_eq!(added["kind"]["type"], "add");
        assert_eq!(added["diff"], "hello\n");
        let updated = change("a.txt", Some("one\ntwo\n"), "one\n2\n");
        assert_eq!(updated["kind"]["type"], "update");
        let diff = updated["diff"].as_str().unwrap();
        assert!(diff.contains("-two") && diff.contains("+2"), "{diff}");
    }

    #[test]
    fn the_result_diff_wins_over_the_call() {
        let diff = ToolDiff {
            path: "a".into(),
            old_text: Some("x\n".into()),
            new_text: "y\n".into(),
        };
        let changes = finished_changes(Some(&diff), vec![json!("fallback")]);
        assert_eq!(changes.len(), 1);
        assert_eq!(changes[0]["kind"]["type"], "update");
    }
}
