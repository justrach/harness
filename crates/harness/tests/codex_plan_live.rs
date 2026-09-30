//! Live check of the ChatGPT-plan provider against the real `codex` CLI.
//!
//! Ignored by default: it needs this host signed in to ChatGPT from Harness
//! (`cargo run -p harness-adapters --example chatgpt_sign_in`).
//! Run with an empty CODEX_HOME so Codex has no login of its own and only the
//! plan token can work:
//!
//! ```text
//! CODEX_HOME=$(mktemp -d) HARNESS_CHATGPT_PLAN=1 \
//!   cargo test -p harness-adapters --test codex_plan_live -- --ignored --nocapture
//! ```

#![cfg(unix)]

use std::time::Duration;

use futures::StreamExt;
use harness_adapters::{CancellationToken, CodexHarness, Harness, RunControls};
use harness_proto::{AgentEvent, DoneStatus, RunRequest, SandboxLevel};
use tokio::sync::{mpsc, oneshot};

#[tokio::test]
#[ignore = "needs a real ChatGPT sign-in and network"]
async fn a_turn_runs_on_the_plan_token_with_no_codex_login() {
    assert!(
        std::env::var_os("HARNESS_CHATGPT_PLAN").is_some(),
        "set HARNESS_CHATGPT_PLAN=1"
    );
    let harness = CodexHarness::new();
    let models = harness.models().await.expect("model list");
    println!(
        "models: {:?}",
        models.iter().map(|m| &m.id).collect::<Vec<_>>()
    );
    let model = std::env::var("PLAN_MODEL")
        .ok()
        .or_else(|| models.first().map(|m| m.id.clone()));

    let (_steer_tx, steer_rx) = mpsc::channel(1);
    let controls = RunControls {
        origin: None,
        request_input: Box::new(|_| {
            let (tx, rx) = oneshot::channel();
            let _ = tx.send(Vec::new());
            rx
        }),
        steering: steer_rx,
        interrupt: CancellationToken::new(),
    };
    let dir = tempfile::tempdir().unwrap();
    let request = RunRequest {
        prompt: "Reply with exactly the word: pong".into(),
        harness: None,
        model,
        reasoning: None,
        model_options: serde_json::Map::new(),
        cwd: dir.path().to_string_lossy().into_owned(),
        sandbox: SandboxLevel::ReadOnly,
        auto_approve: false,
        attachments: Vec::new(),
        worktree: None,
        resume: None,
    };
    let mut stream = harness.run(request, controls).await.expect("run starts");
    let mut events = Vec::new();
    let deadline = tokio::time::Instant::now() + Duration::from_secs(60);
    while let Ok(Some(next)) = tokio::time::timeout_at(deadline, stream.next()).await {
        let event = next.expect("stream event");
        println!(
            "event: {}",
            format!("{event:?}").chars().take(160).collect::<String>()
        );
        let done = matches!(event, AgentEvent::Done { .. });
        events.push(event);
        if done {
            break;
        }
    }
    assert!(events.iter().any(|e| matches!(
        e,
        AgentEvent::Done {
            status: DoneStatus::Completed,
            ..
        }
    )));
}
