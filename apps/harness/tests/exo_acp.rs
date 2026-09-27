//! End to end: the shared ACP harness drives Exo through the real
//! `harness exo-acp` bridge, onto a stand-in for Exo's agent-cli socket.

#![cfg(unix)]

use std::time::Duration;

use futures::StreamExt;
use harness_adapters::{AcpHarness, CancellationToken, Harness, RunControls};
use harness_proto::{AgentEvent, DoneStatus, HarnessId, RunRequest, SandboxLevel};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

#[tokio::test]
async fn exo_turn_runs_through_the_harness_bridge() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("agent-cli.sock");
    let listener = tokio::net::UnixListener::bind(&socket).unwrap();
    let (seen_tx, mut seen) = tokio::sync::mpsc::unbounded_channel::<serde_json::Value>();
    tokio::spawn(async move {
        while let Ok((stream, _)) = listener.accept().await {
            let (read, mut write) = stream.into_split();
            let mut lines = BufReader::new(read).lines();
            if let Ok(Some(line)) = lines.next_line().await {
                let request: serde_json::Value = serde_json::from_str(&line).unwrap();
                let reply = format!("Exo heard: {}", request["prompt"].as_str().unwrap());
                let _ = seen_tx.send(request);
                let line = serde_json::json!({ "type": "reply", "text": reply }).to_string();
                let _ = write.write_all(format!("{line}\n").as_bytes()).await;
            }
        }
    });
    // The bridge child inherits this; nothing else in this test binary reads it.
    unsafe { std::env::set_var("EXO_AGENT_CLI_SOCKET", &socket) };

    let harness = AcpHarness::exo().with_executable(env!("CARGO_BIN_EXE_harness"));
    assert_eq!(harness.id(), HarnessId::Exo);
    let (_steer_tx, steering) = tokio::sync::mpsc::channel(4);
    let controls = RunControls {
        request_input: Box::new(|_| tokio::sync::oneshot::channel().1),
        steering,
        interrupt: CancellationToken::new(),
        mcp_servers: Vec::new(),
    };
    let request = RunRequest {
        prompt: "summarize the repo".into(),
        harness: Some(HarnessId::Exo),
        model: Some("default".into()),
        reasoning: None,
        model_options: serde_json::Map::new(),
        cwd: dir.path().display().to_string(),
        sandbox: SandboxLevel::WorkspaceWrite,
        auto_approve: true,
        resume: None,
        attachments: Vec::new(),
        worktree: None,
    };
    let mut stream = harness.run(request, controls).await.expect("run starts");
    // The session parks after the turn while the steering mailbox lives, so
    // read up to the turn's Done like the engine does.
    let mut events = Vec::new();
    tokio::time::timeout(Duration::from_secs(30), async {
        while let Some(event) = stream.next().await {
            let event = event.expect("stream event");
            let done = matches!(event, AgentEvent::Done { .. });
            events.push(event);
            if done {
                break;
            }
        }
    })
    .await
    .unwrap_or_else(|_| panic!("turn finished in time: {events:?}"));

    let text: String = events
        .iter()
        .filter_map(|event| match event {
            AgentEvent::TextDelta { text } => Some(text.as_str()),
            _ => None,
        })
        .collect();
    assert_eq!(text, "Exo heard: summarize the repo", "{events:?}");
    assert!(
        events.iter().any(|event| matches!(
            event,
            AgentEvent::Done { status: DoneStatus::Completed, .. }
        )),
        "{events:?}"
    );
    let request = seen.recv().await.unwrap();
    assert_eq!(request["cwd"], dir.path().display().to_string());
}
