//! Session doc to transcript records: a port of `SessionStore.entryFrom` / `partFrom` / `joinContinuations` and
//! `SessionStore.queuedFrom` in the iOS app. Malformed entries and parts are skipped, never fatal, and kinds the
//! phone does not show are dropped, exactly as iOS does.

use std::collections::HashMap;

use serde_json::Value;

use crate::records::{
    MessageEntryRecord, MessagePartRecord, MessageRoleRecord, MessageStatusRecord,
    QueueDeliveryGateRecord, QueuedMessageRecord, TaskItemRecord, ToolFieldRecord,
    UserInputQuestionRecord,
};

/// A raw entry plus the root it continues (joined away before display).
struct RawEntry {
    entry: MessageEntryRecord,
    continuation_of: Option<String>,
}

fn text<'a>(map: &'a serde_json::Map<String, Value>, key: &str) -> Option<&'a str> {
    map.get(key).and_then(Value::as_str)
}

/// `LoroValue.i64Value`: integers, and doubles truncated.
fn int(value: &Value) -> Option<i64> {
    value.as_i64().or_else(|| value.as_f64().map(|f| f as i64))
}

const SUPPORTED_IMAGE_TYPES: [&str; 4] = ["image/png", "image/jpeg", "image/webp", "image/gif"];

fn part(value: &Value) -> Option<MessagePartRecord> {
    let m = value.as_object()?;
    let id = text(m, "id")?.to_owned();
    match text(m, "kind")? {
        "text" => Some(MessagePartRecord::Text {
            id,
            text: text(m, "text").unwrap_or_default().to_owned(),
        }),
        "image" => {
            let path = text(m, "path").unwrap_or_default().to_owned();
            let name = text(m, "name").unwrap_or_default().to_owned();
            let mime_type = text(m, "mimeType").unwrap_or_default().to_owned();
            // GeneratedImageReference.isValid
            let valid = path.starts_with('/')
                && !path.contains('\0')
                && !name.is_empty()
                && SUPPORTED_IMAGE_TYPES.contains(&mime_type.as_str());
            Some(if valid {
                MessagePartRecord::Image {
                    id,
                    path,
                    name,
                    mime_type,
                }
            } else {
                MessagePartRecord::Error {
                    id,
                    message: "Generated image unavailable".into(),
                    reauth: None,
                }
            })
        }
        "tool" => {
            let call = m.get("call")?.as_object()?;
            let tag = text(call, "kind").unwrap_or("unknown").to_owned();
            let mut fields = HashMap::new();
            for (key, v) in call {
                if key == "kind" {
                    continue;
                }
                let field = if let Some(s) = v.as_str() {
                    ToolFieldRecord::Text {
                        value: s.to_owned(),
                    }
                } else if let Some(b) = v.as_bool() {
                    ToolFieldRecord::Flag { value: b }
                } else if let Some(i) = int(v) {
                    ToolFieldRecord::Number { value: i }
                } else if let (true, Some(list)) = (tag == "todo" && key == "items", v.as_array()) {
                    ToolFieldRecord::Tasks {
                        items: list
                            .iter()
                            .filter_map(|item| {
                                let item = item.as_object()?;
                                Some(TaskItemRecord {
                                    text: text(item, "text")?.to_owned(),
                                    done: item
                                        .get("done")
                                        .and_then(Value::as_bool)
                                        .unwrap_or(false),
                                })
                            })
                            .collect(),
                    }
                } else if let Some(list) = v.as_array() {
                    ToolFieldRecord::Items {
                        items: list.iter().map(Value::to_string).collect(),
                    }
                } else {
                    continue;
                };
                fields.insert(key.clone(), field);
            }
            // The presence of isError is the resolution marker (schema.rs).
            let is_error = m.get("isError").and_then(Value::as_bool);
            Some(MessagePartRecord::Tool {
                id,
                tag,
                fields,
                is_error: is_error.unwrap_or(false),
                resolved: is_error.is_some(),
            })
        }
        "input" => {
            // All or nothing, like the Swift Decodable array: one bad question leaves the list empty.
            let questions = m
                .get("questions")
                .and_then(Value::as_array)
                .and_then(|list| list.iter().map(question).collect::<Option<Vec<_>>>())
                .unwrap_or_default();
            Some(MessagePartRecord::Input {
                request_id: id.clone(),
                id,
                questions,
                resolved: m.get("resolved").and_then(Value::as_bool).unwrap_or(false),
            })
        }
        "error" => Some(MessagePartRecord::Error {
            id,
            message: text(m, "message").unwrap_or_default().to_owned(),
            reauth: text(m, "reauth")
                .filter(|r| matches!(*r, "chatgpt-new" | "codex"))
                .map(str::to_owned),
        }),
        _ => None,
    }
}

