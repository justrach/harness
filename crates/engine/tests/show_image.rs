//! show_image regression coverage: the explicit agent-facing image intake.
//!
//! A live run accepts a workspace raster via `SessionsEngine::show_image`,
//! folds it as a managed-upload `GeneratedImage` in transcript order, dedupes
//! a re-sent request id, ACKs only after journal + doc sync, and rejects
//! anything outside the run's current cwd, non-raster content,
//! oversize/missing/non-regular sources, and requests for parked,
//! interrupted, or absent runs. The RPC layer gates on chat ownership and
//! never forwards to another device.

use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use futures::stream::BoxStream;

use harness_adapters::{Harness, HarnessError, RunControls};
use harness_doc::MessagePart;
use harness_engine::{EngineCore, HarnessRegistry};
use harness_proto::{
    AgentEvent, DoneStatus, HarnessId, Model, ReasoningLevel, RunRequest, SandboxLevel,
    SessionStatus, SteeringMode,
};

const CHAT: &str = "chat-show-image";
/// A real 1x1 PNG (decodes in any image viewer) — not just a magic signature.
const PNG: &[u8] = b"\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0d\x49\x48\x44\x52\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\x0d\x49\x44\x41\x54\x78\xda\x63\xfc\xcf\xc0\x50\x0f\x00\x04\x85\x01\x80\x84\xa9\x8c\x21\x00\x00\x00\x00\x49\x45\x4e\x44\xae\x42\x60\x82";

fn done(status: DoneStatus) -> AgentEvent {
    AgentEvent::Done {
        status,
        result: None,
        error: None,
        session_id: Some("hs-1".into()),
    }
}

fn run_request(cwd: &std::path::Path) -> RunRequest {
    RunRequest {
        prompt: "work".into(),
        harness: None,
        model: None,
        reasoning: None,
        model_options: Default::default(),
        cwd: cwd.to_string_lossy().into_owned(),
        sandbox: SandboxLevel::WorkspaceWrite,
        auto_approve: true,
        attachments: Vec::new(),
        worktree: None,
        resume: None,
    }
}

/// Channel-backed harness: the test pushes events through the live run so the
/// image request can be sequenced exactly between text parts and Done. The
/// stream stays open until the sender is dropped, which is also how the run
/// stays "working" between assertions.
struct ChannelHarness {
    tx: std::sync::Mutex<Option<tokio::sync::mpsc::Sender<Result<AgentEvent, HarnessError>>>>,
}

impl ChannelHarness {
    fn new() -> Self {
        Self {
            tx: std::sync::Mutex::new(None),
        }
    }

    async fn emit(&self, event: AgentEvent) {
        let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
        let tx = loop {
            if let Some(tx) = self.tx.lock().unwrap().clone() {
                break tx;
            }
            assert!(
                tokio::time::Instant::now() < deadline,
                "timed out waiting for the run to start"
            );
            tokio::time::sleep(Duration::from_millis(10)).await;
        };
        tx.send(Ok(event)).await.expect("run alive");
    }

    fn close(&self) {
        self.tx.lock().unwrap().take();
    }
}

#[async_trait]
impl Harness for ChannelHarness {
    fn id(&self) -> HarnessId {
        HarnessId::Mock
    }
    fn display_name(&self) -> &str {
        "Channel"
    }
    fn supports_steering(&self) -> bool {
        true
    }
    fn steering_mode(&self) -> SteeringMode {
        SteeringMode::StepBoundary
    }
    fn reasoning_levels(&self) -> &[ReasoningLevel] {
        &[ReasoningLevel::Medium]
    }
    async fn models(&self) -> Result<Vec<Model>, HarnessError> {
        Ok(vec![])
    }
    async fn run(
        &self,
        _request: RunRequest,
        _controls: RunControls,
    ) -> Result<BoxStream<'static, Result<AgentEvent, HarnessError>>, HarnessError> {
        let (tx, rx) = tokio::sync::mpsc::channel::<Result<AgentEvent, HarnessError>>(16);
        *self.tx.lock().unwrap() = Some(tx);
        Ok(Box::pin(futures::stream::unfold(rx, |mut rx| async move {
            rx.recv().await.map(|event| (event, rx))
        })))
    }
}

fn assemble(dir: &std::path::Path, harness: Arc<ChannelHarness>) -> EngineCore {
    let registry = HarnessRegistry::new();
    registry.register(harness);
    EngineCore::assemble(dir, Arc::new(registry), HarnessId::Mock, None)
        .expect("engine core assembles")
}

async fn wait_for<F>(mut predicate: F, what: &str)
where
    F: FnMut() -> bool,
{
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    while !predicate() {
        assert!(
            tokio::time::Instant::now() < deadline,
            "timed out waiting for {what}"
        );
        tokio::time::sleep(Duration::from_millis(15)).await;
    }
}

