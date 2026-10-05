//! graff's session transcripts, `.graff/sessions/<session>.transcript.jsonl`:
//! the conversation as the model received it, one item per line. Two shapes
//! exist. Responses routes write items (`function_call`, `custom_tool_call`
//! and their `*_output`, `tool_search_*`, `additional_tools`, `message`,
//! `reasoning`); chat routes write rows (`assistant` with `tool_calls`,
//! `tool` with `tool_call_id`). Only tool traffic and the request count are
//! read here.

use std::collections::HashMap;
use std::fs::File;
use std::io::{self, BufRead, BufReader};
use std::path::Path;

use serde_json::Value;

/// One tool call and the output graff sent back to the model.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ToolCall {
    pub name: String,
    pub arguments: String,
    pub output: String,
    /// Model requests made after the output was added: an upper bound on how
    /// many times it was re-sent, since a compaction can drop it sooner.
    pub requests_after: u64,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Transcript {
    pub calls: Vec<ToolCall>,
    /// Model responses: each run of assistant-side items counts once.
    pub requests: u64,
    pub unreadable_lines: u64,
    /// Outputs whose call never appeared (kept, with name `?`).
    pub unmatched_outputs: u64,
}

/// Estimated tokens, `ceil(characters / 4)`: a size, not billing data.
pub fn est_tokens(text: &str) -> u64 {
    (text.chars().count() as u64).div_ceil(4)
}

pub fn read(path: &Path) -> io::Result<Transcript> {
    let mut parser = Parser::default();
    let mut reader = BufReader::new(File::open(path)?);
    let mut line = Vec::new();
    loop {
        line.clear();
        if reader.read_until(b'\n', &mut line)? == 0 {
            break;
        }
        parser.line(&String::from_utf8_lossy(&line));
    }
    Ok(parser.finish())
}

pub fn parse(text: &str) -> Transcript {
    let mut parser = Parser::default();
    for line in text.lines() {
        parser.line(line);
    }
    parser.finish()
}

#[derive(Default)]
struct Parser {
    out: Transcript,
    /// Calls waiting for their output, by call id.
    pending: HashMap<String, (String, String)>,
    /// The last `tool_search_call`, whose output carries no call id.
    search: Option<String>,
    /// Request index at which each call's output arrived.
    arrived: Vec<u64>,
    in_response: bool,
}

impl Parser {
    fn line(&mut self, line: &str) {
        let line = line.trim();
        if line.is_empty() {
            return;
        }
        let Ok(item) = serde_json::from_str::<Value>(line) else {
            self.out.unreadable_lines += 1;
            return;
        };
        let kind = item["type"].as_str().unwrap_or("");
        let role = item["role"].as_str().unwrap_or("");
        let assistant_side = role == "assistant"
            || matches!(
                kind,
                "function_call"
                    | "custom_tool_call"
                    | "reasoning"
                    | "web_search_call"
                    | "tool_search_call"
            );
        if assistant_side && !self.in_response {
            self.out.requests += 1;
        }
        self.in_response = assistant_side;
        match (kind, role) {
            ("function_call", _) => {
                self.call(&item["call_id"], &item["name"], text_of(&item["arguments"]))
            }
            ("custom_tool_call", _) => {
                self.call(&item["call_id"], &item["name"], text_of(&item["input"]))
            }
            ("function_call_output" | "custom_tool_call_output", _) => {
                let (name, arguments) = self.take(&item["call_id"]);
                self.push(name, arguments, text_of(&item["output"]));
            }
            ("tool_search_call", _) => self.search = Some(text_of(&item["arguments"])),
            ("tool_search_output", _) => {
                let arguments = self.search.take().unwrap_or_default();
                self.push("tool_search".into(), arguments, text_of(&item["tools"]));
            }
            // Tool schemas graff announces mid-session also take context.
            ("additional_tools", _) => self.push(
                "additional_tools".into(),
                String::new(),
                text_of(&item["tools"]),
            ),
            (_, "assistant") => {
                for call in item["tool_calls"].as_array().into_iter().flatten() {
                    let function = &call["function"];
                    self.call(
                        &call["id"],
                        &function["name"],
                        text_of(&function["arguments"]),
                    );
                }
            }
            (_, "tool") => {
                let (name, arguments) = self.take(&item["tool_call_id"]);
                self.push(name, arguments, text_of(&item["content"]));
            }
            _ => {}
        }
    }

    fn call(&mut self, id: &Value, name: &Value, arguments: String) {
        let name = name.as_str().unwrap_or("?").to_string();
        self.pending.insert(text_of(id), (name, arguments));
    }