fn question(value: &Value) -> Option<UserInputQuestionRecord> {
    let q = value.as_object()?;
    Some(UserInputQuestionRecord {
        id: text(q, "id")?.to_owned(),
        header: text(q, "header")?.to_owned(),
        question: text(q, "question")?.to_owned(),
        options: q
            .get("options")?
            .as_array()?
            .iter()
            .map(|o| o.as_str().map(str::to_owned))
            .collect::<Option<Vec<_>>>()?,
        multi_select: match q.get("multiSelect") {
            None | Some(Value::Null) => None,
            Some(v) => Some(v.as_bool()?),
        },
    })
}

fn entry(value: &Value) -> Option<RawEntry> {
    let m = value.as_object()?;
    let id = text(m, "id")?.to_owned();
    let role = match text(m, "role")? {
        "user" => MessageRoleRecord::User,
        "assistant" => MessageRoleRecord::Assistant,
        "system" => MessageRoleRecord::System,
        _ => return None,
    };
    let parts = m
        .get("parts")
        .and_then(Value::as_array)
        .map(|list| list.iter().filter_map(part).collect())
        .unwrap_or_default();
    let status = match text(m, "status") {
        Some("streaming") => Some(MessageStatusRecord::Streaming),
        Some("complete") => Some(MessageStatusRecord::Complete),
        Some("aborted") => Some(MessageStatusRecord::Aborted),
        _ => None,
    };
    Some(RawEntry {
        entry: MessageEntryRecord {
            id,
            role,
            parts,
            created_at: m.get("createdAt").and_then(int).unwrap_or(0),
            device_id: text(m, "deviceId").unwrap_or_default().to_owned(),
            status,
        },
        continuation_of: text(m, "continuationOf").map(str::to_owned),
    })
}

/// schema.rs `join_continuation_entries`: continuation parts append to their root in list order; orphans stand
/// alone.
fn join_continuations(raw: Vec<RawEntry>) -> Vec<MessageEntryRecord> {
    let mut roots: Vec<MessageEntryRecord> = Vec::new();
    let mut index: HashMap<String, usize> = HashMap::new();
    for RawEntry {
        entry,
        continuation_of,
    } in raw
    {
        if let Some(ix) = continuation_of.as_ref().and_then(|root| index.get(root)) {
            roots[*ix].parts.extend(entry.parts);
        } else {
            index.insert(entry.id.clone(), roots.len());
            roots.push(entry);
        }
    }
    roots
}

/// The doc's `messages` list (as JSON) to display entries.
pub fn entries(messages: &Value) -> Vec<MessageEntryRecord> {
    let raw = messages
        .as_array()
        .map(|list| list.iter().filter_map(entry).collect())
        .unwrap_or_default();
    join_continuations(raw)
}

/// `SessionStore.queuedFrom`: a row needs an id and non-blank text; unknown gates fail closed as review-required.
pub fn queued(value: &Value) -> Option<QueuedMessageRecord> {
    let m = value.as_object()?;
    // Swift trims `.whitespaces`: spaces and tabs, not line breaks.
    let id = text(m, "id")?
        .trim_matches(|c: char| {
            c.is_whitespace()
                && !matches!(
                    c,
                    '\n' | '\r' | '\u{0B}' | '\u{0C}' | '\u{85}' | '\u{2028}' | '\u{2029}'
                )
        })
        .to_owned();
    if id.is_empty() {
        return None;
    }
    let body = text(m, "text")?;
    if body.trim().is_empty() {
        return None;
    }
    Some(QueuedMessageRecord {
        id,
        text: body.to_owned(),
        attachments: m
            .get("attachments")
            .and_then(Value::as_array)
            .map(|list| {
                list.iter()
                    .filter_map(|v| v.as_str().map(str::to_owned))
                    .collect()
            })
            .unwrap_or_default(),
        issued_by: text(m, "issuedBy").unwrap_or_default().to_owned(),
        issued_at: m.get("issuedAt").and_then(int).unwrap_or(0),
        edited_at: m.get("editedAt").and_then(int),
        hold_for_turn_end: m
            .get("holdForTurnEnd")
            .and_then(Value::as_bool)
            .unwrap_or(false),
        delivery_gate: m.get("deliveryGate").and_then(gate),
    })
}

fn gate(value: &Value) -> Option<QueueDeliveryGateRecord> {
    let g = value.as_object()?;
    let kind = text(g, "kind")?;
    let owner = text(g, "ownerDeviceId")
        .unwrap_or("another device")
        .to_owned();
    Some(match kind {
        "editing" => QueueDeliveryGateRecord::Editing {
            owner_device_id: owner,
            expires_at_ms: g.get("expiresAtMs").and_then(int).unwrap_or(0),
        },
        _ => QueueDeliveryGateRecord::ReviewRequired {
            owner_device_id: owner,
        },
    })
}