fn parts(core: &EngineCore) -> Vec<MessagePart> {
    core.doc_host
        .open(CHAT)
        .expect("open chat")
        .doc()
        .read_entries()
        .expect("read entries")
        .into_iter()
        .flat_map(|e| e.parts)
        .collect()
}

fn image_parts(core: &EngineCore) -> Vec<(String, String)> {
    parts(core)
        .into_iter()
        .filter_map(|p| {
            if let MessagePart::Image { path, name, .. } = p {
                Some((path, name))
            } else {
                None
            }
        })
        .collect()
}

fn text_present(core: &EngineCore, needle: &str) -> bool {
    parts(core).iter().any(|p| {
        if let MessagePart::Text { text, .. } = p {
            text.contains(needle)
        } else {
            false
        }
    })
}

#[tokio::test]
async fn show_image_publishes_in_order_and_stays_durable() {
    let dir = tempfile::tempdir().unwrap();
    let data_dir = dir.path().join("engine");
    let workspace = dir.path().join("ws");
    std::fs::create_dir_all(&workspace).unwrap();
    let source = workspace.join("shot.png");
    std::fs::write(&source, PNG).unwrap();

    let managed_path;
    {
        let harness = Arc::new(ChannelHarness::new());
        let core = assemble(&data_dir, harness.clone());
        core.sessions
            .dispatch(CHAT, HarnessId::Mock, run_request(&workspace), None)
            .await
            .unwrap();

        // Ordering: wait for the first text to be journaled/folded so a
        // biased select can never interleave the queued image ahead of it.
        harness
            .emit(AgentEvent::TextDelta {
                text: "before".into(),
            })
            .await;
        wait_for(|| text_present(&core, "before"), "preceding text part").await;

        let image = core
            .sessions
            .show_image(CHAT, "req-1", "shot.png", Some("first capture".into()))
            .await
            .expect("workspace image imports");
        // ACK = accepted into journal+doc: the Image part must exist already.
        wait_for(|| image_parts(&core).len() == 1, "image part synced").await;

        // Same request id (the client's unary reconnect retry re-sends the
        // same params) dedupes to the one published image — no second event.
        let again = core
            .sessions
            .show_image(CHAT, "req-1", "shot.png", Some("ignored".into()))
            .await
            .expect("resent request id resolves to the same import");
        assert_eq!(again, image);
        // The deduped result carries the FIRST request's metadata.
        assert_eq!(again.name, "first capture");

        harness
            .emit(AgentEvent::TextDelta {
                text: "after".into(),
            })
            .await;
        harness.emit(done(DoneStatus::Completed)).await;
        wait_for(
            || {
                core.sessions
                    .session_status(CHAT)
                    .is_some_and(|s| s.status == SessionStatus::Idle)
            },
            "turn done",
        )
        .await;
        tokio::time::sleep(Duration::from_millis(50)).await;

        let (path, name) = &image_parts(&core)[0];
        managed_path = path.clone();
        assert_eq!(name, "first capture");
        assert_eq!(image.path, *path);
        assert!(
            std::path::Path::new(path).starts_with(core.uploads.dir().canonicalize().unwrap()),
            "{path} must live under managed uploads"
        );
        assert!(!path.contains("ws/shot.png"));
        let kinds: Vec<&str> = parts(&core)
            .iter()
            .map(|p| match p {
                MessagePart::Text { .. } => "text",
                MessagePart::Image { .. } => "image",
                _ => "other",
            })
            .collect();
        let first_text = kinds.iter().position(|k| *k == "text").unwrap();
        let image_at = kinds.iter().position(|k| *k == "image").unwrap();
        let last_text = kinds.iter().rposition(|k| *k == "text").unwrap();
        assert!(first_text < image_at && image_at < last_text, "{kinds:?}");

        harness.close();
        // Snapshot every open doc before teardown so the reassembled engine
        // sees the committed transcript (snapshot saves are debounced).
        core.doc_host.shutdown_workers().await;
        core.sessions.shutdown().await;
        drop(core);
    }

    // Source deleted before reassembly: the managed copy is the durable truth.
    std::fs::remove_file(&source).unwrap();
    assert_eq!(std::fs::read(&managed_path).unwrap(), PNG);
    {
        let harness = Arc::new(ChannelHarness::new());
        let core = assemble(&data_dir, harness);
        let reopened = image_parts(&core);
        assert_eq!(reopened.len(), 1);
        assert_eq!(reopened[0].0, managed_path);
        assert_eq!(reopened[0].1, "first capture");
        core.sessions.shutdown().await;
    }
}

