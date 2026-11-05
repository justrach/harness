//! Codex sessions: `<codex home>/sessions/YYYY/MM/DD/rollout-*.jsonl`.
//!
//! The first line is `session_meta` (id, cwd). The conversation is the
//! `response_item` lines: `message` (role `user` or `assistant`), the tool
//! calls (`function_call`, `custom_tool_call`) and their outputs, which are
//! matched back by `call_id`. Reasoning, token counts and Codex's own
//! instruction blocks are not part of what the person saw.

use std::collections::HashMap;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};

use harness_doc::MessageRole;
use harness_proto::ToolCall;
use serde_json::Value;

use super::{Block, ExternalSession, Msg, Source};

pub(super) fn discover(codex_home: &Path, cwd: Option<&str>) -> Vec<ExternalSession> {
    let mut files = Vec::new();
    rollout_files(&codex_home.join("sessions"), &mut files);
    rollout_files(&codex_home.join("archived_sessions"), &mut files);
    files.iter().filter_map(|path| head(path, cwd)).collect()
}

/// A link identifies a local thread; it does not authorize fetching a web page
/// or starting Codex. Keep references separate from filesystem paths.
pub(super) fn reference_id(reference: &str) -> Result<String, String> {
    let reference = reference.trim();
    let id = match reference.strip_prefix("codex://threads/") {
        Some(rest) => {
            let path = rest.split(['?', '#']).next().unwrap_or("");
            path.strip_suffix('/').unwrap_or(path)
        }
        None => reference,
    };
    let parsed = uuid::Uuid::parse_str(id).map_err(|_| {
        "Paste a Codex conversation link (codex://threads/<conversation-id>) or its conversation ID."
            .to_string()
    })?;
    let canonical = parsed.hyphenated().to_string();
    if !canonical.eq_ignore_ascii_case(id) {
        return Err("The Codex conversation ID must be a hyphenated UUID.".into());
    }
    Ok(canonical)
}

/// Resolve exactly one thread, including archived rollouts. A filename narrows
/// the read, and session_meta verifies the ID before any transcript is imported.
pub(super) fn resolve(codex_home: &Path, id: &str) -> Result<(ExternalSession, bool), String> {
    for (directory, archived) in [("sessions", false), ("archived_sessions", true)] {
        let mut files = Vec::new();
        rollout_files(&codex_home.join(directory), &mut files);
        files.sort();
        for path in files {
            let matches_id = path
                .file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| {
                    let name = name.to_ascii_lowercase();
                    name == format!("{id}.jsonl") || name.ends_with(&format!("-{id}.jsonl"))
                });
            if !matches_id {
                continue;
            }
            let lines = super::head_lines(&path)
                .map_err(|e| format!("The local Codex conversation could not be read: {e}"))?;
            let mut metadata = None;
            for line in lines {
                if line["type"] == "session_meta" {
                    if line["payload"]["source"]["subagent"].is_object() {
                        break;
                    }
                    if line["payload"]["id"]
                        .as_str()
                        .is_some_and(|native| native.eq_ignore_ascii_case(id))
                    {
                        metadata = Some(line["payload"]["cwd"].as_str().map(str::to_owned));
                    }
                    break;
                }
            }
            let Some(cwd) = metadata else {
                continue;
            };
            let title = head(&path, None)
                .map(|session| session.title)
                .unwrap_or_else(|| "Codex conversation".into());
            let (started_at, updated_at, size) = super::file_times(&path);
            return Ok((
                ExternalSession {
                    source: Source::Codex,
                    id: id.to_owned(),
                    path: path.to_string_lossy().into_owned(),
                    cwd,
                    title,
                    started_at,
                    updated_at,
                    size,
                },
                archived,
            ));
        }
    }
    Err("That Codex conversation was not found on this device. Open Harness on the computer that holds the conversation, or check the Codex conversation link.".into())
}

