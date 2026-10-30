//! Runs `protocol/desktop/transcript.json` through `apply_transcript_frame`.
//! harness-nano runs the same file against its port (`apps/nano/src/parity.zig`).

use harness_doc::{MessagePart, SessionMessageEntry, TranscriptFrame, apply_transcript_frame};
use serde_json::{Value, json};

fn vectors() -> Value {
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../protocol/desktop/transcript.json"
    );
    serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap()
}

/// An entry as the vectors describe it: id, role, and its streamable texts.
fn summary(e: &SessionMessageEntry) -> Value {
    let texts: Vec<&str> = e
        .parts
        .iter()
        .filter_map(|p| match p {
            MessagePart::Text { text, .. } | MessagePart::Reasoning { text, .. } => {
                Some(text.as_str())
            }
            _ => None,
        })
        .collect();
    let role = serde_json::to_value(e.role).unwrap();
    json!({ "id": e.id, "role": role, "texts": texts })
}

#[test]
fn frames_apply_as_the_vectors_say() {
    for case in vectors()["cases"].as_array().unwrap() {
        let name = case["name"].as_str().unwrap();
        let mut entries: Vec<SessionMessageEntry> = Vec::new();
        let mut desync = None;
        for (i, f) in case["frames"].as_array().unwrap().iter().enumerate() {
            let frame: TranscriptFrame = serde_json::from_value(f.clone())
                .unwrap_or_else(|e| panic!("{name}: frame {i} doesn't parse: {e}"));
            if apply_transcript_frame(&mut entries, frame).is_err() {
                desync = Some(i as u64);
                break;
            }
        }
        match case.get("desyncAt") {
            Some(at) => assert_eq!(desync, at.as_u64(), "{name}"),
            None => {
                assert_eq!(desync, None, "{name}");
                let got: Vec<Value> = entries.iter().map(summary).collect();
                assert_eq!(Value::Array(got), case["expect"], "{name}");
            }
        }
    }
}
