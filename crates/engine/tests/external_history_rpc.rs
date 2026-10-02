//! Another tool's conversations reach the engine over its RPC: listed for
//! `/resume`, imported as a chat, and not offered again.
//!
//! One test per file: it points the engine at fake Claude Code and Codex
//! homes through the environment the engine reads at assembly.

use std::io::Write;
use std::sync::Arc;

use harness_engine::{EngineCore, registry::default_registry};
use harness_proto::HarnessId;
use serde_json::json;

#[tokio::test]
async fn a_conversation_from_another_tool_lists_imports_and_opens_as_a_chat() {
    let dir = tempfile::tempdir().unwrap();
    let claude = dir.path().join("claude");
    let project = claude.join("projects").join("-w-app");
    std::fs::create_dir_all(&project).unwrap();
    let mut f = std::fs::File::create(project.join("sess-1.jsonl")).unwrap();
    for line in [
        r#"{"type":"user","cwd":"/w/app","timestamp":"2026-09-01T10:00:01Z","message":{"role":"user","content":"make the build faster"}}"#,
        r#"{"type":"assistant","timestamp":"2026-09-01T10:00:02Z","message":{"role":"assistant","content":[{"type":"text","text":"Cached the deps."}]}}"#,
    ] {
        writeln!(f, "{line}").unwrap();
    }
    // SAFETY: this is the only test in the binary, so nothing else reads the environment.
    unsafe {
        std::env::set_var("CLAUDE_CONFIG_DIR", &claude);
        std::env::set_var("CODEX_HOME", dir.path().join("codex"));
    }

    let data = dir.path().join("data");
    std::fs::create_dir_all(&data).unwrap();
    let core = EngineCore::assemble(&data, Arc::new(default_registry()), HarnessId::Mock, None)
        .expect("engine assembles");
    let client = harness_rpc::memory_client(core.rpc_service());

    let listed = client
        .call(
            harness_rpc::methods::EXTERNAL_HISTORY_LIST,
            json!({ "cwd": "/w/app" }),
        )
        .await
        .unwrap();
    let rows = listed.as_array().expect("a list");
    assert_eq!(rows.len(), 1, "{listed}");
    assert_eq!(rows[0]["source"], "claude");
    assert_eq!(rows[0]["id"], "sess-1");
    assert_eq!(rows[0]["title"], "make the build faster");

    let summary = client
        .call(
            harness_rpc::methods::EXTERNAL_HISTORY_IMPORT,
            json!({ "sessions": [{ "source": "claude", "id": "sess-1" }] }),
        )
        .await
        .unwrap();
    assert_eq!(summary["imported"], 1, "{summary}");
    assert_eq!(summary["chatIds"], json!(["ext-claude-sess-1"]));

    let chat = core
        .workspace
        .chat("ext-claude-sess-1")
        .unwrap()
        .expect("the chat row exists");
    assert_eq!(chat.title.as_deref(), Some("make the build faster"));
    assert_eq!(
        chat.last_message_preview.as_deref(),
        Some("Cached the deps.")
    );

    // Open it the way the app does and read the transcript back.
    let handle = core
        .doc_host
        .open("ext-claude-sess-1")
        .expect("the chat opens");
    let transcript = handle.watch_messages().borrow().clone();
    assert_eq!(transcript.entries.len(), 2, "opening kept the conversation");
    assert_eq!(transcript.entries[0].role, harness_doc::MessageRole::User);

    let after = client
        .call(
            harness_rpc::methods::EXTERNAL_HISTORY_LIST,
            json!({ "cwd": "/w/app" }),
        )
        .await
        .unwrap();
    assert_eq!(
        after,
        json!([]),
        "an imported conversation is not offered again"
    );
}
