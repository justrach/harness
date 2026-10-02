//! Claude Code sessions: `<config dir>/projects/<encoded cwd>/<session>.jsonl`.
//!
//! One JSON object per line. `user` and `assistant` lines carry
//! `message.content`, a string or blocks (`text`, `thinking`, `tool_use`,
//! `tool_result`). A tool's result arrives on a later `user` line, so results
//! are folded back onto the call that asked for them. Sub-agent (`isSidechain`)
//! and `isMeta` lines are not part of the conversation.

use std::collections::HashMap;
use std::path::Path;

use harness_doc::MessageRole;
use harness_proto::ToolCall;
use serde_json::Value;

use super::{Block, ExternalSession, Msg, Source};

/// Claude Code names a project folder after its path, every non-alphanumeric
/// character replaced by `-`.
pub(super) fn encode_cwd(cwd: &str) -> String {
    cwd.chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect()
}

pub(super) fn discover(config_dir: &Path, cwd: Option<&str>) -> Vec<ExternalSession> {
    let projects = config_dir.join("projects");
    let Ok(dirs) = std::fs::read_dir(&projects) else {
        return Vec::new();
    };
    let wanted = cwd.map(encode_cwd);
    let mut out = Vec::new();
    for dir in dirs.flatten() {
        if let Some(wanted) = &wanted
            && dir.file_name().to_string_lossy() != wanted.as_str()
        {
            continue;
        }
        let Ok(files) = std::fs::read_dir(dir.path()) else {
            continue;
        };
        for file in files.flatten() {
            let path = file.path();
            if path.extension().and_then(|e| e.to_str()) != Some("jsonl") {
                continue;
            }
            if let Some(session) = head(&path) {
                out.push(session);
            }
        }
    }
    out
}

fn head(path: &Path) -> Option<ExternalSession> {
    let id = path.file_stem()?.to_string_lossy().into_owned();
    let mut cwd = None;
    let mut prompt = None;
    for line in super::head_lines(path).ok()? {
        if line["isSidechain"].as_bool() == Some(true) {
            continue;
        }
        if cwd.is_none() {
            cwd = line["cwd"].as_str().map(str::to_owned);
        }
        if prompt.is_none()
            && line["type"] == "user"
            && line["isMeta"].as_bool() != Some(true)
            && let Some(text) = user_text(&line["message"]["content"])
            && !super::is_scaffolding(&text)
        {
            prompt = Some(text);
        }
        if cwd.is_some() && prompt.is_some() {
            break;
        }
    }
    super::session_from_head(Source::Claude, id, path, cwd, prompt)
}

/// The words a person typed: a string, or the text blocks of a block list.
/// `None` for a line that is only tool results.
fn user_text(content: &Value) -> Option<String> {
    match content {
        Value::String(s) => Some(s.clone()),
        Value::Array(blocks) => {
            let text: Vec<&str> = blocks
                .iter()
                .filter(|b| b["type"] == "text")
                .filter_map(|b| b["text"].as_str())
                .collect();
            (!text.is_empty()).then(|| text.join("\n"))
        }
        _ => None,
    }
}