pub fn queue(list: &Value) -> Vec<QueuedMessageRecord> {
    list.as_array()
        .map(|rows| rows.iter().filter_map(queued).collect())
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn continuations_join_their_root_and_orphans_stand_alone() {
        let entries = entries(&json!([
            {"id": "a", "role": "assistant", "createdAt": 1, "deviceId": "mac", "status": "complete",
             "parts": [{"id": "p1", "kind": "text", "text": "one"}]},
            {"id": "b", "role": "assistant", "continuationOf": "a",
             "parts": [{"id": "p2", "kind": "text", "text": "two"}]},
            {"id": "c", "role": "assistant", "continuationOf": "gone", "parts": []},
            {"id": "bad", "role": "robot", "parts": []},
            {"role": "user", "parts": []},
        ]));
        assert_eq!(
            entries.iter().map(|e| e.id.as_str()).collect::<Vec<_>>(),
            ["a", "c"]
        );
        assert_eq!(entries[0].parts.len(), 2);
        assert_eq!(entries[0].status, Some(MessageStatusRecord::Complete));
        assert_eq!(entries[1].device_id, "");
    }

    #[test]
    fn parts_decode_like_the_ios_app() {
        let entries = entries(&json!([{"id": "a", "role": "assistant", "parts": [
            {"id": "t", "kind": "tool", "call": {"kind": "exec", "command": "ls", "timeout": 5.9, "ok": true}, "isError": false},
            {"id": "u", "kind": "tool", "call": {"kind": "todo", "items": [{"text": "x", "done": true}, {"done": false}]}},
            {"id": "i", "kind": "image", "path": "relative.png", "name": "n", "mimeType": "image/png"},
            {"id": "q", "kind": "input", "questions": [{"id": "1", "header": "h", "question": "?", "options": ["a"]}, {"id": "2"}]},
            {"id": "e", "kind": "error", "message": "m", "reauth": "somewhere"},
            {"id": "r", "kind": "reasoning", "thinking": "hidden"},
        ]}]));
        let parts = &entries[0].parts;
        assert_eq!(parts.len(), 5, "unknown kinds are dropped");
        let MessagePartRecord::Tool {
            tag,
            fields,
            resolved,
            ..
        } = &parts[0]
        else {
            panic!()
        };
        assert_eq!(tag, "exec");
        assert!(*resolved);
        assert_eq!(fields["timeout"], ToolFieldRecord::Number { value: 5 });
        assert_eq!(fields["ok"], ToolFieldRecord::Flag { value: true });
        let MessagePartRecord::Tool {
            fields, resolved, ..
        } = &parts[1]
        else {
            panic!()
        };
        assert!(!*resolved, "no isError means still running");
        assert_eq!(
            fields["items"],
            ToolFieldRecord::Tasks {
                items: vec![TaskItemRecord {
                    text: "x".into(),
                    done: true
                }]
            }
        );
        assert_eq!(
            parts[2],
            MessagePartRecord::Error {
                id: "i".into(),
                message: "Generated image unavailable".into(),
                reauth: None
            }
        );
        let MessagePartRecord::Input { questions, .. } = &parts[3] else {
            panic!()
        };
        assert!(
            questions.is_empty(),
            "one bad question empties the list, as Swift's Decodable does"
        );
        let MessagePartRecord::Error { reauth, .. } = &parts[4] else {
            panic!()
        };
        assert_eq!(*reauth, None);
    }

    #[test]
    fn queue_rows_need_an_id_and_text_and_unknown_gates_fail_closed() {
        let rows = queue(&json!([
            {"id": " q1 ", "text": "hello", "issuedAt": 3, "deliveryGate": {"kind": "later"}},
            {"id": "q2", "text": "  "},
            {"text": "no id"},
            {"id": "q3", "text": "edit", "holdForTurnEnd": true,
             "deliveryGate": {"kind": "editing", "ownerDeviceId": "mac", "expiresAtMs": 9}},
        ]));
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].id, "q1");
        assert_eq!(
            rows[0].delivery_gate,
            Some(QueueDeliveryGateRecord::ReviewRequired {
                owner_device_id: "another device".into()
            })
        );
        assert!(rows[1].hold_for_turn_end);
        assert_eq!(
            rows[1].delivery_gate,
            Some(QueueDeliveryGateRecord::Editing {
                owner_device_id: "mac".into(),
                expires_at_ms: 9
            })
        );
    }
}
