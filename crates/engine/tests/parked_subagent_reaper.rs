//! The idle reaper ends a parked persistent session nobody came back to. A
//! background subagent can outlive the turn that spawned it, so a parked
//! session with a subagent still running must not be reaped, and its idle
//! window starts over from the subagent's last activity.

use std::sync::Arc;
use std::time::{Duration, Instant};

use async_trait::async_trait;
use futures::StreamExt;
use futures::stream::BoxStream;
use harness_adapters::{Harness, HarnessError, RunControls};
use harness_doc::{MessagePart, SubagentStatus};
use harness_engine::{EngineCore, HarnessRegistry};
use harness_proto::{
    AgentEvent, DoneStatus, HarnessId, Model, ReasoningLevel, RunRequest, SandboxLevel,
    SteeringMode, ToolCall,
};
use tokio::sync::{Mutex, mpsc};
use tokio_util::sync::CancellationToken;

/// Shortened reaper window (production: 30 minutes).
const IDLE: Duration = Duration::from_millis(800);
const SPAWN: &str = "spawn-bg";

/// A steerable harness that parks after each Done and streams whatever the
/// test feeds it. Records the run's interrupt token: the reaper cancels it to
/// stop the agent process.
struct ParkingHarness {
    feed: Mutex<Option<mpsc::UnboundedReceiver<AgentEvent>>>,
    interrupt: Arc<std::sync::Mutex<Option<CancellationToken>>>,
}

#[async_trait]
impl Harness for ParkingHarness {
    fn id(&self) -> HarnessId {
        HarnessId::Mock
    }

    fn display_name(&self) -> &str {
        "Parking harness"
    }

    fn supports_steering(&self) -> bool {
        true
    }

    fn steering_mode(&self) -> SteeringMode {
        SteeringMode::StepBoundary
    }

    // Every turn ends with a wire Done; keep the quiesce watchdog out of it.
    fn deterministic_turn_end(&self) -> bool {
        true
    }

    fn reasoning_levels(&self) -> &[ReasoningLevel] {
        &[]
    }

    async fn models(&self) -> Result<Vec<Model>, HarnessError> {
        Ok(vec![])
    }

    async fn run(
        &self,
        _request: RunRequest,
        controls: RunControls,
    ) -> Result<BoxStream<'static, Result<AgentEvent, HarnessError>>, HarnessError> {
        *self.interrupt.lock().unwrap() = Some(controls.interrupt.clone());
        let mut feed = self.feed.lock().await.take().unwrap();
        // Hold the controls (steering mailbox) open for the whole run.
        Ok(futures::stream::poll_fn(move |cx| {
            let _ = &controls;
            feed.poll_recv(cx).map(|event| event.map(Ok))
        })
        .boxed())
    }
}

struct Run {
    core: EngineCore,
    feed: mpsc::UnboundedSender<AgentEvent>,
    interrupt: Arc<std::sync::Mutex<Option<CancellationToken>>>,
    chat: &'static str,
    _dir: tempfile::TempDir,
}

impl Run {
    async fn start(chat: &'static str) -> Self {
        // SAFETY: every test in this binary sets the same value before any
        // session starts; nothing reads it concurrently with a different one.
        unsafe { std::env::set_var("HARNESS_SESSION_IDLE_MS", IDLE.as_millis().to_string()) };
        let dir = tempfile::tempdir().unwrap();
        let (feed, rx) = mpsc::unbounded_channel();
        let interrupt = Arc::new(std::sync::Mutex::new(None));
        let registry = Arc::new(HarnessRegistry::new());
        registry.register(Arc::new(ParkingHarness {
            feed: Mutex::new(Some(rx)),
            interrupt: interrupt.clone(),
        }));
        let core = EngineCore::assemble(dir.path(), registry, HarnessId::Mock, None).unwrap();
        core.sessions
            .dispatch(
                chat,
                HarnessId::Mock,
                RunRequest {
                    prompt: "spawn a background subagent".into(),
                    harness: None,
                    model: None,
                    reasoning: None,
                    model_options: Default::default(),
                    cwd: dir.path().display().to_string(),
                    sandbox: SandboxLevel::ReadOnly,
                    auto_approve: true,
                    attachments: vec![],
                    worktree: None,
                    resume: None,
                },
                Some(format!("{chat}-user")),
            )
            .await
            .unwrap();
        Self {
            core,
            feed,
            interrupt,
            chat,
            _dir: dir,
        }
    }