pub(super) fn load(path: &Path) -> std::io::Result<Vec<Msg>> {
    let mut msgs: Vec<Msg> = Vec::new();
    // tool_use id → (message index, block index)
    let mut calls: HashMap<String, (usize, usize)> = HashMap::new();
    for line in super::json_lines(path)? {
        if line["isSidechain"].as_bool() == Some(true) || line["isMeta"].as_bool() == Some(true) {
            continue;
        }
        let at_ms = line["timestamp"]
            .as_str()
            .and_then(super::parse_time_ms)
            .unwrap_or(0);
        let content = &line["message"]["content"];
        match line["type"].as_str() {
            Some("user") => {
                if let Value::Array(blocks) = content {
                    for block in blocks.iter().filter(|b| b["type"] == "tool_result") {
                        let Some(id) = block["tool_use_id"].as_str() else {
                            continue;
                        };
                        if let Some(&(m, b)) = calls.get(id)
                            && let Block::Tool {
                                output, is_error, ..
                            } = &mut msgs[m].blocks[b]
                        {
                            *output = result_text(&block["content"])
                                .and_then(|t| harness_doc::summarize_tool_output(&t));
                            *is_error = block["is_error"].as_bool() == Some(true);
                        }
                    }
                }
                if let Some(text) = user_text(content)
                    && !super::is_scaffolding(&text)
                {
                    msgs.push(Msg {
                        role: MessageRole::User,
                        at_ms,
                        blocks: vec![Block::Text(text)],
                    });
                }
            }
            Some("assistant") => {
                // One assistant turn spans several lines (text, then each tool
                // call); keep them as one message until a person speaks again.
                let merge = matches!(msgs.last(), Some(l) if l.role == MessageRole::Assistant);
                let target = if merge { msgs.len() - 1 } else { msgs.len() };
                let offset = if merge { msgs[target].blocks.len() } else { 0 };
                let mut blocks = Vec::new();
                match content {
                    Value::String(s) if !s.trim().is_empty() => blocks.push(Block::Text(s.clone())),
                    Value::Array(items) => {
                        for item in items {
                            match item["type"].as_str() {
                                Some("text") => {
                                    if let Some(t) = item["text"].as_str()
                                        && !t.trim().is_empty()
                                    {
                                        blocks.push(Block::Text(t.to_owned()));
                                    }
                                }
                                Some("tool_use") => {
                                    if let Some(id) = item["id"].as_str() {
                                        calls
                                            .insert(id.to_owned(), (target, offset + blocks.len()));
                                    }
                                    blocks.push(Block::Tool {
                                        call: tool_call(
                                            item["name"].as_str().unwrap_or("tool"),
                                            &item["input"],
                                        ),
                                        output: None,
                                        is_error: false,
                                    });
                                }
                                _ => {}
                            }
                        }
                    }
                    _ => {}
                }
                if blocks.is_empty() {
                    continue;
                }
                if merge {
                    msgs[target].blocks.extend(blocks);
                } else {
                    msgs.push(Msg {
                        role: MessageRole::Assistant,
                        at_ms,
                        blocks,
                    });
                }
            }
            _ => {}
        }
    }
    Ok(msgs)
}

fn result_text(content: &Value) -> Option<String> {
    match content {
        Value::String(s) => Some(s.clone()),
        Value::Array(blocks) => {
            let text: Vec<&str> = blocks.iter().filter_map(|b| b["text"].as_str()).collect();
            (!text.is_empty()).then(|| text.join("\n"))
        }
        _ => None,
    }
}

