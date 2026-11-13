//! A send the running turn cannot take through its mailbox (a changed model,
//! images) used to replace the runtime at once: the agent saw a bare cancel
//! mid-answer, and its reply ended "interrupted by user" with no Stop pressed.
//! Such a send now waits in the queue and starts when the turn ends.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use futures::StreamExt;
use futures::stream::BoxStream;

use harness_adapters::{Harness, HarnessError, RunControls};
use harness_doc::{SessionCommandEntry, SessionCommandPayload, SessionCommandStatus};
use harness_engine::{EngineCore, HarnessRegistry};
use harness_proto::{
    AgentEvent, DoneStatus, HarnessId, Model, ReasoningLevel, RunRequest, SandboxLevel,
    SessionStatus, SteeringMode,
};

const CHAT: &str = "chat-mid-turn-reconfigure";

/// A turn that ends when the test says so, and records whether it was cut off.
struct HeldHarness {
    finish: tokio::sync::broadcast::Sender<()>,
    requests: Mutex<Vec<RunRequest>>,
    interrupted: Arc<AtomicBool>,
}

#[async_trait]
impl Harness for HeldHarness {
    fn id(&self) -> HarnessId {
        HarnessId::Mock
    }
    fn display_name(&self) -> &str {
        "Held"
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
        request: RunRequest,
        controls: RunControls,
    ) -> Result<BoxStream<'static, Result<AgentEvent, HarnessError>>, HarnessError> {
        self.requests.lock().unwrap().push(request.clone());
        let mut finish = self.finish.subscribe();
        let interrupt = controls.interrupt.clone();
        let interrupted = self.interrupted.clone();
        let mut steering = controls.steering;
        let started = futures::stream::iter(vec![Ok(AgentEvent::SessionStarted {
            harness: HarnessId::Mock,
            model: request.model.clone().unwrap_or_else(|| "mock-1".into()),
            tools: vec![],
            cwd: request.cwd.clone(),
            session_id: "sess-reconfigure".into(),
            assistant_message_id: format!("a-{}", request.prompt),
        })]);
        let done = futures::stream::once(async move {
            let status = loop {
                tokio::select! {
                    _ = interrupt.cancelled() => {
                        interrupted.store(true, Ordering::SeqCst);
                        break DoneStatus::Interrupted;
                    }
                    _ = finish.recv() => break DoneStatus::Completed,
                    steer = steering.recv() => if steer.is_none() {
                        break DoneStatus::Completed;
                    },
                }
            };
            Ok(AgentEvent::Done {
                status,
                result: None,
                error: None,
                session_id: Some("sess-reconfigure".into()),
            })
        });
        Ok(started.chain(done).boxed())
    }
}

async fn wait_for(mut predicate: impl FnMut() -> bool, what: &str) {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    while !predicate() {
        assert!(
            tokio::time::Instant::now() < deadline,
            "timed out waiting for {what}"
        );
        tokio::time::sleep(Duration::from_millis(15)).await;
    }
}

fn run(core: &EngineCore, id: &str, prompt: &str, model: Option<&str>, cwd: &str) {
    core.doc_host
        .open(CHAT)
        .unwrap()
        .doc()
        .queue_command(&SessionCommandEntry {
            id: format!("cmd-{id}"),
            payload: SessionCommandPayload::Run {
                message_id: id.into(),
                request: RunRequest {
                    turn_origin: Default::default(),
                    prompt: prompt.into(),
                    harness: Some(HarnessId::Mock),
                    model: model.map(str::to_string),
                    reasoning: None,
                    model_options: Default::default(),
                    cwd: cwd.into(),
                    sandbox: SandboxLevel::WorkspaceWrite,
                    auto_approve: true,
                    attachments: Vec::new(),
                    worktree: None,
                    resume: None,
                },
            },
            issued_by: "viewer".into(),
            issued_at: chrono::Utc::now().timestamp_millis(),
            based_on: None,
            expires_at: None,
            status: SessionCommandStatus::Pending,
            resolution: None,
        })
        .unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_send_with_a_new_model_waits_for_the_running_turn() {
    let path = tempfile::tempdir().unwrap().keep();
    let cwd = path.join("work");
    std::fs::create_dir_all(&cwd).unwrap();
    let cwd = cwd.display().to_string();
    let (finish, _) = tokio::sync::broadcast::channel(16);
    let harness = Arc::new(HeldHarness {
        finish,
        requests: Mutex::new(Vec::new()),
        interrupted: Arc::new(AtomicBool::new(false)),
    });
    let registry = HarnessRegistry::new();
    registry.register(harness.clone());
    let core = EngineCore::assemble(
        &path.join("data"),
        Arc::new(registry),
        HarnessId::Mock,
        None,
    )
    .expect("engine core assembles");
    let client = harness_rpc::memory_client(core.rpc_service());
    client
        .call(
            harness_rpc::methods::MUTATE,
            serde_json::json!({"op": "createChat", "chatId": CHAT, "deviceId": core.device_id, "cwd": cwd}),
        )
        .await
        .expect("createChat");
    core.workspace
        .rename_chat(CHAT, "Pre-titled")
        .expect("rename chat");

    run(&core, "first", "first", Some("mock-1"), &cwd);
    wait_for(
        || harness.requests.lock().unwrap().len() == 1,
        "the first turn to start",
    )
    .await;
    wait_for(
        || core.sessions.turn_in_flight(CHAT),
        "the first turn to be working",
    )
    .await;

    // Mid-turn, a send that picked another model.
    run(&core, "second", "second", Some("mock-2"), &cwd);
    let queued = || {
        core.doc_host
            .open(CHAT)
            .unwrap()
            .doc()
            .read_queue()
            .unwrap_or_default()
            .into_iter()
            .map(|item| item.text)
            .collect::<Vec<_>>()
    };
    wait_for(|| queued() == ["second"], "the second send to be held").await;
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert!(
        !harness.interrupted.load(Ordering::SeqCst),
        "the running turn was cancelled"
    );
    assert_eq!(harness.requests.lock().unwrap().len(), 1);
    assert_eq!(
        core.sessions.session_status(CHAT).unwrap().status,
        SessionStatus::Working
    );

    // The turn ends on its own; the held send starts with its own model.
    let _ = harness.finish.send(());
    wait_for(
        || harness.requests.lock().unwrap().len() == 2,
        "the held send to start",
    )
    .await;
    assert!(!harness.interrupted.load(Ordering::SeqCst));
    let second = harness.requests.lock().unwrap()[1].clone();
    assert_eq!(second.prompt, "second");
    assert_eq!(second.model.as_deref(), Some("mock-2"));
    wait_for(|| queued().is_empty(), "the queue to empty").await;

    let _ = harness.finish.send(());
    core.shutdown().await;
}
