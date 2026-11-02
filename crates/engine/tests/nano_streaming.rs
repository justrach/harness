//! Synthetic Graff ACP -> public Nano transcript RPC, before the prompt completes.
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
    let update: TranscriptUpdate = serde_json::from_value(value).expect("valid public RPC update");
    apply_transcript_frame(entries, update.frame).expect("contiguous transcript frames");
}

#[tokio::test]
async fn nano_watch_observes_graff_text_before_prompt_completion() {
    let dir = tempfile::tempdir().unwrap();
    let registry = HarnessRegistry::new();
    let fixture = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../harness/tests/fixtures/acp-lifecycle.py");
    registry.register(Arc::new(AcpHarness::graff().with_executable(fixture)));
    let core =
        EngineCore::assemble(dir.path(), Arc::new(registry), HarnessId::Graff, None).unwrap();
    let client = harness_rpc::memory_client(core.rpc_service());
    let chat = "synthetic-nano-streaming";
    let _handle = core.doc_host.open(chat).unwrap();

    // Match Nano's opening subscription, including the preview -> reset contract.
    // The in-memory transport still dispatches the public engine RPC service.
    let mut watch = client
        .subscribe(
            methods::WATCH_DOC_MESSAGES,
            json!({ "chatId": chat, "openingTail": true }),
        )
        .await
        .unwrap();
    let mut entries = Vec::new();
    tokio::time::timeout(Duration::from_secs(5), async {
        let preview = watch.recv().await.expect("opening preview");
        assert_eq!(preview["historyPending"], true);
        apply(&mut entries, preview);
        apply(
            &mut entries,
            watch.recv().await.expect("authoritative reset"),
        );
    })
    .await
    .expect("watch must attach before the run is queued");

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

    // The real subprocess flushes "working", waits 3.6 seconds, then emits
    // "finished" and responds to session/prompt. Completion-only publication
    // cannot satisfy either this shorter deadline or the streaming status.
    tokio::time::timeout(Duration::from_millis(2500), async {
        while assistant_with(&entries, "working").is_none() {
            apply(
                &mut entries,
                watch.recv().await.expect("watch remains live"),
            );
        }
    })
    .await
    .expect("Nano's public watch must publish text before the ACP response");
    assert_eq!(
        assistant_with(&entries, "working").unwrap().status,
        Some(MessageStatus::Streaming)
    );
    assert!(assistant_with(&entries, "finished").is_none());
    assert_eq!(
        core.sessions.session_status(chat).unwrap().status,
        SessionStatus::Working
    );

    // Also prove that this is the same turn which later actually completes.
    tokio::time::timeout(Duration::from_secs(10), async {
        while !assistant_with(&entries, "workingfinished")
            .is_some_and(|entry| entry.status == Some(MessageStatus::Complete))
        {
            apply(
                &mut entries,
                watch.recv().await.expect("watch remains live"),
            );
        }
    })
    .await
    .expect("watch must eventually publish the completed ACP response");
    core.shutdown().await;
}
