//! A fresh run whose first turn "completes" with no output and zero tokens has
//! not answered the user's prompt: Claude Code, resuming a session that still
//! has a background task with no completion record, runs its own synthetic
//! notification turn first and drops the prompt behind it. The engine re-sends
//! the prompt once into the live run (the user entry is idempotent by id, so
//! no second bubble), and ends with a visible reason if that comes back empty.
//!
//! The scripted stream is the one seen in a real run journal:
//! `sessionStarted`, `usage 0/0`, `done completed ""`.

use std::sync::{Arc, Mutex as StdMutex};
use std::time::Duration;

use async_trait::async_trait;
use futures::StreamExt;
use futures::stream::BoxStream;
use tokio::sync::{Mutex, mpsc};

use harness_adapters::{Harness, HarnessError, RunControls};
use harness_doc::{MessagePart, MessageRole, MessageStatus, SessionMessageEntry};
use harness_engine::{EngineCore, HarnessRegistry};
use harness_proto::{
    AgentEvent, DoneStatus, HarnessId, Model, ReasoningLevel, RunRequest, SandboxLevel,
    SessionStatus, SteeringMode,
};

const CHAT: &str = "chat-empty-turn";
const PROMPT: &str = "pull the app and benchmark it";

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

fn done(result: Option<&str>) -> AgentEvent {
    AgentEvent::Done {
        status: DoneStatus::Completed,
        result: result.map(str::to_owned),
        error: None,
        session_id: Some("hs-e".into()),
    }
}

fn session_started() -> AgentEvent {
    AgentEvent::SessionStarted {
        harness: HarnessId::Mock,
        model: "mock-1".into(),
        tools: vec![],
        cwd: "/tmp".into(),
        session_id: "hs-e".into(),
        assistant_message_id: "a-e".into(),
    }
}

fn usage(input_tokens: u64, output_tokens: u64) -> AgentEvent {
    AgentEvent::Usage {
        input_tokens,
        output_tokens,
    }
}

fn text(t: &str) -> AgentEvent {
    AgentEvent::TextDelta { text: t.into() }
}

/// The empty turn exactly as the journal recorded it.
fn empty_turn() -> Vec<AgentEvent> {
    vec![session_started(), usage(0, 0), done(Some(""))]
}