#[tokio::test]
async fn show_image_rejects_out_of_jail_and_bad_sources() {
    let dir = tempfile::tempdir().unwrap();
    let workspace = dir.path().join("ws");
    std::fs::create_dir_all(&workspace).unwrap();
    let outside = dir.path().join("outside.png");
    std::fs::write(&outside, PNG).unwrap();
    std::fs::write(workspace.join("ok.png"), PNG).unwrap();
    std::fs::write(workspace.join("fake.png"), b"<svg>not a raster</svg>").unwrap();
    let oversized = workspace.join("big.png");
    std::fs::File::create(&oversized)
        .unwrap()
        .set_len(25 * 1024 * 1024)
        .unwrap();
    std::fs::create_dir_all(workspace.join("adir.png")).unwrap();

    let harness = Arc::new(ChannelHarness::new());
    let core = assemble(dir.path(), harness.clone());
    core.sessions
        .dispatch(CHAT, HarnessId::Mock, run_request(&workspace), None)
        .await
        .unwrap();

    let attach_error = "show_image could not attach the file; use a supported raster image inside the active workspace (maximum 24 MiB)";
    // (case label, request id, path)
    let cases: Vec<(&str, &str, String)> = vec![
        ("traversal", "bad-0", "../outside.png".into()),
        (
            "absolute-outside",
            "bad-1",
            outside.to_string_lossy().into_owned(),
        ),
        ("extension-spoof", "bad-2", "fake.png".into()),
        ("oversized", "bad-3", "big.png".into()),
        ("missing", "bad-4", "nope.png".into()),
        ("nonregular", "bad-5", "adir.png".into()),
        ("url", "bad-6", "https://example.com/x.png".into()),
        ("blank-path", "bad-7", "   ".into()),
        ("overlong-path", "bad-8", "x".repeat(4097)),
        ("bad-id-nul", "req\0nul", "ok.png".into()),
        ("bad-id-symbol", "req@x", "ok.png".into()),
    ];
    for (case, id, path) in &cases {
        let err = core
            .sessions
            .show_image(CHAT, id, path, None)
            .await
            .expect_err(&format!("{case} must be rejected"));
        assert!(
            !err.to_string().contains(dir.path().to_str().unwrap()),
            "{case} error leaks paths: {err}"
        );
        if !matches!(*case, "bad-id-nul" | "bad-id-symbol") {
            assert_eq!(err.to_string(), attach_error, "{case}");
        }
        assert_eq!(image_parts(&core), vec![], "{case} must not publish");
    }
    // Overlong caption is rejected before touching the file.
    core.sessions
        .show_image(CHAT, "cap-1", "ok.png", Some("c".repeat(201)))
        .await
        .expect_err("overlong caption must be rejected");
    #[cfg(unix)]
    {
        let link = workspace.join("escape.png");
        std::os::unix::fs::symlink(&outside, &link).unwrap();
        core.sessions
            .show_image(CHAT, "bad-symlink", "escape.png", None)
            .await
            .expect_err("symlink escape must be rejected");
        assert!(image_parts(&core).is_empty());
    }
    assert_eq!(image_parts(&core).len(), 0);
    // Sources are untouched: nothing was copied or deleted.
    assert_eq!(std::fs::read(&outside).unwrap(), PNG);
    assert!(std::fs::metadata(&oversized).unwrap().len() > 24 * 1024 * 1024);
    harness.close();
    core.sessions.shutdown().await;
}

#[tokio::test]
async fn show_image_rejects_without_live_run_and_when_parked() {
    let dir = tempfile::tempdir().unwrap();
    let workspace = dir.path().join("ws");
    std::fs::create_dir_all(&workspace).unwrap();
    std::fs::write(workspace.join("shot.png"), PNG).unwrap();

    let harness = Arc::new(ChannelHarness::new());
    let core = assemble(dir.path(), harness.clone());
    // No run at all.
    core.sessions
        .show_image(CHAT, "idle-0", "shot.png", None)
        .await
        .expect_err("no active run must reject");

    core.sessions
        .dispatch(CHAT, HarnessId::Mock, run_request(&workspace), None)
        .await
        .unwrap();
    harness.emit(done(DoneStatus::Completed)).await;
    wait_for(
        || {
            core.sessions
                .session_status(CHAT)
                .is_some_and(|s| s.status == SessionStatus::Idle)
        },
        "parked idle session",
    )
    .await;
    let err = core
        .sessions
        .show_image(CHAT, "idle-1", "shot.png", None)
        .await
        .expect_err("parked idle run must reject");
    assert!(err.to_string().contains("idle"));
    assert!(image_parts(&core).is_empty());

    // Stream closed on a parked session retires the run: now the handle is
    // gone entirely and the request fails the same "no active run" path.
    harness.close();
    wait_for(
        || {
            core.sessions
                .session_status(CHAT)
                .is_none_or(|s| s.status != SessionStatus::Working)
        },
        "retired run",
    )
    .await;
    let err = core
        .sessions
        .show_image(CHAT, "idle-2", "shot.png", None)
        .await
        .expect_err("retired run must reject");
    assert!(!err.to_string().contains(dir.path().to_str().unwrap()));
    core.sessions.shutdown().await;
}