/// Walk `sessions/` (three levels of date folders) for rollout files.
fn rollout_files(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let Ok(kind) = entry.file_type() else {
            continue;
        };
        if kind.is_dir() {
            rollout_files(&path, out);
        } else if kind.is_file() && path.extension().and_then(|e| e.to_str()) == Some("jsonl") {
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
    let mut lines = BufReader::new(std::fs::File::open(path)?)
        .lines()
        .enumerate()
        .peekable();
    while let Some((index, line)) = lines.next() {
        // A session may be actively appending its final JSON record. Other
        // malformed records and all I/O/UTF-8 errors must abort the import,
        // rather than permanently saving a silently truncated snapshot.
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        let line: Value = match serde_json::from_str(&line) {
            Ok(line) => line,
            Err(error) if error.is_eof() && lines.peek().is_none() => break,
            Err(_) => {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    format!(
                        "Codex history contains an invalid JSON record at line {}",
                        index + 1
                    ),
                ));
            }
        };
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

    const THREAD_ID: &str = "12345678-1234-4123-8123-123456789abc";

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

    #[test]
    fn references_accept_codex_threads_and_reject_other_urls_and_paths() {
        for reference in [
            THREAD_ID.to_string(),
            format!("codex://threads/{THREAD_ID}"),
            format!(" codex://threads/{THREAD_ID}?view=review#latest "),
            format!("codex://threads/{THREAD_ID}/"),
            THREAD_ID.to_uppercase(),
        ] {
            assert_eq!(reference_id(&reference).unwrap(), THREAD_ID);
        }
        for reference in [
            "".to_owned(),
            "codex://threads/".into(),
            format!("https://example.com/{THREAD_ID}"),
            format!("https://chatgpt.com/share/{THREAD_ID}"),
            format!("codex://threads/{THREAD_ID}/../../private"),
            format!("codex://threads/{THREAD_ID}//"),
            format!("codex://threads/{THREAD_ID}%2fprivate"),
            format!("codex://someone@threads/{THREAD_ID}"),
            THREAD_ID.replace('-', ""),
            format!("{{{THREAD_ID}}}"),
            format!("/tmp/{THREAD_ID}.jsonl"),
        ] {
            assert!(reference_id(&reference).is_err(), "{reference}");
        }
    }

    #[test]
    fn direct_resolution_finds_archived_paginated_rollouts_and_verifies_metadata() {
        let dir = tempfile::tempdir().unwrap();
        let original = session(dir.path(), "rollout-fixture.jsonl", "/w/app");
        let archived_dir = dir.path().join("archived_sessions");
        std::fs::create_dir_all(&archived_dir).unwrap();
        let body = std::fs::read_to_string(&original).unwrap().replace(
            r#""id":"c1""#,
            &format!(r#""id":"{THREAD_ID}","history_mode":"paginated""#),
        );
        let path = archived_dir.join(format!("rollout-2026-09-01-{THREAD_ID}.jsonl"));
        std::fs::write(&path, body).unwrap();
        std::fs::remove_file(original).unwrap();
        let (found, archived) = resolve(dir.path(), THREAD_ID).unwrap();
        assert!(archived);
        assert_eq!(found.id, THREAD_ID);
        assert_eq!(found.title, "add a retry");
        assert_eq!(load(&path).unwrap().len(), 2);
        assert_eq!(discover(dir.path(), None).len(), 1);

        std::fs::write(
            &path,
            r#"{"type":"session_meta","payload":{"id":"different","cwd":"/w/app"}}"#,
        )
        .unwrap();
        assert!(resolve(dir.path(), THREAD_ID).is_err());
    }

    #[test]
    fn history_tolerates_only_an_incomplete_final_json_record() {
        let dir = tempfile::tempdir().unwrap();
        let path = session(dir.path(), "rollout-fixture.jsonl", "/w/app");
        let valid = std::fs::read_to_string(&path).unwrap();
        std::fs::write(&path, format!("{valid}{{\"type\":")).unwrap();
        assert_eq!(load(&path).unwrap().len(), 2);
        std::fs::write(
            &path,
            format!("{valid}{{\"type\":\n{{\"type\":\"event_msg\"}}\n"),
        )
        .unwrap();
        assert!(
            load(&path).is_err(),
            "an incomplete interior record is corrupt"
        );
        std::fs::write(&path, format!("{valid}not-json\n")).unwrap();
        assert!(load(&path).is_err(), "a malformed final record is corrupt");
        let mut corrupt = valid.into_bytes();
        corrupt.extend_from_slice(b"\xff\n{\"type\":\"event_msg\"}\n");
        std::fs::write(&path, corrupt).unwrap();
        assert_eq!(
            load(&path).err().unwrap().kind(),
            std::io::ErrorKind::InvalidData
        );
    }
}