/// Feed-by-hand harness that records every steer the engine sends it and
/// confirms each with a `Steered` boundary, like the Claude adapter does.
struct FeedHarness {
    main_prompt: String,
    opt_in: bool,
    steers: Arc<StdMutex<Vec<String>>>,
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
    fn deterministic_turn_end(&self) -> bool {
        true
    }
    fn retries_empty_first_turn(&self) -> bool {
        self.opt_in
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
            // The auto-titler's side run: complete instantly with output.
            let events = vec![Ok(done(Some("title")))];
            return Ok(futures::stream::iter(events).boxed());
        }
        let mut feed = self
            .feed
            .lock()
            .await
            .take()
            .expect("FeedHarness serves the main dispatch once per test");
        let steers = self.steers.clone();
        let (tx, rx) = mpsc::channel::<Result<AgentEvent, HarnessError>>(64);
        tokio::spawn(async move {
            let mut steering_open = true;
            loop {
                tokio::select! {
                    biased;
                    steer = controls.steering.recv(), if steering_open => match steer {
                        Some(message) => {
                            steers.lock().unwrap().push(message.prompt);
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
    steers: Arc<StdMutex<Vec<String>>>,
    _dir: tempfile::TempDir,
}

fn assemble(main_prompt: &str, opt_in: bool) -> Rig {
    let (feed, rx) = mpsc::unbounded_channel();
    let steers = Arc::new(StdMutex::new(Vec::new()));
    let registry = HarnessRegistry::new();
    registry.register(Arc::new(FeedHarness {
        main_prompt: main_prompt.into(),
        opt_in,
        steers: steers.clone(),
        feed: Mutex::new(Some(rx)),
    }));
    let dir = tempfile::tempdir().unwrap();
    let core = EngineCore::assemble(dir.path(), Arc::new(registry), HarnessId::Mock, None)
        .expect("engine core assembles");
    Rig {
        core,
        feed,
        steers,
        _dir: dir,
    }
}

impl Rig {
    async fn send(&self, prompt: &str) {
        self.core
            .sessions
            .dispatch(CHAT, HarnessId::Mock, run_request(prompt), None)
            .await
            .expect("dispatch");
    }
    fn feed_all(&self, events: Vec<AgentEvent>) {
        for event in events {
            self.feed.send(event).unwrap();
        }
    }
    fn status(&self) -> Option<SessionStatus> {
        self.core.sessions.session_status(CHAT).map(|s| s.status)
    }
    fn steers(&self) -> Vec<String> {
        self.steers.lock().unwrap().clone()
    }
    fn entries(&self) -> Vec<SessionMessageEntry> {
        self.core
            .doc_host
            .open(CHAT)
            .ok()
            .and_then(|h| h.doc().read_entries().ok())
            .unwrap_or_default()
    }
    fn user_entries(&self) -> usize {
        self.entries()
            .iter()
            .filter(|e| e.role == MessageRole::User)
            .count()
    }
    fn assistant_text(&self) -> String {
        self.entries()
            .into_iter()
            .filter(|e| e.role == MessageRole::Assistant)
            .flat_map(|e| e.parts)
            .filter_map(|p| match p {
                MessagePart::Text { text, .. } => Some(text),
                _ => None,
            })
            .collect::<Vec<_>>()
            .join("")
    }
    fn errors(&self) -> Vec<String> {
        self.entries()
            .into_iter()
            .flat_map(|e| e.parts)
            .filter(|p| matches!(p, MessagePart::Error { .. }))
            .map(|p| format!("{p:?}"))
            .collect()
    }
    fn completions(&self) -> Option<String> {
        self.core
            .sessions
            .session_status(CHAT)
            .and_then(|s| s.last_completed_turn)
    }
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

/// A short pause for "and nothing else happens" assertions.
async fn settle() {
    tokio::time::sleep(Duration::from_millis(300)).await;
}

#[tokio::test]
async fn an_empty_first_turn_is_re_sent_once_and_the_answer_lands() {
    let rig = assemble(PROMPT, true);
    rig.send(PROMPT).await;

    rig.feed_all(empty_turn());
    wait_for(|| rig.steers().len() == 1, "the prompt is re-sent").await;
    assert_eq!(rig.steers(), vec![PROMPT.to_string()]);
    // The empty Done was swallowed: the chat never read "completed".
    assert_eq!(rig.status(), Some(SessionStatus::Working));
    assert_eq!(rig.completions(), None, "no completed turn was announced");

    // The re-sent prompt gets a real answer.
    rig.feed_all(vec![text("pong"), usage(10, 4), done(Some("pong"))]);
    wait_for(
        || rig.status() == Some(SessionStatus::Idle) && rig.assistant_text() == "pong",
        "the answer lands and the chat parks",
    )
    .await;

    assert_eq!(rig.steers().len(), 1, "one re-send, never more");
    assert_eq!(rig.user_entries(), 1, "the message is not drawn twice");
    assert!(rig.errors().is_empty(), "{:?}", rig.errors());
    assert!(
        rig.completions().is_some(),
        "the real answer completes the turn"
    );
    rig.core.sessions.shutdown().await;
}

#[tokio::test]
async fn a_second_empty_turn_ends_with_a_visible_reason_instead_of_looping() {
    let rig = assemble(PROMPT, true);
    rig.send(PROMPT).await;

    rig.feed_all(empty_turn());
    wait_for(|| rig.steers().len() == 1, "the prompt is re-sent").await;
    // The re-send comes back empty as well.
    rig.feed_all(vec![usage(0, 0), done(Some(""))]);
    wait_for(
        || rig.status() == Some(SessionStatus::Idle),
        "the turn ends after the second empty completion",
    )
    .await;
    settle().await;

    assert_eq!(rig.steers().len(), 1, "no second re-send");
    let errors = rig.errors();
    assert_eq!(errors.len(), 1, "{errors:?}");
    assert!(
        errors[0].contains("Feed returned no answer to this message"),
        "{errors:?}"
    );
    assert_eq!(rig.user_entries(), 1);
    rig.core.sessions.shutdown().await;
}

#[tokio::test]
async fn a_turn_with_output_is_never_re_sent() {
    let rig = assemble(PROMPT, true);
    rig.send(PROMPT).await;

    rig.feed_all(vec![
        session_started(),
        text("Working on it."),
        usage(8, 5),
        done(Some("Working on it.")),
    ]);
    wait_for(
        || rig.status() == Some(SessionStatus::Idle),
        "the turn parks",
    )
    .await;
    settle().await;

    assert!(rig.steers().is_empty());
    assert_eq!(rig.assistant_text(), "Working on it.");
    rig.core.sessions.shutdown().await;
}

#[tokio::test]
async fn a_turn_that_spent_tokens_is_never_re_sent() {
    // An empty result after real API work is the agent's answer (for example,
    // a turn that only ran tools), not a swallowed prompt.
    let rig = assemble(PROMPT, true);
    rig.send(PROMPT).await;

    rig.feed_all(vec![session_started(), usage(500, 20), done(Some(""))]);
    wait_for(
        || rig.status() == Some(SessionStatus::Idle),
        "the turn parks",
    )
    .await;
    settle().await;

    assert!(rig.steers().is_empty());
    rig.core.sessions.shutdown().await;
}

#[tokio::test]
async fn a_slash_command_is_never_re_sent() {
    // Commands can legitimately produce no model output.
    let rig = assemble("/compact", true);
    rig.send("/compact").await;

    rig.feed_all(empty_turn());
    wait_for(
        || rig.status() == Some(SessionStatus::Idle),
        "the turn parks",
    )
    .await;
    settle().await;

    assert!(rig.steers().is_empty());
    assert!(rig.errors().is_empty());
    rig.core.sessions.shutdown().await;
}

#[tokio::test]
async fn a_harness_that_does_not_opt_in_is_left_alone() {
    let rig = assemble(PROMPT, false);
    rig.send(PROMPT).await;

    rig.feed_all(empty_turn());
    wait_for(
        || rig.status() == Some(SessionStatus::Idle),
        "the turn parks",
    )
    .await;
    settle().await;

    assert!(rig.steers().is_empty());
    assert!(rig.errors().is_empty());
    assert_eq!(
        rig.entries()
            .iter()
            .filter(|e| e.status == Some(MessageStatus::Aborted))
            .count(),
        0
    );
    rig.core.sessions.shutdown().await;
}
