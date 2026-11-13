#![cfg(target_os = "macos")]

use std::{os::unix::fs::PermissionsExt, time::Duration};

use futures::StreamExt;
use harness_adapters::{AcpHarness, CancellationToken, Harness, RunControls};
use harness_proto::{AgentEvent, DoneStatus, ReasoningLevel, RunRequest, SandboxLevel};
use serde_json::Value;
use tokio::sync::{mpsc, oneshot};

async fn exercise(mode: &str) -> (Vec<AgentEvent>, Vec<Value>) {
    let root = tempfile::tempdir().unwrap();
    let exe = root.path().join("graff");
    std::fs::write(&exe, include_str!("fixtures/graff-connections.py")).unwrap();
    std::fs::set_permissions(&exe, std::fs::Permissions::from_mode(0o755)).unwrap();
    std::fs::write(root.path().join("mode"), mode).unwrap();
    let (_, steering) = mpsc::channel(8);
    let controls = RunControls {
        origin: None,
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
        turn_origin: Default::default(),
        prompt: "hello".into(),
        harness: None,
        model: Some("p1/shared".into()),
        reasoning: Some(ReasoningLevel::High),
        model_options: Default::default(),
        cwd: root.path().display().to_string(),
        sandbox: SandboxLevel::WorkspaceWrite,
        auto_approve: true,
        attachments: Vec::new(),
        worktree: None,
        resume: Some("fixture".into()),
    };
    let stream = AcpHarness::graff()
        .with_executable(exe)
        .run(request, controls)
        .await
        .unwrap();
    let events = tokio::time::timeout(
        Duration::from_secs(10),
        stream.map(Result::unwrap).collect(),
    )
    .await
    .unwrap();
    let wire = std::fs::read_to_string(root.path().join("wire.jsonl"))
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    (events, wire)
}

fn user_prompts(wire: &[Value]) -> Vec<usize> {
    wire.iter()
        .enumerate()
        .filter_map(|(ix, entry)| {
            (entry["method"] == "session/prompt" && entry["params"]["prompt"][0]["text"] == "hello")
                .then_some(ix)
        })
        .collect()
}

#[tokio::test]
async fn resumed_connection_switch_is_verified_before_user_text_and_refreshes_effort() {
    for mode in ["supported", "late-command"] {
        let (events, wire) = exercise(mode).await;
        assert!(
            events.iter().any(|event| matches!(
                event,
                AgentEvent::Done {
                    status: DoneStatus::Completed,
                    ..
                }
            )),
            "{mode}: {events:?}"
        );
        let user = user_prompts(&wire);
        assert_eq!(user.len(), 1, "{mode}: {wire:?}");
        let switch = wire
            .iter()
            .position(|entry| entry["params"]["prompt"][0]["text"] == "/model p1 shared")
            .unwrap();
        let catalogs: Vec<_> = wire
            .iter()
            .enumerate()
            .filter_map(|(ix, entry)| (entry["method"] == "graff/models").then_some(ix))
            .collect();
        assert_eq!(catalogs.len(), 2);
        assert!(catalogs[0] < switch && switch < catalogs[1] && catalogs[1] < user[0]);
        assert!(
            wire[catalogs[1] + 1..user[0]]
                .iter()
                .any(|entry| entry["method"] == "session/set_config_option"
                    && entry["params"]["value"] == "high")
        );
    }
}

#[tokio::test]
async fn unsafe_or_unconfirmed_connection_switch_never_sends_user_text() {
    for mode in [
        "unsupported",
        "foreign-command",
        "revoked-command",
        "signed-out",
        "current-signed-out",
        "auth-lost",
        "missing-model",
        "rejected",
        "ignored",
        "missing-current",
        "cancelled",
    ] {
        let (events, wire) = exercise(mode).await;
        assert!(
            events.iter().any(|event| matches!(
                event,
                AgentEvent::Done {
                    status: DoneStatus::Errored,
                    ..
                }
            )),
            "{mode}: {events:?}"
        );
        assert!(user_prompts(&wire).is_empty(), "{mode}: {wire:?}");
        if [
            "unsupported",
            "foreign-command",
            "revoked-command",
            "signed-out",
            "current-signed-out",
            "missing-model",
        ]
        .contains(&mode)
        {
            assert!(
                !wire.iter().any(|entry| entry["method"] == "session/prompt"),
                "{mode}: {wire:?}"
            );
        }
    }
}

#[tokio::test]
async fn already_selected_connection_does_not_run_a_switch_command() {
    let (events, wire) = exercise("already-selected").await;
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
    assert_eq!(user_prompts(&wire).len(), 1);
    assert_eq!(
        wire.iter()
            .filter(|entry| entry["method"] == "session/prompt")
            .count(),
        1
    );
}
