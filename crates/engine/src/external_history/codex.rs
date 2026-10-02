//! Codex sessions: `<codex home>/sessions/YYYY/MM/DD/rollout-*.jsonl`.
//!
//! The first line is `session_meta` (id, cwd). The conversation is the
//! `response_item` lines: `message` (role `user` or `assistant`), the tool
//! calls (`function_call`, `custom_tool_call`) and their outputs, which are
//! matched back by `call_id`. Reasoning, token counts and Codex's own
//! instruction blocks are not part of what the person saw.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use harness_doc::MessageRole;
use harness_proto::ToolCall;
use serde_json::Value;

use super::{Block, ExternalSession, Msg, Source};

pub(super) fn discover(codex_home: &Path, cwd: Option<&str>) -> Vec<ExternalSession> {
    let mut files = Vec::new();
    rollout_files(&codex_home.join("sessions"), &mut files);
    files.iter().filter_map(|path| head(path, cwd)).collect()
}

/// Walk `sessions/` (three levels of date folders) for rollout files.
fn rollout_files(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            rollout_files(&path, out);
        } else if path.extension().and_then(|e| e.to_str()) == Some("jsonl") {
            out.push(path);
        }
    }
}

fn head(path: &Path, want_cwd: Option<&str>) -> Option<ExternalSession> {
    let mut id = None;
    let mut cwd = None;
    let mut prompt = None;
    for line in super::head_lines(path).ok()? {
        match line["type"].as_str() {
            Some("session_meta") => {
                // Threads Codex spawns for itself (sub-agents, reviewers) are
                // not conversations a person had.
                if line["payload"]["source"]["subagent"].is_object() {
                    return None;
                }
                id = line["payload"]["id"].as_str().map(str::to_owned);
                cwd = line["payload"]["cwd"].as_str().map(str::to_owned);
                if let (Some(want), Some(have)) = (want_cwd, &cwd)
                    && want != have
                {
                    return None;
                }
            }
            Some("response_item")
                if prompt.is_none()
                    && line["payload"]["type"] == "message"
                    && line["payload"]["role"] == "user" =>
            {
                let text = message_text(&line["payload"]["content"]);
                if !super::is_scaffolding(&text) {
                    prompt = Some(text);
                }
            }
            _ => {}
        }
        if id.is_some() && prompt.is_some() {
            break;
        }
    }
    if want_cwd.is_some() && cwd.is_none() {
        return None;
    }
    super::session_from_head(Source::Codex, id?, path, cwd, prompt)
}

fn message_text(content: &Value) -> String {
    match content {
        Value::String(s) => s.clone(),
        Value::Array(blocks) => blocks
            .iter()
            .filter_map(|b| b["text"].as_str())
            .collect::<Vec<_>>()
            .join("\n"),
        _ => String::new(),
    }
}

pub(super) fn load(path: &Path) -> std::io::Result<Vec<Msg>> {
    let mut msgs: Vec<Msg> = Vec::new();
    // call_id → (message index, block index)
    let mut calls: HashMap<String, (usize, usize)> = HashMap::new();
    for line in super::json_lines(path)? {
        if line["type"] != "response_item" {
            continue;
        }
        let at_ms = line["timestamp"]
            .as_str()
            .and_then(super::parse_time_ms)
            .unwrap_or(0);
        let p = &line["payload"];
        match p["type"].as_str() {
            Some("message") => match p["role"].as_str() {
                Some("user") => {
                    let text = message_text(&p["content"]);
                    if !super::is_scaffolding(&text) {
                        msgs.push(Msg {
                            role: MessageRole::User,
                            at_ms,
                            blocks: vec![Block::Text(text)],
                        });
                    }
                }
                Some("assistant") => {
                    let text = message_text(&p["content"]);
                    if !text.trim().is_empty() {
                        push_assistant(&mut msgs, at_ms, Block::Text(text), None, &mut calls);
                    }
                }
                _ => {}
            },
            Some(kind @ ("function_call" | "custom_tool_call")) => {
                let name = p["name"].as_str().unwrap_or("tool");
                let args = if kind == "function_call" {
                    p["arguments"].as_str()
                } else {
                    p["input"].as_str()
                };
                let block = Block::Tool {
                    call: tool_call(name, args.unwrap_or("")),
                    output: None,
                    is_error: false,
                };
                push_assistant(
                    &mut msgs,
                    at_ms,
                    block,
                    p["call_id"].as_str().map(str::to_owned),
                    &mut calls,
                );
            }
            Some("function_call_output" | "custom_tool_call_output") => {
                if let Some(&(m, b)) = p["call_id"].as_str().and_then(|id| calls.get(id))
                    && let Block::Tool {
                        output, is_error, ..
                    } = &mut msgs[m].blocks[b]
                {
                    let (text, failed) = output_text(&p["output"]);
                    *output = harness_doc::summarize_tool_output(&text);
                    *is_error = failed;
                }
            }
            _ => {}
        }
    }
    Ok(msgs)
}

/// Add a block to the current assistant turn, starting one if a person spoke last.
fn push_assistant(
    msgs: &mut Vec<Msg>,
    at_ms: i64,
    block: Block,
    call_id: Option<String>,
    calls: &mut HashMap<String, (usize, usize)>,
) {
    if !matches!(msgs.last(), Some(m) if m.role == MessageRole::Assistant) {
        msgs.push(Msg {
            role: MessageRole::Assistant,
            at_ms,
            blocks: Vec::new(),
        });
    }
    let index = msgs.len() - 1;
    if let Some(id) = call_id {
        calls.insert(id, (index, msgs[index].blocks.len()));
    }
    msgs[index].blocks.push(block);
}

