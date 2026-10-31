//! The queue state is explicit, live-only, run-scoped, and independent of
//! session liveness. All data and harness events here are synthetic.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use futures::{StreamExt, stream::BoxStream};
use harness_adapters::{Harness, HarnessError, RunControls};
use harness_engine::{EngineCore, HarnessRegistry};
use harness_proto::{
    AgentEvent, DoneStatus, HarnessId, Model, ReasoningLevel, RunRequest, SandboxLevel,
    SteeringMode, ToolProgressItem,
};
use tokio::sync::{mpsc, watch};

#[derive(Debug)]
struct Started {
    chat: String,
    directory: PathBuf,
    events: mpsc::UnboundedSender<Result<AgentEvent, HarnessError>>,
}

struct WaitingHarness {
    started: mpsc::UnboundedSender<Started>,
}

#[async_trait]
impl Harness for WaitingHarness {
    fn id(&self) -> HarnessId {
        HarnessId::Mock
    }
    fn display_name(&self) -> &str {
        "Queue fixture"
    }
    fn supports_steering(&self) -> bool {
        false
    }
    fn steering_mode(&self) -> SteeringMode {
        SteeringMode::TurnBoundary
    }
    fn reasoning_levels(&self) -> &[ReasoningLevel] {
        &[ReasoningLevel::Medium]
    }
    async fn models(&self) -> Result<Vec<Model>, HarnessError> {
        Ok(Vec::new())
    }
    async fn run(
        &self,
        request: RunRequest,
        controls: RunControls,
    ) -> Result<BoxStream<'static, Result<AgentEvent, HarnessError>>, HarnessError> {
        let origin = controls.origin.expect("a chat run has an origin");
        let directory = origin
            .build_wait_dir
            .expect("the engine must supply a private queue-signal directory");
        if request.prompt == "wait" {
            std::fs::write(
                directory.join(std::process::id().to_string()),
                chrono::Utc::now().timestamp().to_string(),
            )?;
        }
        let (events, rx) = mpsc::unbounded_channel();
        events
            .send(Ok(AgentEvent::SessionStarted {
                harness: HarnessId::Mock,
                model: "fixture".into(),
                tools: Vec::new(),
                cwd: request.cwd,
                session_id: format!("fixture-{}", origin.chat_id),
                assistant_message_id: format!("assistant-{}", origin.chat_id),
            }))
            .unwrap();
        self.started
            .send(Started {
                chat: origin.chat_id,
                directory,
                events: events.clone(),
            })
            .unwrap();
        tokio::spawn(async move {
            controls.interrupt.cancelled().await;
            let _ = events.send(Ok(AgentEvent::Done {
                status: DoneStatus::Interrupted,
                result: None,
                error: None,
                session_id: None,
            }));
        });
        Ok(futures::stream::unfold(rx, |mut rx| async move {
            rx.recv().await.map(|event| (event, rx))
        })
        .boxed())
    }
}

fn request(cwd: &std::path::Path, prompt: &str) -> RunRequest {
    RunRequest {
        turn_origin: Default::default(),
        prompt: prompt.into(),
        harness: None,
        model: None,
        reasoning: None,
        model_options: Default::default(),
        cwd: cwd.to_string_lossy().into_owned(),
        sandbox: SandboxLevel::WorkspaceWrite,
        auto_approve: true,
        attachments: Vec::new(),
        resume: None,
        worktree: None,
    }
}

async fn wait_state(rx: &mut watch::Receiver<Vec<ToolProgressItem>>, waiting: bool) {
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            if harness_proto::build_wait::build_wait_since(&rx.borrow()).is_some() == waiting {
                return;
            }
            rx.changed()
                .await
                .expect("queue progress channel stays live");
        }
    })
    .await
    .expect("queue state must follow the explicit signal promptly");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn build_wait_tracks_acquisition_cancellation_and_chat_isolation() {
    let directory = tempfile::tempdir().unwrap();
    let (started, mut starts) = mpsc::unbounded_channel();
    let registry = HarnessRegistry::new();
    registry.register(Arc::new(WaitingHarness { started }));
    let core = EngineCore::assemble(
        &directory.path().join("engine"),
        Arc::new(registry),
        HarnessId::Mock,
        None,
    )
    .unwrap();
    for id in ["waiting-chat", "running-chat"] {
        core.workspace
            .create_chat(id, None, Some(&core.device_id), None, None)
            .unwrap();
        core.workspace
            .rename_chat(id, "Synthetic queue test")
            .unwrap();
    }
    let mut waiting = core.sessions.watch_tool_progress("waiting-chat");
    let running = core.sessions.watch_tool_progress("running-chat");
    core.sessions
        .dispatch(
            "waiting-chat",
            HarnessId::Mock,
            request(directory.path(), "wait"),
            None,
        )
        .await
        .unwrap();
    let first = tokio::time::timeout(Duration::from_secs(5), starts.recv())
        .await
        .unwrap()
        .unwrap();
    assert_eq!(first.chat, "waiting-chat");
    wait_state(&mut waiting, true).await;
    core.sessions
        .dispatch(
            "running-chat",
            HarnessId::Mock,
            request(directory.path(), "run"),
            None,
        )
        .await
        .unwrap();
    let second = tokio::time::timeout(Duration::from_secs(5), starts.recv())
        .await
        .unwrap()
        .unwrap();
    assert_ne!(first.directory, second.directory);
    assert!(harness_proto::build_wait::build_wait_since(&running.borrow()).is_none());

    // A queued background command must not hide genuine concurrent model work.
    first
        .events
        .send(Ok(AgentEvent::ReasoningDelta {
            text: "Checking another synthetic fixture while the build is queued.".into(),
        }))
        .unwrap();
    wait_state(&mut waiting, false).await;
    tokio::time::sleep(Duration::from_millis(700)).await;
    assert!(harness_proto::build_wait::build_wait_since(&waiting.borrow()).is_none());
    // A tool boundary ends that model request; the outstanding explicit wait
    // can own the status again, without an inactivity/CPU heuristic.
    first
        .events
        .send(Ok(AgentEvent::ToolCall {
            id: "queued-command".into(),
            call: harness_proto::ToolCall::Exec {
                command: "synthetic queued build".into(),
            },
        }))
        .unwrap();
    wait_state(&mut waiting, true).await;

    let marker = first.directory.join(std::process::id().to_string());
    std::fs::remove_file(&marker).unwrap();
    wait_state(&mut waiting, false).await;
    std::fs::write(&marker, chrono::Utc::now().timestamp().to_string()).unwrap();
    wait_state(&mut waiting, true).await;
    core.sessions.interrupt("waiting-chat").await.unwrap();
    wait_state(&mut waiting, false).await;

    second
        .events
        .send(Ok(AgentEvent::Done {
            status: DoneStatus::Completed,
            result: None,
            error: None,
            session_id: None,
        }))
        .unwrap();
    core.shutdown().await;
    assert!(harness_proto::build_wait::build_wait_since(&running.borrow()).is_none());
    let (replay, _) = core.sessions.subscribe("waiting-chat", 0).unwrap();
    assert!(
        !replay
            .iter()
            .any(|event| matches!(event.event, AgentEvent::ToolProgress { .. })),
        "queue metadata must not enter durable history"
    );
}
