//! A GUI-owned checkout stays the selected ACP workspace when a saved graff
//! session is loaded. The fake server rejects the load if auto-isolation is on.

#![cfg(unix)]

use std::path::PathBuf;
use std::time::Duration;

use futures::StreamExt;
use harness_adapters::{AcpHarness, CancellationToken, Harness, RunControls};
use harness_proto::{AgentEvent, DoneStatus, RunRequest, SandboxLevel, WorktreeSpec};
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

async fn run_graff_worktree_fixture(
    cwd: &str,
    resume: Option<&str>,
    worktree: Option<&str>,
) -> Vec<AgentEvent> {
    let fixture =
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/fake-graff-worktree.py");
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
        cwd: cwd.to_owned(),
        sandbox: SandboxLevel::WorkspaceWrite,
        auto_approve: true,
        attachments: Vec::new(),
        worktree: worktree.map(|name| WorktreeSpec {
            repo_path: cwd.to_owned(),
            base: "main".into(),
            space_id: None,
            agent_name: Some(name.to_owned()),
        }),
        resume: resume.map(str::to_owned),
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
    events.into_iter().map(Result::unwrap).collect()
}

fn started_in(events: &[AgentEvent]) -> (String, PathBuf) {
    events
        .iter()
        .find_map(|event| match event {
            AgentEvent::SessionStarted { session_id, cwd, .. } => {
                Some((session_id.clone(), std::fs::canonicalize(cwd).unwrap()))
            }
            _ => None,
        })
        .unwrap_or_else(|| panic!("no SessionStarted: {events:?}"))
}

/// A Graff-owned worktree (`WorktreeSpec::agent_name`): the adapter launches
/// `graff acp -w <name>` from the repo, reports the tree Graff ran the
/// session in, and resumes there — from the repo with the spec, or from the
/// tree itself on later runs.
#[tokio::test]
async fn graff_runs_and_resumes_in_its_own_named_worktree() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().to_str().unwrap().to_owned();
    let tree = std::fs::canonicalize(dir.path())
        .unwrap()
        .join(".graff/worktrees/harness-chat1");

    let first = run_graff_worktree_fixture(&root, None, Some("harness-chat1")).await;
    assert_eq!(started_in(&first), ("fresh".to_owned(), tree.clone()), "{first:?}");

    let respawned = run_graff_worktree_fixture(&root, Some("saved"), Some("harness-chat1")).await;
    assert_eq!(started_in(&respawned), ("saved".to_owned(), tree.clone()), "{respawned:?}");

    let inside = run_graff_worktree_fixture(tree.to_str().unwrap(), Some("saved"), None).await;
    assert_eq!(started_in(&inside), ("saved".to_owned(), tree.clone()), "{inside:?}");

    for events in [&first, &respawned, &inside] {
        assert!(
            !events.iter().any(|event| matches!(event, AgentEvent::Error { .. })),
            "no lost-context fallback: {events:?}"
        );
        assert!(
            events.iter().any(|event| matches!(event, AgentEvent::Done { status: DoneStatus::Completed, .. })),
            "{events:?}"
        );
    }
}
