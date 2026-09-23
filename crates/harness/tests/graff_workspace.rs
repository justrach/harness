//! A GUI-owned checkout stays the selected ACP workspace when a saved graff
//! session is loaded. The fake server rejects the load if auto-isolation is on.

#![cfg(unix)]

use std::path::PathBuf;
use std::time::Duration;

use futures::StreamExt;
use harness_adapters::{AcpHarness, CancellationToken, Harness, RunControls};
use harness_proto::{AgentEvent, DoneStatus, RunRequest, SandboxLevel};
use tokio::sync::{mpsc, oneshot};

#[tokio::test]
async fn graff_acp_restores_in_the_selected_workspace() {
    let fixture =
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/fake-graff-workspace.py");
    let dir = tempfile::tempdir().unwrap();
    let cwd = dir.path().to_str().unwrap().to_owned();
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
    };
    let request = RunRequest {
        prompt: "Hello".into(),
        harness: None,
        model: None,
        reasoning: None,
        model_options: Default::default(),
        cwd: cwd.clone(),
        sandbox: SandboxLevel::WorkspaceWrite,
        auto_approve: true,
        attachments: Vec::new(),
        worktree: None,
        resume: Some("saved".into()),
    };
    let events = tokio::time::timeout(Duration::from_secs(10), async {
        harness
            .run(request, controls)
            .await
            .unwrap()
            .collect::<Vec<_>>()
            .await
    })
    .await
    .unwrap();
    let events: Vec<_> = events.into_iter().map(Result::unwrap).collect();
    assert!(
        events.iter().any(|event| matches!(event,
            AgentEvent::SessionStarted { session_id, cwd: active, .. }
                if session_id == "saved" && active == &cwd
        )),
        "{events:?}"
    );
    assert!(
        events.iter().any(|event| matches!(
            event,
            AgentEvent::Done {
                status: DoneStatus::Completed,
                ..
            }
        )),
        "{events:?}"
    );
    assert!(
        !events
            .iter()
            .any(|event| matches!(event, AgentEvent::Error { .. })),
        "{events:?}"
    );
}
