//! A subagent boundary with no content must not keep the expired commit timer
//! ready forever. Count polls of the real engine's adapter stream while quiet.

use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use async_trait::async_trait;
use futures::StreamExt;
use futures::stream::BoxStream;
use harness_adapters::{Harness, HarnessError, RunControls};
use harness_engine::{EngineCore, HarnessRegistry};
use harness_proto::{
    AgentEvent, DoneStatus, HarnessId, Model, ReasoningLevel, RunRequest, SandboxLevel,
    SteeringMode,
};
use tokio::sync::{Mutex, mpsc};

struct QuietHarness {
    feed: Mutex<Option<mpsc::UnboundedReceiver<AgentEvent>>>,
    polls: Arc<AtomicUsize>,
    received: Arc<AtomicUsize>,
}

#[async_trait]
impl Harness for QuietHarness {
    fn id(&self) -> HarnessId {
        HarnessId::Mock
    }

    fn display_name(&self) -> &str {
        "Quiet subagent"
    }

    fn supports_steering(&self) -> bool {
        false
    }

    fn steering_mode(&self) -> SteeringMode {
        SteeringMode::StepBoundary
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
        _controls: RunControls,
    ) -> Result<BoxStream<'static, Result<AgentEvent, HarnessError>>, HarnessError> {
        let mut feed = self.feed.lock().await.take().unwrap();
        let polls = self.polls.clone();
        let received = self.received.clone();
        Ok(futures::stream::poll_fn(move |cx| {
            polls.fetch_add(1, Ordering::Relaxed);
            feed.poll_recv(cx).map(|event| {
                event.map(|event| {
                    received.fetch_add(1, Ordering::Release);
                    Ok(event)
                })
            })
        })
        .boxed())
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn quiet_subagent_boundaries_do_not_spin_the_session_commit_timer() {
    let dir = tempfile::tempdir().unwrap();
    let (feed, rx) = mpsc::unbounded_channel();
    let polls = Arc::new(AtomicUsize::new(0));
    let received = Arc::new(AtomicUsize::new(0));
    let registry = Arc::new(HarnessRegistry::new());
    registry.register(Arc::new(QuietHarness {
        feed: Mutex::new(Some(rx)),
        polls: polls.clone(),
        received: received.clone(),
    }));
    let core = EngineCore::assemble(dir.path(), registry, HarnessId::Mock, None).unwrap();
    core.sessions
        .dispatch(
            "quiet-parent",
            HarnessId::Mock,
            RunRequest {
                prompt: "quiet subagent regression".into(),
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
            Some("quiet-user".into()),
        )
        .await
        .unwrap();

    let mut delivered = 0;
    for event in [
        AgentEvent::SessionStarted {
            harness: HarnessId::Mock,
            model: "mock".into(),
            tools: vec![],
            cwd: dir.path().display().to_string(),
            session_id: "quiet-child".into(),
            assistant_message_id: "child-assistant".into(),
        },
        AgentEvent::TextDelta {
            text: "child output".into(),
        },
        AgentEvent::Steered {
            assistant_message_id: None,
            next_assistant_message_id: None,
        },
    ] {
        feed.send(AgentEvent::Subagent {
            parent_tool_use_id: "quiet-spawn".into(),
            event: Box::new(event),
        })
        .unwrap();
        delivered += 1;
        tokio::time::timeout(Duration::from_secs(5), async {
            while received.load(Ordering::Acquire) < delivered {
                tokio::time::sleep(Duration::from_millis(1)).await;
            }
        })
        .await
        .expect("engine receives the child event");
        // Allow the 120 ms commit deadline and setup notifications to settle.
        tokio::time::sleep(Duration::from_millis(180)).await;
        println!("measuring quiet adapter stream after event {delivered}");
        let before = polls.load(Ordering::Relaxed);
        tokio::time::sleep(Duration::from_millis(150)).await;
        let quiet_polls = polls.load(Ordering::Relaxed) - before;
        println!("quiet adapter polls in 150 ms after event {delivered}: {quiet_polls}");
        assert!(
            quiet_polls <= 10,
            "quiet subagent kept the session loop runnable: {quiet_polls} adapter polls"
        );
    }

    // Nonempty output still reaches the child doc before the next boundary.
    let child = core
        .doc_host
        .open("quiet-parent--sub--quiet-spawn")
        .unwrap();
    assert!(!child.doc().read_entries().unwrap().is_empty());
    feed.send(AgentEvent::Done {
        status: DoneStatus::Completed,
        result: None,
        error: None,
        session_id: None,
    })
    .unwrap();
    core.shutdown().await;
}
