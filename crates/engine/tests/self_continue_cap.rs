//! A chain of self-continued turns is capped (#341). An agent that keeps
//! streaming without ever ending its turn used to park at the quiesce
//! watchdog, resume on its next delta and park again forever, each cycle a
//! new segment and more journal rows. Past `HARNESS_SELF_RESUME_MAX` resumes
//! the session stays parked until a real turn boundary resets the chain.
//!
//! A separate file because the env knobs are process-global.

use std::sync::{Arc, Once};
use std::time::Duration;

use async_trait::async_trait;
use futures::StreamExt;
use futures::stream::BoxStream;
use tokio::sync::{Mutex, mpsc};

use harness_adapters::{Harness, HarnessError, RunControls};
use harness_engine::{EngineCore, HarnessRegistry};
use harness_proto::{
    AgentEvent, DoneStatus, HarnessId, Model, ReasoningLevel, RunRequest, SandboxLevel,
    SessionStatus, SteeringMode,
};

const CHAT: &str = "chat-self-cap";
/// Normal window: far beyond the test horizon.
const QUIESCE_MS: u64 = 600_000;
const SELF_QUIESCE_MS: u64 = 300;
/// Resumes allowed per self-continued chain under test.
const SELF_RESUME_MAX: u32 = 2;

fn init_env() {
    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        // SAFETY: called before any engine (and thus any reader of the vars)
        // exists in this test process.
        unsafe {
            std::env::set_var("HARNESS_TURN_QUIESCE_MS", QUIESCE_MS.to_string());
            std::env::set_var("HARNESS_SELF_TURN_QUIESCE_MS", SELF_QUIESCE_MS.to_string());
            std::env::set_var("HARNESS_SELF_RESUME_MAX", SELF_RESUME_MAX.to_string());
        }
    });
}

fn run_request(prompt: &str) -> RunRequest {
    RunRequest {
        prompt: prompt.into(),
        harness: None,
        model: None,
        reasoning: None,
        model_options: Default::default(),
        cwd: "/tmp".into(),
        sandbox: SandboxLevel::WorkspaceWrite,
        auto_approve: true,
        attachments: Vec::new(),
        worktree: None,
        resume: None,
    }
}

fn done(status: DoneStatus) -> AgentEvent {
    AgentEvent::Done {
        status,
        result: None,
        error: None,
        session_id: Some("hs-cap".into()),
    }
}

fn session_started() -> AgentEvent {
    AgentEvent::SessionStarted {
        harness: HarnessId::Mock,
        model: "mock-1".into(),
        tools: vec![],
        cwd: "/tmp".into(),
        session_id: "hs-cap".into(),
        assistant_message_id: "a-cap".into(),
    }
}

fn text(t: &str) -> AgentEvent {
    AgentEvent::TextDelta { text: t.into() }
}

/// Feed-by-hand harness (see `turn_quiesce.rs`): the test pushes events
/// through a channel; accepted steers confirm with a `Steered` boundary.
struct FeedHarness {
    main_prompt: String,
    feed: Mutex<Option<mpsc::UnboundedReceiver<AgentEvent>>>,
}

#[async_trait]
impl Harness for FeedHarness {
    fn id(&self) -> HarnessId {
        HarnessId::Mock
    }
    fn display_name(&self) -> &str {
        "Feed"
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
        mut controls: RunControls,
    ) -> Result<BoxStream<'static, Result<AgentEvent, HarnessError>>, HarnessError> {
        if request.prompt != self.main_prompt {
            let events = vec![Ok(done(DoneStatus::Completed))];
            return Ok(futures::stream::iter(events).boxed());
        }
        let mut feed = self
            .feed
            .lock()
            .await
            .take()
            .expect("FeedHarness serves the main dispatch once per test");
        let (tx, rx) = mpsc::channel::<Result<AgentEvent, HarnessError>>(64);
        tokio::spawn(async move {
            let mut steering_open = true;
            loop {
                tokio::select! {
                    biased;
                    steer = controls.steering.recv(), if steering_open => match steer {
                        Some(_) => {
                            let boundary = AgentEvent::Steered {
                                assistant_message_id: None,
                                next_assistant_message_id: None,
                            };
                            if tx.send(Ok(boundary)).await.is_err() {
                                return;
                            }
                        }
                        None => steering_open = false,
                    },
                    event = feed.recv() => match event {
                        Some(event) => {
                            if tx.send(Ok(event)).await.is_err() {
                                return;
                            }
                        }
                        None => return,
                    },
                }
            }
        });
        Ok(futures::stream::unfold(rx, |mut rx| async move {
            rx.recv().await.map(|event| (event, rx))
        })
        .boxed())
    }
}

struct Rig {
    core: EngineCore,
    feed: mpsc::UnboundedSender<AgentEvent>,
    _dir: tempfile::TempDir,
}

fn assemble(main_prompt: &str) -> Rig {
    init_env();
    let (feed, rx) = mpsc::unbounded_channel();
    let registry = HarnessRegistry::new();
    registry.register(Arc::new(FeedHarness {
        main_prompt: main_prompt.into(),
        feed: Mutex::new(Some(rx)),
    }));
    let dir = tempfile::tempdir().unwrap();
    let core = EngineCore::assemble(dir.path(), Arc::new(registry), HarnessId::Mock, None)
        .expect("engine core assembles");
    Rig {
        core,
        feed,
        _dir: dir,
    }
}

fn status(core: &EngineCore) -> Option<SessionStatus> {
    core.sessions.session_status(CHAT).map(|s| s.status)
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
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
}

/// Self-continued output past the resume gate: Working, then the short
/// window parks it again. False when the output did not resume the session.
async fn self_continue(rig: &Rig, line: &str) -> bool {
    tokio::time::sleep(Duration::from_millis(1200)).await;
    rig.feed.send(text(line)).unwrap();
    let deadline = tokio::time::Instant::now() + Duration::from_millis(250);
    while tokio::time::Instant::now() < deadline {
        if status(&rig.core) == Some(SessionStatus::Working) {
            wait_for(
                || status(&rig.core) == Some(SessionStatus::Idle),
                "short quiesce parks the self-continued turn",
            )
            .await;
            return true;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    false
}

#[tokio::test]
async fn a_self_continued_chain_stops_resuming_at_its_cap_until_the_next_turn() {
    let rig = assemble("watch the builds");
    rig.core
        .sessions
        .dispatch(CHAT, HarnessId::Mock, run_request("watch the builds"), None)
        .await
        .expect("dispatch");
    rig.feed.send(session_started()).unwrap();
    rig.feed.send(text("Watching.")).unwrap();
    rig.feed.send(done(DoneStatus::Completed)).unwrap();
    wait_for(
        || status(&rig.core) == Some(SessionStatus::Idle),
        "park after Done",
    )
    .await;

    for round in 0..SELF_RESUME_MAX {
        assert!(
            self_continue(&rig, &format!("Build {round} finished.")).await,
            "resume {round} is within the cap"
        );
    }
    assert!(
        !self_continue(&rig, "Still going, with no turn end.").await,
        "past the cap the session stays parked"
    );
    assert_eq!(status(&rig.core), Some(SessionStatus::Idle));

    // A real turn end closes the chain; the next wake resumes again.
    rig.feed.send(done(DoneStatus::Completed)).unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert!(
        self_continue(&rig, "A new build finished.").await,
        "a turn boundary resets the chain"
    );

    rig.core.sessions.shutdown().await;
}