/// Claude Code's tool names, mapped to Harness's. Arguments other than the one
/// that names the target are not kept.
pub(super) fn tool_call(name: &str, input: &Value) -> ToolCall {
    let s = |key: &str| input[key].as_str().map(str::to_owned);
    match name {
        "Bash" => ToolCall::Exec {
            command: s("command").unwrap_or_default(),
        },
        "Read" => ToolCall::ReadFile {
            path: s("file_path").unwrap_or_default(),
        },
        "Write" => ToolCall::WriteFile {
            path: s("file_path").unwrap_or_default(),
            content: None,
        },
        "Edit" | "MultiEdit" => ToolCall::EditFile {
            path: s("file_path").unwrap_or_default(),
            old_string: None,
            new_string: None,
        },
        "Grep" => ToolCall::Search {
            pattern: s("pattern").unwrap_or_default(),
            path: s("path"),
        },
        "Glob" => ToolCall::Glob {
            pattern: s("pattern").unwrap_or_default(),
        },
        "WebFetch" => ToolCall::WebFetch {
            url: s("url").unwrap_or_default(),
            prompt: None,
        },
        "WebSearch" => ToolCall::WebSearch {
            query: s("query").unwrap_or_default(),
        },
        other => match other.strip_prefix("mcp__").and_then(|r| r.split_once("__")) {
            Some((server, tool)) => ToolCall::Mcp {
                server: server.to_owned(),
                tool: tool.to_owned(),
                input: None,
            },
            None => ToolCall::Unknown {
                name: other.to_owned(),
                input: None,
            },
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn write(dir: &Path, name: &str, lines: &[&str]) -> std::path::PathBuf {
        let path = dir.join(name);
        let mut f = std::fs::File::create(&path).unwrap();
        for l in lines {
            writeln!(f, "{l}").unwrap();
        }
        path
    }

    const SESSION: &[&str] = &[
        r#"{"type":"queue-operation","operation":"enqueue"}"#,
        r#"{"type":"user","isMeta":true,"cwd":"/w/app","timestamp":"2026-09-01T10:00:00Z","message":{"role":"user","content":"<command-name>/clear</command-name>"}}"#,
        r#"{"type":"user","cwd":"/w/app","sessionId":"s1","timestamp":"2026-09-01T10:00:01Z","message":{"role":"user","content":"fix the login bug"}}"#,
        r#"{"type":"assistant","timestamp":"2026-09-01T10:00:02Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hmm"},{"type":"text","text":"Looking at it."},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"cargo test"}}]}}"#,
        r#"{"type":"user","timestamp":"2026-09-01T10:00:03Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"test result: ok","is_error":false}]}}"#,
        r#"{"type":"assistant","timestamp":"2026-09-01T10:00:04Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"t2","name":"Edit","input":{"file_path":"/w/app/a.rs","old_string":"x","new_string":"y"}}]}}"#,
        r#"{"type":"user","timestamp":"2026-09-01T10:00:05Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","content":"nope","is_error":true}]}}"#,
        r#"{"type":"assistant","timestamp":"2026-09-01T10:00:06Z","message":{"role":"assistant","content":[{"type":"text","text":"Fixed."}]}}"#,
        r#"{"type":"assistant","isSidechain":true,"timestamp":"2026-09-01T10:00:07Z","message":{"role":"assistant","content":[{"type":"text","text":"sub-agent chatter"}]}}"#,
    ];

    #[test]
    fn a_session_becomes_prompts_replies_and_tool_rows() {
        let dir = tempfile::tempdir().unwrap();
        let path = write(dir.path(), "s1.jsonl", SESSION);
        let msgs = load(&path).unwrap();
        // user prompt, then ONE assistant turn holding both text, both tools and the final reply
        assert_eq!(msgs.len(), 2, "{}", msgs.len());
        assert_eq!(msgs[0].role, MessageRole::User);
        assert_eq!(msgs[1].role, MessageRole::Assistant);
        let b = &msgs[1].blocks;
        assert_eq!(b.len(), 4);
        assert!(matches!(&b[0], Block::Text(t) if t == "Looking at it."));
        assert!(matches!(
            &b[1],
            Block::Tool { call: ToolCall::Exec { command }, output: Some(o), is_error: false }
                if command == "cargo test" && o.contains("test result")
        ));
        assert!(matches!(
            &b[2],
            Block::Tool { call: ToolCall::EditFile { path, .. }, is_error: true, .. } if path == "/w/app/a.rs"
        ));
        assert!(matches!(&b[3], Block::Text(t) if t == "Fixed."));
        assert!(
            !msgs
                .iter()
                .flat_map(|m| &m.blocks)
                .any(|b| matches!(b, Block::Text(t) if t.contains("sub-agent")))
        );
    }

    #[test]
    fn discovery_titles_by_the_first_real_prompt_and_filters_by_folder() {
        let dir = tempfile::tempdir().unwrap();
        let proj = dir.path().join("projects").join(encode_cwd("/w/app"));
        std::fs::create_dir_all(&proj).unwrap();
        write(&proj, "s1.jsonl", SESSION);
        let other = dir.path().join("projects").join(encode_cwd("/w/other"));
        std::fs::create_dir_all(&other).unwrap();
        write(&other, "s2.jsonl", SESSION);
        let all = discover(dir.path(), None);
        assert_eq!(all.len(), 2);
        assert_eq!(all[0].title, "fix the login bug");
        assert_eq!(all[0].cwd.as_deref(), Some("/w/app"));
        let mine = discover(dir.path(), Some("/w/app"));
        assert_eq!(mine.len(), 1);
        assert_eq!(mine[0].id, "s1");
    }

    #[test]
    fn a_file_with_no_prompt_is_not_offered() {
        let dir = tempfile::tempdir().unwrap();
        let proj = dir.path().join("projects").join("p");
        std::fs::create_dir_all(&proj).unwrap();
        write(&proj, "empty.jsonl", &[r#"{"type":"queue-operation"}"#]);
        assert!(discover(dir.path(), None).is_empty());
    }

    #[test]
    fn tool_names_map_and_arguments_are_dropped() {
        let call = tool_call(
            "mcp__github__create_issue",
            &serde_json::json!({"title":"secret"}),
        );
        assert!(
            matches!(call, ToolCall::Mcp { server, tool, input: None } if server == "github" && tool == "create_issue")
        );
        let call = tool_call(
            "Write",
            &serde_json::json!({"file_path":"/a","content":"secret"}),
        );
        assert!(matches!(call, ToolCall::WriteFile { content: None, .. }));
    }
}
