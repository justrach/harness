//! A real synthetic ACP subprocess must publish text through WatchDocMessages
//! before session/prompt completes, with both transcript opening contracts.
use std::{sync::Arc, time::Duration};

use harness_adapters::AcpHarness;
use harness_doc::{
    MessagePart, MessageRole, MessageStatus, SessionCommandPayload, SessionMessageEntry,
    TranscriptUpdate, transcript_delta::apply_transcript_frame,
};
use harness_engine::{EngineCore, HarnessRegistry};
use harness_proto::{HarnessId, RunRequest, SandboxLevel, SessionStatus};
use harness_rpc::methods;
use serde_json::json;

fn assistant_with<'a>(
    entries: &'a [SessionMessageEntry],
    needle: &str,
) -> Option<&'a SessionMessageEntry> {
    entries.iter().find(|entry| {
        entry.role == MessageRole::Assistant
            && entry
                .parts
                .iter()
                .any(|part| matches!(part, MessagePart::Text { text, .. } if text.contains(needle)))
    })
}

fn apply(entries: &mut Vec<SessionMessageEntry>, value: serde_json::Value) {
    let update: TranscriptUpdate = serde_json::from_value(value).expect("valid transcript update");
    apply_transcript_frame(entries, update.frame).expect("contiguous transcript frames");
}

#[tokio::test]
async fn acp_text_reaches_watch_doc_messages_while_prompt_is_pending() {
    let dir = tempfile::tempdir().unwrap();
    let registry = HarnessRegistry::new();
    let fixture = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../harness/tests/fixtures/acp-lifecycle.py");
    registry.register(Arc::new(AcpHarness::devin().with_executable(fixture)));
    let core =
        EngineCore::assemble(dir.path(), Arc::new(registry), HarnessId::Devin, None).unwrap();
    let client = harness_rpc::memory_client(core.rpc_service());
    let chat = "synthetic-acp-streaming";
    let handle = core.doc_host.open(chat).unwrap();

    let mut full = client
        .subscribe(methods::WATCH_DOC_MESSAGES, json!({ "chatId": chat }))
        .await
        .unwrap();
    let mut opening = client
        .subscribe(
            methods::WATCH_DOC_MESSAGES,
            json!({ "chatId": chat, "openingTail": true }),
        )
        .await
        .unwrap();
    let mut full_entries = Vec::new();
    let mut opening_entries = Vec::new();
    tokio::time::timeout(Duration::from_secs(5), async {
        apply(&mut full_entries, full.recv().await.unwrap());
        let preview = opening.recv().await.unwrap();
        assert_eq!(preview["historyPending"], true);
        apply(&mut opening_entries, preview);
        // The opening-tail preview is followed by an authoritative reset.
        apply(&mut opening_entries, opening.recv().await.unwrap());
    })
    .await
    .expect("both public RPC watches attach before dispatch");

    let command = SessionCommandPayload::Run {
        message_id: "synthetic-user".into(),
        request: RunRequest {
            turn_origin: Default::default(),
            prompt: "streaming".into(),
            harness: None,
            model: None,
            reasoning: None,
            model_options: Default::default(),
            cwd: dir.path().display().to_string(),
            sandbox: SandboxLevel::WorkspaceWrite,
            auto_approve: true,
            attachments: Vec::new(),
            worktree: None,
            resume: None,
        },
    };
    client
        .call(
            methods::QUEUE_COMMAND,
            json!({ "chatId": chat, "command": command }),
        )
        .await
        .unwrap();

    // The peer flushes "working", then holds its prompt response for 3.6s.
    // A completion-only publication cannot satisfy this deadline or status.
    tokio::time::timeout(Duration::from_millis(2500), async {
        while assistant_with(&full_entries, "working").is_none()
            || assistant_with(&opening_entries, "working").is_none()
        {
            tokio::select! {
                value = full.recv() => apply(&mut full_entries, value.expect("full watch remains live")),
                value = opening.recv() => apply(&mut opening_entries, value.expect("opening watch remains live")),
            }
        }
    })
    .await
    .expect("ACP text must reach both RPC watches before prompt completion");
    for entries in [&full_entries, &opening_entries] {
        let assistant = assistant_with(entries, "working").unwrap();
        assert_eq!(assistant.status, Some(MessageStatus::Streaming));
        assert!(assistant_with(entries, "finished").is_none());
    }
    assert_eq!(
        core.sessions.session_status(chat).unwrap().status,
        SessionStatus::Working
    );
    let persisted = handle.doc().read_entries().unwrap();
    assert_eq!(
        assistant_with(&persisted, "working").unwrap().status,
        Some(MessageStatus::Streaming)
    );

    tokio::time::timeout(Duration::from_secs(10), async {
        loop {
            let completed = |entries: &[SessionMessageEntry]| {
                assistant_with(entries, "workingfinished")
                    .is_some_and(|entry| entry.status == Some(MessageStatus::Complete))
            };
            if completed(&full_entries) && completed(&opening_entries) {
                break;
            }
            tokio::select! {
                value = full.recv() => apply(&mut full_entries, value.expect("full watch remains live")),
                value = opening.recv() => apply(&mut opening_entries, value.expect("opening watch remains live")),
            }
        }
    })
    .await
    .expect("both watches eventually publish the completed response");
    core.shutdown().await;
}