/// A tool output is plain text, or a JSON object whose `output` is the text
/// (and whose `metadata.exit_code` says how it ended).
fn output_text(output: &Value) -> (String, bool) {
    let raw = match output {
        Value::String(s) => s.clone(),
        other => other.to_string(),
    };
    if let Ok(Value::Object(obj)) = serde_json::from_str::<Value>(&raw)
        && let Some(text) = obj.get("output").and_then(Value::as_str)
    {
        let failed = obj
            .get("metadata")
            .and_then(|m| m.get("exit_code"))
            .and_then(Value::as_i64)
            .is_some_and(|c| c != 0);
        return (text.to_owned(), failed);
    }
    (raw, false)
}

fn tool_call(name: &str, arguments: &str) -> ToolCall {
    let args: Value = serde_json::from_str(arguments).unwrap_or(Value::Null);
    match name {
        "shell" | "container.exec" | "exec_command" | "shell_command" | "local_shell" => {
            ToolCall::Exec {
                command: command_text(&args),
            }
        }
        "apply_patch" => ToolCall::ApplyPatch { path: None },
        other => ToolCall::Unknown {
            name: other.to_owned(),
            input: None,
        },
    }
}

/// `["bash","-lc","script"]` is the script; any other argv is joined.
fn command_text(args: &Value) -> String {
    let command = if args["command"].is_null() {
        &args["cmd"]
    } else {
        &args["command"]
    };
    match command {
        Value::String(s) => s.clone(),
        Value::Array(argv) => {
            let parts: Vec<&str> = argv.iter().filter_map(Value::as_str).collect();
            match parts.as_slice() {
                [_, flag, script] if flag.starts_with('-') && flag.ends_with('c') => {
                    (*script).to_owned()
                }
                _ => parts.join(" "),
            }
        }
        _ => String::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn session(dir: &Path, name: &str, cwd: &str) -> PathBuf {
        let day = dir.join("sessions/2026/09/01");
        std::fs::create_dir_all(&day).unwrap();
        let path = day.join(name);
        let mut f = std::fs::File::create(&path).unwrap();
        let lines = [
            format!(r#"{{"type":"session_meta","payload":{{"id":"c1","cwd":"{cwd}"}}}}"#),
            r#"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>x</environment_context>"}]}}"#.into(),
            r#"{"type":"response_item","timestamp":"2026-09-01T10:00:00Z","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"add a retry"}]}}"#.into(),
            r#"{"type":"response_item","payload":{"type":"reasoning","summary":[]}}"#.into(),
            r#"{"type":"response_item","timestamp":"2026-09-01T10:00:01Z","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"On it."}]}}"#.into(),
            r#"{"type":"response_item","payload":{"type":"function_call","name":"shell","call_id":"k1","arguments":"{\"command\":[\"bash\",\"-lc\",\"cargo test\"]}"}}"#.into(),
            r#"{"type":"response_item","payload":{"type":"function_call_output","call_id":"k1","output":"{\"output\":\"2 failed\",\"metadata\":{\"exit_code\":101}}"}}"#.into(),
            r#"{"type":"response_item","payload":{"type":"custom_tool_call","name":"apply_patch","call_id":"k2","input":"*** Begin Patch"}}"#.into(),
            r#"{"type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"k2","output":"Done!"}}"#.into(),
            r#"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Added."}]}}"#.into(),
        ];
        for l in lines {
            writeln!(f, "{l}").unwrap();
        }
        path
    }

    #[test]
    fn a_rollout_becomes_prompts_replies_and_tool_rows() {
        let dir = tempfile::tempdir().unwrap();
        let path = session(dir.path(), "rollout-a.jsonl", "/w/app");
        let msgs = load(&path).unwrap();
        assert_eq!(msgs.len(), 2);
        assert!(matches!(&msgs[0].blocks[0], Block::Text(t) if t == "add a retry"));
        let b = &msgs[1].blocks;
        assert_eq!(b.len(), 4);
        assert!(matches!(
            &b[1],
            Block::Tool { call: ToolCall::Exec { command }, output: Some(o), is_error: true }
                if command == "cargo test" && o.contains("2 failed")
        ));
        assert!(matches!(
            &b[2],
            Block::Tool {
                call: ToolCall::ApplyPatch { .. },
                is_error: false,
                ..
            }
        ));
    }

    #[test]
    fn a_spawned_sub_agent_thread_is_not_a_conversation() {
        let dir = tempfile::tempdir().unwrap();
        let path = session(dir.path(), "rollout-a.jsonl", "/w/app");
        let body = std::fs::read_to_string(&path).unwrap().replacen(
            r#""cwd":"/w/app""#,
            r#""cwd":"/w/app","source":{"subagent":{"thread_spawn":{"parent":"p"}}}"#,
            1,
        );
        std::fs::write(&path, body).unwrap();
        assert!(discover(dir.path(), None).is_empty());
    }

    #[test]
    fn discovery_skips_instruction_blocks_and_filters_by_folder() {
        let dir = tempfile::tempdir().unwrap();
        session(dir.path(), "rollout-a.jsonl", "/w/app");
        session(dir.path(), "rollout-b.jsonl", "/w/other");
        let all = discover(dir.path(), None);
        assert_eq!(all.len(), 2);
        assert!(all.iter().all(|s| s.title == "add a retry" && s.id == "c1"));
        let mine = discover(dir.path(), Some("/w/app"));
        assert_eq!(mine.len(), 1);
        assert_eq!(mine[0].cwd.as_deref(), Some("/w/app"));
    }
}
