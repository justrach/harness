//! graff sessions: `<project>/.graff/sessions/<session>.transcript.jsonl`.
//!
//! Every line is a chat row (`{"role","content"}`) or a Responses item
//! (`message`, `function_call`, `function_call_output`). Rows carry no clock,
//! so messages are stamped from the file's last write, one millisecond apart
//! and in order.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use harness_doc::MessageRole;
use harness_proto::ToolCall;
use serde_json::Value;

use super::{Block, ExternalSession, Msg, Source};

const SUFFIX: &str = ".transcript.jsonl";

pub(super) fn discover(projects: &[PathBuf], cwd: Option<&str>) -> Vec<ExternalSession> {
    let mut out = Vec::new();
    for project in projects {
        if let Some(cwd) = cwd
            && project != Path::new(cwd)
        {
            continue;
        }
        let Ok(entries) = std::fs::read_dir(project.join(".graff").join("sessions")) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            let Some(id) = path
                .file_name()
                .and_then(|n| n.to_str())
                .and_then(|n| n.strip_suffix(SUFFIX))
                .map(str::to_owned)
            else {
                continue;
            };
            let prompt = super::head_lines(&path).ok().and_then(|mut lines| {
                lines.find_map(|l| {
                    (role(&l) == Some("user"))
                        .then(|| text_of(&l))
                        .filter(|t| !super::is_scaffolding(t))
                })
            });
            if let Some(session) = super::session_from_head(
                Source::Graff,
                id,
                &path,
                Some(project.to_string_lossy().into_owned()),
                prompt,
            ) {
                out.push(session);
            }
        }
    }
    out
}

fn role(line: &Value) -> Option<&str> {
    line["role"].as_str()
}

fn text_of(line: &Value) -> String {
    match &line["content"] {
        Value::String(s) => s.clone(),
        Value::Array(blocks) => blocks
            .iter()
            .filter_map(|b| b["text"].as_str())
            .collect::<Vec<_>>()
            .join("\n"),
        _ => String::new(),
    }
}

pub(super) fn load(path: &Path, updated_at: i64) -> std::io::Result<Vec<Msg>> {
    let mut msgs: Vec<Msg> = Vec::new();
    let mut calls: HashMap<String, (usize, usize)> = HashMap::new();
    let mut tick = 0i64;
    let mut next_at = || {
        tick += 1;
        updated_at + tick
    };
    for line in super::json_lines(path)? {
        match (line["type"].as_str(), role(&line)) {
            (Some("function_call"), _) => {
                let name = line["name"].as_str().unwrap_or("tool");
                let args: Value = line["arguments"]
                    .as_str()
                    .and_then(|a| serde_json::from_str(a).ok())
                    .unwrap_or(Value::Null);
                let call = match name {
                    "shell" | "bash" | "run_command" | "exec" => ToolCall::Exec {
                        command: args["command"]
                            .as_str()
                            .or_else(|| args["cmd"].as_str())
                            .unwrap_or_default()
                            .to_owned(),
                    },
                    other => ToolCall::Unknown {
                        name: other.to_owned(),
                        input: None,
                    },
                };
                if !matches!(msgs.last(), Some(m) if m.role == MessageRole::Assistant) {
                    msgs.push(Msg {
                        role: MessageRole::Assistant,
                        at_ms: next_at(),
                        blocks: Vec::new(),
                    });
                }
                let index = msgs.len() - 1;
                if let Some(id) = line["call_id"].as_str() {
                    calls.insert(id.to_owned(), (index, msgs[index].blocks.len()));
                }
                msgs[index].blocks.push(Block::Tool {
                    call,
                    output: None,
                    is_error: false,
                });
            }
            (Some("function_call_output"), _) => {
                if let Some(&(m, b)) = line["call_id"].as_str().and_then(|id| calls.get(id))
                    && let Block::Tool { output, .. } = &mut msgs[m].blocks[b]
                {
                    let text = match &line["output"] {
                        Value::String(s) => s.clone(),
                        other => other.to_string(),
                    };
                    *output = harness_doc::summarize_tool_output(&text);
                }
            }
            (_, Some("user")) => {
                let text = text_of(&line);
                if !super::is_scaffolding(&text) {
                    msgs.push(Msg {
                        role: MessageRole::User,
                        at_ms: next_at(),
                        blocks: vec![Block::Text(text)],
                    });
                }
            }
            (_, Some("assistant")) => {
                let text = text_of(&line);
                if text.trim().is_empty() {
                    continue;
                }
                match msgs.last_mut() {
                    Some(m) if m.role == MessageRole::Assistant => m.blocks.push(Block::Text(text)),
                    _ => msgs.push(Msg {
                        role: MessageRole::Assistant,
                        at_ms: next_at(),
                        blocks: vec![Block::Text(text)],
                    }),
                }
            }
            _ => {}
        }
    }
    Ok(msgs)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn project(dir: &Path) -> PathBuf {
        let sessions = dir.join(".graff/sessions");
        std::fs::create_dir_all(&sessions).unwrap();
        let mut f =
            std::fs::File::create(sessions.join("session-1790794305113-84189.transcript.jsonl"))
                .unwrap();
        for l in [
            r#"{"role":"user","content":"rename the helper"}"#,
            r#"{"role":"assistant","content":"Renaming."}"#,
            r#"{"type":"function_call","name":"shell","call_id":"a","arguments":"{\"command\":\"rg helper\"}"}"#,
            r#"{"type":"function_call_output","call_id":"a","output":"src/a.rs:1:helper"}"#,
            r#"{"role":"assistant","content":[{"type":"output_text","text":"Done."}]}"#,
        ] {
            writeln!(f, "{l}").unwrap();
        }
        dir.to_path_buf()
    }

    #[test]
    fn a_transcript_becomes_prompts_replies_and_tool_rows() {
        let dir = tempfile::tempdir().unwrap();
        let root = project(dir.path());
        let found = discover(&[root.clone()], None);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].id, "session-1790794305113-84189");
        assert_eq!(found[0].title, "rename the helper");
        let msgs = load(Path::new(&found[0].path), found[0].updated_at).unwrap();
        assert_eq!(msgs.len(), 2);
        let b = &msgs[1].blocks;
        assert_eq!(b.len(), 3);
        assert!(matches!(
            &b[1],
            Block::Tool { call: ToolCall::Exec { command }, output: Some(_), .. } if command == "rg helper"
        ));
        assert!(msgs[0].at_ms < msgs[1].at_ms);
        assert!(discover(&[root], Some("/elsewhere")).is_empty());
    }
}
