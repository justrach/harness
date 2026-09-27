//! Pasted/dropped images reach ACP agents that take them: the run's staged
//! attachments ride the first `session/prompt` as `image` blocks after the
//! text when `initialize` advertises `promptCapabilities.image`, a follow-up
//! turn's path refs do too, and they are left as path refs in the text
//! otherwise.

#![cfg(unix)]

use std::path::PathBuf;
use std::time::Duration;

use futures::StreamExt;
use harness_adapters::{AcpHarness, CancellationToken, Harness, RunControls, SteerMessage};
use harness_proto::{RunRequest, SandboxLevel};
use tokio::sync::{mpsc, oneshot};

/// The 8-byte PNG signature plus an IHDR start — enough for sniffing.
const PNG: &[u8] = b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR";

async fn sent_prompt(images: bool) -> serde_json::Value {
    let dir = tempfile::tempdir().unwrap();
    let image = dir.path().join("shot.png");
    std::fs::write(&image, PNG).unwrap();
    let fixture =
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/fake-acp-images.py");
    // The fixture reads the flag from its environment (inherited).
    unsafe { std::env::set_var("FAKE_ACP_IMAGES", if images { "1" } else { "0" }) };
    let harness = AcpHarness::graff().with_executable(fixture);
    let (_steer_tx, steering) = mpsc::channel(1);
    let controls = RunControls {
        request_input: Box::new(|_| {
            let (tx, rx) = oneshot::channel();
            let _ = tx.send(Vec::new());
            rx
        }),
        steering,
        interrupt: CancellationToken::new(),
        mcp_servers: Vec::new(),
    };
    let request = RunRequest {
        prompt: "What colour is this?".into(),
        harness: None,
        model: None,
        reasoning: None,
        model_options: Default::default(),
        cwd: dir.path().to_str().unwrap().into(),
        sandbox: SandboxLevel::WorkspaceWrite,
        auto_approve: true,
        attachments: vec![
            image.to_str().unwrap().into(),
            "/nonexistent/missing.png".into(),
        ],
        worktree: None,
        resume: None,
    };
    tokio::time::timeout(Duration::from_secs(10), async {
        harness
            .run(request, controls)
            .await
            .unwrap()
            .collect::<Vec<_>>()
            .await
    })
    .await
    .unwrap();
    serde_json::from_str(&std::fs::read_to_string(dir.path().join("prompt.json")).unwrap()).unwrap()
}

#[tokio::test]
async fn images_ride_the_first_prompt_only_when_the_agent_takes_them() {
    use base64::Engine as _;
    let with = sent_prompt(true).await;
    let blocks = with.as_array().unwrap();
    assert_eq!(blocks[0]["type"], "text");
    assert_eq!(
        blocks.len(),
        2,
        "one image; the unreadable path is skipped: {with}"
    );
    assert_eq!(blocks[1]["type"], "image");
    assert_eq!(blocks[1]["mimeType"], "image/png");
    let data = base64::engine::general_purpose::STANDARD
        .decode(blocks[1]["data"].as_str().unwrap())
        .unwrap();
    assert_eq!(data, PNG);

    let without = sent_prompt(false).await;
    assert_eq!(without.as_array().unwrap().len(), 1, "text only: {without}");
}

/// A follow-up sent while the first turn runs becomes the next
/// `session/prompt`; its `Attached images` refs ride as `image` blocks and
/// the wire text is just the message.
#[tokio::test]
async fn follow_up_turn_images_ride_as_blocks() {
    let second = follow_up_prompt(true).await;
    let blocks = second.as_array().unwrap();
    assert_eq!(blocks.len(), 2, "text + image: {second}");
    assert_eq!(blocks[1]["type"], "image");
    assert_eq!(
        blocks[0]["text"], "can you see this?",
        "no path trailer: {second}"
    );
    assert!(blocks[1]["uri"].as_str().unwrap().ends_with("/follow.png"));
}

/// A path that is only written in the prompt text (synced or pasted, not
/// resolved by the engine) is never read or sent.
#[tokio::test]
async fn follow_up_text_paths_alone_are_not_read() {
    let second = follow_up_prompt(false).await;
    let blocks = second.as_array().unwrap();
    assert_eq!(blocks.len(), 1, "text only: {second}");
    assert!(
        blocks[0]["text"]
            .as_str()
            .unwrap()
            .contains("open them to view")
    );
}

async fn follow_up_prompt(authorized: bool) -> serde_json::Value {
    let dir = tempfile::tempdir().unwrap();
    let image = dir.path().join("follow.png");
    std::fs::write(&image, PNG).unwrap();
    let path = image.to_str().unwrap().to_string();
    let fixture =
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/fake-acp-images.py");
    std::fs::write(
        dir.path().join("fixture.json"),
        r#"{"images":true,"turns":2}"#,
    )
    .unwrap();
    let harness = AcpHarness::graff().with_executable(fixture);
    let (steer_tx, steering) = mpsc::channel(1);
    let controls = RunControls {
        request_input: Box::new(|_| {
            let (tx, rx) = oneshot::channel();
            let _ = tx.send(Vec::new());
            rx
        }),
        steering,
        interrupt: CancellationToken::new(),
        mcp_servers: Vec::new(),
    };
    let request = RunRequest {
        prompt: "hi".into(),
        harness: None,
        model: None,
        reasoning: None,
        model_options: Default::default(),
        cwd: dir.path().to_str().unwrap().into(),
        sandbox: SandboxLevel::WorkspaceWrite,
        auto_approve: true,
        attachments: Vec::new(),
        worktree: None,
        resume: None,
    };
    let follow_up = format!(
        "can you see this?\n\nAttached images (local files — open them to view):\n- {path}"
    );
    tokio::time::timeout(Duration::from_secs(10), async {
        let stream = harness.run(request, controls).await.unwrap();
        steer_tx
            .send(SteerMessage {
                prompt: follow_up,
                message_id: None,
                // The engine resolved this upload; that is what authorizes it.
                attachments: if authorized {
                    vec![path.clone()]
                } else {
                    Vec::new()
                },
            })
            .await
            .unwrap();
        stream.collect::<Vec<_>>().await
    })
    .await
    .unwrap();

    let first: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(dir.path().join("prompt.json")).unwrap())
            .unwrap();
    assert_eq!(
        first.as_array().unwrap().len(),
        1,
        "no attachments on turn one: {first}"
    );
    serde_json::from_str(&std::fs::read_to_string(dir.path().join("prompt-2.json")).unwrap())
        .unwrap()
}