    fn send(&self, event: AgentEvent) {
        self.feed.send(event).unwrap();
    }

    fn sub(&self, event: AgentEvent) {
        self.send(AgentEvent::Subagent {
            parent_tool_use_id: SPAWN.into(),
            event: Box::new(event),
        });
    }

    fn reaped(&self) -> bool {
        self.interrupt
            .lock()
            .unwrap()
            .as_ref()
            .is_some_and(CancellationToken::is_cancelled)
    }

    async fn wait_reaped(&self, within: Duration) -> bool {
        let deadline = Instant::now() + within;
        while Instant::now() < deadline {
            if self.reaped() {
                return true;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        self.reaped()
    }

    fn chip_status(&self) -> Option<SubagentStatus> {
        let doc = self.core.doc_host.open(self.chat).unwrap();
        doc.doc()
            .read_entries()
            .unwrap_or_default()
            .iter()
            .flat_map(|entry| &entry.parts)
            .find_map(|part| match part {
                MessagePart::Tool {
                    id,
                    subagent_status,
                    ..
                } if id == SPAWN => *subagent_status,
                _ => None,
            })
    }
}

fn text(text: &str) -> AgentEvent {
    AgentEvent::TextDelta { text: text.into() }
}

fn done() -> AgentEvent {
    AgentEvent::Done {
        status: DoneStatus::Completed,
        result: None,
        error: None,
        session_id: None,
    }
}

fn spawn_call() -> AgentEvent {
    AgentEvent::ToolCall {
        id: SPAWN.into(),
        call: ToolCall::Unknown {
            name: "Agent".into(),
            input: None,
        },
    }
}

fn spawn_result() -> AgentEvent {
    AgentEvent::ToolResult {
        id: SPAWN.into(),
        is_error: false,
        output: None,
        diff: None,
    }
}

fn started(run: &Run) -> AgentEvent {
    AgentEvent::SessionStarted {
        harness: HarnessId::Mock,
        model: "mock".into(),
        tools: vec![],
        cwd: run._dir.path().display().to_string(),
        session_id: format!("{}-session", run.chat),
        assistant_message_id: "assistant".into(),
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn parked_session_is_not_reaped_under_a_running_background_subagent() {
    let run = Run::start("bg-parent").await;
    // The spawn returns at once (background), the child starts streaming,
    // and the parent's turn completes: the session parks.
    run.send(started(&run));
    run.send(spawn_call());
    run.send(spawn_result());
    run.sub(text("child starting"));
    run.send(done());

    // The child keeps working for three idle windows after the park.
    let parked = Instant::now();
    while parked.elapsed() < IDLE * 3 {
        tokio::time::sleep(IDLE / 4).await;
        assert!(
            !run.reaped(),
            "reaped {:?} after the park with the subagent still running",
            parked.elapsed()
        );
        run.sub(text("child still working"));
    }

    // The child settles. The idle window runs from that last activity, not
    // from the park (long past), so the session is not reaped right away...
    run.sub(done());
    assert!(
        !run.wait_reaped(IDLE / 2).await,
        "reaped as soon as the subagent settled; the window must restart from its activity"
    );
    // ...but it still is, one window later.
    assert!(
        run.wait_reaped(IDLE * 3).await,
        "a parked session with every subagent settled was never reaped"
    );
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert_eq!(run.chip_status(), Some(SubagentStatus::Done));
    run.core.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn subagent_that_ended_with_its_spawn_does_not_hold_off_the_reaper() {
    let run = Run::start("fg-parent").await;
    // A foreground spawn: the child streams, then the spawn call returns. No
    // tagged Done ever follows (not every driver sends one for these).
    run.send(started(&run));
    run.send(spawn_call());
    run.sub(text("child working"));
    run.send(spawn_result());
    run.send(done());

    assert!(
        run.wait_reaped(IDLE * 4).await,
        "a finished foreground subagent kept the parked session alive"
    );
    run.core.shutdown().await;
}