#[tokio::test]
async fn show_image_rejects_when_interrupted_mid_request() {
    let dir = tempfile::tempdir().unwrap();
    let workspace = dir.path().join("ws");
    std::fs::create_dir_all(&workspace).unwrap();
    std::fs::write(workspace.join("shot.png"), PNG).unwrap();

    let harness = Arc::new(ChannelHarness::new());
    let core = assemble(dir.path(), harness.clone());
    core.sessions
        .dispatch(CHAT, HarnessId::Mock, run_request(&workspace), None)
        .await
        .unwrap();
    // Interrupt BEFORE the request is serviced: the cancel flag is observed
    // in the mailbox arm and the request is rejected with no image part and
    // no hanging ACK.
    core.sessions.interrupt(CHAT).await.unwrap();
    let err = tokio::time::timeout(
        Duration::from_secs(10),
        core.sessions.show_image(CHAT, "int-1", "shot.png", None),
    )
    .await
    .expect("reply must resolve, not hang")
    .expect_err("interrupted run must reject");
    // Any rejection is fine (interrupted mailbox arm or retired run); it must
    // not leak paths.
    assert!(!err.to_string().contains(workspace.to_str().unwrap()));
    assert!(image_parts(&core).is_empty());
    harness.close();
    core.sessions.shutdown().await;
}

#[tokio::test]
async fn show_image_rpc_gate_and_success() {
    use harness_rpc::{memory_client, methods};

    let dir = tempfile::tempdir().unwrap();
    let data_dir = dir.path().join("engine");
    let workspace = dir.path().join("ws");
    std::fs::create_dir_all(&workspace).unwrap();
    std::fs::write(workspace.join("shot.png"), PNG).unwrap();

    let harness = Arc::new(ChannelHarness::new());
    let core = assemble(&data_dir, harness.clone());
    let client = memory_client(core.rpc_service());

    // Chat must exist AND belong to this device.
    let missing = client
        .call(
            methods::SHOW_IMAGE,
            serde_json::json!({ "chatId": "ghost", "id": "rpc-0", "path": "shot.png" }),
        )
        .await
        .unwrap_err();
    assert!(missing.to_string().contains("chat not found"));

    core.workspace
        .create_chat(
            CHAT,
            None,
            Some(&core.device_id),
            None,
            Some(workspace.to_string_lossy().into_owned()),
        )
        .expect("create chat row");

    // Unknown fields are rejected outright (deny_unknown_fields).
    let bad_args = client
        .call(
            methods::SHOW_IMAGE,
            serde_json::json!({
                "chatId": CHAT, "id": "rpc-0", "path": "shot.png", "bogus": true
            }),
        )
        .await
        .unwrap_err();
    assert!(bad_args.to_string().contains("unknown field"));

    // Valid params, but no live run yet.
    let no_run = client
        .call(
            methods::SHOW_IMAGE,
            serde_json::json!({ "chatId": CHAT, "id": "rpc-0", "path": "shot.png" }),
        )
        .await
        .unwrap_err();
    assert!(no_run.to_string().contains("No active run"));

    core.sessions
        .dispatch(CHAT, HarnessId::Mock, run_request(&workspace), None)
        .await
        .unwrap();

    let ok = client
        .call(
            methods::SHOW_IMAGE,
            serde_json::json!({ "chatId": CHAT, "id": "rpc-1", "path": "shot.png", "caption": "ui" }),
        )
        .await
        .expect("SHOW_IMAGE succeeds on a live run");
    assert_eq!(ok["attached"], true);
    assert_eq!(ok["id"], "show-image:rpc-1");
    assert_eq!(ok["name"], "ui");
    assert_eq!(ok["mimeType"], "image/png");
    // The Image part is already journaled/folded when the call resolves.
    wait_for(|| image_parts(&core).len() == 1, "rpc image part").await;
    let (path, name) = &image_parts(&core)[0];
    assert_eq!(name, "ui");
    assert!(std::path::Path::new(path).is_file());

    // A chat row hosted on ANOTHER device is refused even with a live run here.
    core.workspace
        .create_chat("chat-remote", None, Some("other-device"), None, None)
        .expect("remote-host chat row");
    let wrong_host = client
        .call(
            methods::SHOW_IMAGE,
            serde_json::json!({ "chatId": "chat-remote", "id": "rpc-2", "path": "shot.png" }),
        )
        .await
        .unwrap_err();
    assert!(wrong_host.to_string().contains("another device"));

    harness.emit(done(DoneStatus::Completed)).await;
    harness.close();
    core.sessions.shutdown().await;
}