    fn take(&mut self, id: &Value) -> (String, String) {
        self.pending.remove(&text_of(id)).unwrap_or_else(|| {
            self.out.unmatched_outputs += 1;
            ("?".into(), String::new())
        })
    }

    fn push(&mut self, name: String, arguments: String, output: String) {
        self.arrived.push(self.out.requests);
        self.out.calls.push(ToolCall {
            name,
            arguments,
            output,
            requests_after: 0,
        });
    }

    fn finish(mut self) -> Transcript {
        for (call, arrived) in self.out.calls.iter_mut().zip(&self.arrived) {
            call.requests_after = self.out.requests - arrived;
        }
        self.out
    }
}

/// A field as text: strings as they are, text parts joined, anything else as JSON.
fn text_of(value: &Value) -> String {
    match value {
        Value::Null => String::new(),
        Value::String(text) => text.clone(),
        Value::Array(parts) if parts.iter().all(|p| p["text"].is_string()) && !parts.is_empty() => {
            parts
                .iter()
                .filter_map(|p| p["text"].as_str())
                .collect::<Vec<_>>()
                .join("\n")
        }
        other => other.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn responses_items_pair_calls_with_outputs_and_count_requests() {
        let text = r#"
{"type":"message","role":"user","content":[{"type":"input_text","text":"fix it"}]}
{"type":"reasoning","id":"r1","summary":[],"encrypted_content":"x"}
{"type":"function_call","id":"f1","call_id":"c1","name":"read_file","arguments":"{\"path\":\"src/a.rs\"}"}
{"type":"function_call","id":"f2","call_id":"c2","name":"shell","arguments":"{\"cmd\":\"ls\"}"}
{"type":"function_call_output","call_id":"c2","output":"a.rs\nb.rs"}
{"type":"function_call_output","call_id":"c1","output":"fn main() {}"}
{"type":"tool_search_call","id":"s1","call_id":null,"arguments":{"query":"git"},"execution":"server"}
{"type":"tool_search_output","id":"s1","call_id":null,"execution":"server","tools":[{"name":"git_log"}]}
{"type":"custom_tool_call","call_id":"c3","name":"apply_patch","input":"*** Begin Patch"}
{"type":"function_call_output","call_id":"c3","output":"Done"}
{"type":"function_call_output","call_id":"lost","output":"orphan"}
{"type":"message","role":"assistant","content":[{"type":"output_text","text":"done"}]}
not json
"#;
        let t = parse(text);
        let names: Vec<&str> = t.calls.iter().map(|c| c.name.as_str()).collect();
        assert_eq!(
            names,
            ["shell", "read_file", "tool_search", "apply_patch", "?"]
        );
        assert_eq!(t.calls[1].arguments, r#"{"path":"src/a.rs"}"#);
        assert_eq!(t.calls[0].output, "a.rs\nb.rs");
        assert_eq!(t.calls[2].output, r#"[{"name":"git_log"}]"#);
        assert_eq!(t.calls[2].arguments, r#"{"query":"git"}"#);
        assert_eq!(t.requests, 4);
        assert_eq!(t.calls[0].requests_after, 3);
        assert_eq!(t.calls[4].requests_after, 1);
        assert_eq!((t.unreadable_lines, t.unmatched_outputs), (1, 1));
    }

    #[test]
    fn chat_rows_pair_tool_calls_with_tool_rows() {
        let text = r#"
{"role":"user","content":"hi"}
{"role":"assistant","content":null,"tool_calls":[{"id":"t1","type":"function","function":{"name":"grep","arguments":"{\"q\":\"x\"}"}}]}
{"role":"tool","tool_call_id":"t1","content":"src/a.rs:1:x"}
{"role":"assistant","content":"ok"}
"#;
        let t = parse(text);
        assert_eq!(t.calls.len(), 1);
        assert_eq!(
            (t.calls[0].name.as_str(), t.calls[0].output.as_str()),
            ("grep", "src/a.rs:1:x")
        );
        assert_eq!((t.requests, t.calls[0].requests_after), (2, 1));
        assert_eq!(
            text_of(
                &serde_json::json!([{"type": "text", "text": "a"}, {"type": "text", "text": "b"}])
            ),
            "a\nb"
        );
    }

    #[test]
    fn tokens_are_characters_over_four_rounded_up() {
        assert_eq!(
            (
                est_tokens(""),
                est_tokens("abc"),
                est_tokens("abcd"),
                est_tokens("abcde")
            ),
            (0, 1, 1, 2)
        );
        assert_eq!(est_tokens("éééé"), 1);
    }
}
