//! Work a restart (quit, update, crash) cut short picks itself back up on the
//! harness that was running it, on the same harness session, for graff as
//! well as Claude Code. A run that was waiting on the user's answer is never
//! re-sent: its question stays answerable, and the answer continues the run.
//!
//! Each test boots an engine over a data dir, cuts a run short (a graceful
//! `shutdown`, or a manufactured kill -9 state), boots a second engine over
//! the same dir, and checks what it dispatched on its own. The agents are
//! fakes that report a real harness id; no agent binary or account is used.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use futures::StreamExt;
use futures::stream::BoxStream;

use harness_adapters::{Harness, HarnessError, RunControls};
use harness_doc::{
    MessagePart, MessageRole, MessageStatus, SessionCommandPayload, SessionDoc,
    SessionMessageEntry, restart_note,
};
use harness_engine::{EngineCore, HarnessRegistry, RunJournal};
use harness_proto::{
    AgentEvent, ChatConfig, DoneStatus, HarnessId, Model, ReasoningLevel, RunRequest, SandboxLevel,
    SessionStatus, SteeringMode, UserInputAnswer, UserInputQuestion,
};
use harness_sync::DocsStore;

const CHAT: &str = "chat-cut-short";
const CWD: &str = "/tmp";
const MODEL: &str = "fixture-model";
/// The dev profile's store root under a data dir (`EngineCore::assemble`).
const STORE: &str = "orgs/dev-org/dev-user";

/// One run as the agent received it, and which agent received it.
#[derive(Debug, Clone)]
struct Dispatched {
    harness: HarnessId,
    request: RunRequest,
}

type Log = Arc<Mutex<Vec<Dispatched>>>;

/// What the fake agent does with its first run; later runs answer at once.
#[derive(Clone, Copy)]
enum FirstRun {
    /// Works until it is interrupted.
    Work,
    /// Asks a question and waits for the answer (or an interrupt).
    Ask,
    /// Answers at once, like every later run.
    Answer,
}

/// A fake agent reporting `id`. It continues the conversation it is asked to
/// resume (its `SessionStarted` echoes `request.resume`), and starts
/// `fresh_session` otherwise, as Claude Code and graff do.
struct FakeAgent {
    id: HarnessId,
    log: Log,
    fresh_session: String,
    first: Mutex<Option<FirstRun>>,
}

fn question() -> UserInputQuestion {
    UserInputQuestion {
        id: "q1".into(),
        header: "Target".into(),
        question: "Which branch should the fix go on?".into(),
        options: vec!["main".into(), "release".into()],
        prefill: None,
        multiline: false,
        multi_select: false,
    }
}

fn done(status: DoneStatus, session_id: &str) -> AgentEvent {
    AgentEvent::Done {
        status,
        result: None,
        error: None,
        session_id: Some(session_id.into()),
    }
}

#[async_trait]
impl Harness for FakeAgent {
    fn id(&self) -> HarnessId {
        self.id
    }
    fn display_name(&self) -> &str {
        "Fake agent"
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
        Ok(vec![])
    }
    async fn run(
        &self,
        request: RunRequest,
        controls: RunControls,
    ) -> Result<BoxStream<'static, Result<AgentEvent, HarnessError>>, HarnessError> {
        self.log.lock().unwrap().push(Dispatched {
            harness: self.id,
            request: request.clone(),
        });
        let session = request
            .resume
            .clone()
            .unwrap_or_else(|| self.fresh_session.clone());
        let started = AgentEvent::SessionStarted {
            harness: self.id,
            model: MODEL.into(),
            tools: vec![],
            cwd: request.cwd.clone(),
            session_id: session.clone(),
            assistant_message_id: "a-1".into(),
        };
        let first = self
            .first
            .lock()
            .unwrap()
            .take()
            .unwrap_or(FirstRun::Answer);
        let (tx, rx) = tokio::sync::mpsc::channel::<Result<AgentEvent, HarnessError>>(16);
        tokio::spawn(async move {
            let _ = tx.send(Ok(started)).await;
            let end = match first {
                FirstRun::Answer => {
                    let _ = tx
                        .send(Ok(AgentEvent::TextDelta {
                            text: format!("ack: {}", request.prompt),
                        }))
                        .await;
                    done(DoneStatus::Completed, &session)
                }
                FirstRun::Work => {
                    let _ = tx
                        .send(Ok(AgentEvent::TextDelta {
                            text: "working on it…".into(),
                        }))
                        .await;
                    controls.interrupt.cancelled().await;
                    done(DoneStatus::Interrupted, &session)
                }
                FirstRun::Ask => {
                    let answer = (controls.request_input)(vec![question()]);
                    // An interrupt unparks the question with no answer
                    // before it cancels the run: keep waiting for the cancel.
                    let answers = answer.await.unwrap_or_default();
                    if answers.is_empty() {
                        controls.interrupt.cancelled().await;
                        done(DoneStatus::Interrupted, &session)
                    } else {
                        let _ = tx
                            .send(Ok(AgentEvent::TextDelta {
                                text: format!("picked {}", answers[0].labels.join(",")),
                            }))
                            .await;
                        done(DoneStatus::Completed, &session)
                    }
                }
            };
            let _ = tx.send(Ok(end)).await;
        });
        Ok(futures::stream::unfold(rx, |mut rx| async move {
            rx.recv().await.map(|event| (event, rx))
        })
        .boxed())
    }
}

/// Boot an engine over `dir` running `agent`, with a decoy registered as the
/// engine default: a resumed run that lost track of its harness lands on the
/// decoy, and the test sees it.
fn boot(dir: &std::path::Path, agent: FakeAgent, decoy: &Log) -> EngineCore {
    let registry = HarnessRegistry::new();
    registry.register(Arc::new(agent));
    registry.register(Arc::new(FakeAgent {
        id: HarnessId::Mock,
        log: decoy.clone(),
        fresh_session: "decoy-session".into(),
        first: Mutex::new(None),
    }));
    EngineCore::assemble(dir, Arc::new(registry), HarnessId::Mock, None)
        .expect("engine core assembles")
}

fn agent(id: HarnessId, log: &Log, fresh_session: &str, first: FirstRun) -> FakeAgent {
    FakeAgent {
        id,
        log: log.clone(),
        fresh_session: fresh_session.into(),
        first: Mutex::new(Some(first)),
    }
}

/// The chat as the composer creates it: in a project, titled (so the
/// auto-titler stays out of the logs), with the picked agent and model.
fn create_chat(core: &EngineCore, harness: HarnessId) {
    core.workspace
        .create_space("space-cut-short", &core.device_id, CWD, None, false)
        .expect("create space row");
    core.workspace
        .create_chat(
            CHAT,
            Some("space-cut-short"),
            None,
            Some(ChatConfig {
                harness,
                model: Some(MODEL.into()),
                reasoning: None,
                model_options: Default::default(),
                sandbox: SandboxLevel::WorkspaceWrite,
                chat_mode: false,
            }),
            None,
        )
        .expect("create chat row");
    core.workspace
        .rename_chat(CHAT, "Release fix")
        .expect("rename chat");
}

fn send(core: &EngineCore, harness: HarnessId, prompt: &str, message_id: &str) {
    core.doc_host
        .queue_command(
            CHAT,
            SessionCommandPayload::Run {
                request: RunRequest {
                    turn_origin: Default::default(),
                    prompt: prompt.into(),
                    harness: Some(harness),
                    model: Some(MODEL.into()),
                    reasoning: None,
                    model_options: Default::default(),
                    cwd: CWD.into(),
                    sandbox: SandboxLevel::WorkspaceWrite,
                    auto_approve: true,
                    attachments: Vec::new(),
                    worktree: None,
                    resume: None,
                },
                message_id: message_id.into(),
            },
        )
        .expect("queue run command");
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

fn entries(core: &EngineCore) -> Vec<SessionMessageEntry> {
    core.doc_host
        .open(CHAT)
        .ok()
        .and_then(|h| h.doc().read_entries().ok())
        .unwrap_or_default()
}

fn status(core: &EngineCore) -> Option<SessionStatus> {
    core.sessions.session_status(CHAT).map(|s| s.status)
}

fn prompts(log: &Log) -> Vec<Dispatched> {
    log.lock()
        .unwrap()
        .iter()
        .filter(|d| !d.request.prompt.is_empty())
        .cloned()
        .collect()
}

fn error_notes(entries: &[SessionMessageEntry]) -> Vec<String> {
    entries
        .iter()
        .flat_map(|e| &e.parts)
        .filter_map(|p| match p {
            MessagePart::Error { message, .. } => Some(message.clone()),
            _ => None,
        })
        .collect()
}

/// Every question part in the transcript, as `(request_id, resolved)`.
fn questions(entries: &[SessionMessageEntry]) -> Vec<(String, bool)> {
    entries
        .iter()
        .flat_map(|e| &e.parts)
        .filter_map(|p| match p {
            MessagePart::Input {
                request_id,
                resolved,
                ..
            } => Some((request_id.clone(), *resolved)),
            _ => None,
        })
        .collect()
}

fn complete_answers(core: &EngineCore) -> usize {
    entries(core)
        .iter()
        .filter(|e| e.role == MessageRole::Assistant && e.status == Some(MessageStatus::Complete))
        .count()
}

/// A graceful shutdown (the app quitting into an update) mid-turn: the next
/// boot re-sends the turn on the same agent, model and harness session, and
/// says so calmly. `updated_from` stands in for the version the last boot
/// recorded.
async fn quit_mid_turn_then_boot(harness: HarnessId, updated_from: Option<&str>) {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path().join("data");
    let first: Log = Arc::default();
    let decoy: Log = Arc::default();
    let core = boot(
        &dir,
        agent(harness, &first, "session-1", FirstRun::Work),
        &decoy,
    );
    create_chat(&core, harness);
    send(&core, harness, "fix the flaky upload test", "msg-user-1");
    wait_for(
        || status(&core) == Some(SessionStatus::Working),
        "the turn to run",
    )
    .await;
    core.shutdown().await;
    drop(core);
    if let Some(version) = updated_from {
        std::fs::write(dir.join(STORE).join("journals/engine-version"), version).unwrap();
    }

    let second: Log = Arc::default();
    let core = boot(
        &dir,
        agent(harness, &second, "session-2", FirstRun::Answer),
        &decoy,
    );
    wait_for(
        || complete_answers(&core) == 1,
        "the resumed turn to finish",
    )
    .await;

    let resumed = prompts(&second);
    assert_eq!(resumed.len(), 1, "resumed exactly once: {resumed:?}");
    assert_eq!(resumed[0].harness, harness);
    assert_eq!(resumed[0].request.prompt, "fix the flaky upload test");
    assert_eq!(resumed[0].request.model.as_deref(), Some(MODEL));
    assert_eq!(
        resumed[0].request.resume.as_deref(),
        Some("session-1"),
        "the resumed turn continues the same conversation"
    );
    assert!(prompts(&decoy).is_empty(), "ran on the wrong agent");

    let entries = entries(&core);
    assert_eq!(
        entries
            .iter()
            .filter(|e| e.role == MessageRole::User)
            .count(),
        1,
        "the re-sent prompt is not shown twice"
    );
    let expected = restart_note::resuming(updated_from.map(|_| env!("CARGO_PKG_VERSION")));
    assert_eq!(error_notes(&entries), vec![expected]);
    core.shutdown().await;
}

#[tokio::test]
async fn a_quit_mid_graff_turn_resumes_it_on_the_same_graff_session() {
    quit_mid_turn_then_boot(HarnessId::Graff, None).await;
}

#[tokio::test]
async fn a_quit_mid_claude_turn_resumes_it_on_the_same_claude_session() {
    quit_mid_turn_then_boot(HarnessId::ClaudeCode, None).await;
}

#[tokio::test]
async fn an_update_mid_turn_names_the_new_version_in_the_note() {
    quit_mid_turn_then_boot(HarnessId::Graff, Some("0.0.1")).await;
}

/// The answer to an open question, sent through the durable command queue
/// as the composer does.
fn answer(core: &EngineCore, request_id: &str, label: &str) {
    core.doc_host
        .queue_command(
            CHAT,
            SessionCommandPayload::RespondInput {
                request_id: request_id.into(),
                answers: vec![UserInputAnswer {
                    question_id: "q1".into(),
                    labels: vec![label.into()],
                }],
            },
        )
        .expect("queue answer");
}

/// After a restart under an open question: nothing was re-sent, the one
/// question is still open with the calm note beside it, and answering it
/// continues the run on `session` with the answer.
async fn answer_after_restart(core: &EngineCore, log: &Log, decoy: &Log, session: &str) {
    // Let any (wrong) automatic pick-up happen before checking for it.
    tokio::time::sleep(Duration::from_millis(1500)).await;
    assert!(
        prompts(log).is_empty() && prompts(decoy).is_empty(),
        "a run waiting on an answer was re-sent: {:?}",
        prompts(log)
    );
    let before = entries(core);
    let open = questions(&before);
    assert_eq!(open.len(), 1, "one question, never asked twice: {open:?}");
    assert!(!open[0].1, "the question stays answerable");
    assert_eq!(
        error_notes(&before),
        vec![restart_note::AWAITING_ANSWER.to_owned()]
    );

    answer(core, &open[0].0, "release");
    wait_for(|| !prompts(log).is_empty(), "the answer to reach the agent").await;
    let resumed = prompts(log);
    assert_eq!(resumed.len(), 1, "{resumed:?}");
    assert_eq!(resumed[0].harness, HarnessId::Graff);
    assert_eq!(resumed[0].request.resume.as_deref(), Some(session));
    assert!(
        resumed[0].request.prompt.contains("release"),
        "the answer rides the resumed turn: {}",
        resumed[0].request.prompt
    );
    wait_for(
        || complete_answers(core) == 1,
        "the answered turn to finish",
    )
    .await;
    let after = questions(&entries(core));
    assert_eq!(after.len(), 1, "{after:?}");
    assert!(after[0].1, "answering resolves the question");
    assert!(prompts(decoy).is_empty(), "ran on the wrong agent");
}

/// #482/#517 kept: a quit while graff waits on the user's answer re-sends
/// nothing. Before, the shutdown resolved the question as the run ended, so
/// after the restart nothing could answer it.
#[tokio::test]
async fn a_quit_while_graff_waits_on_a_question_keeps_the_question_answerable() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path().join("data");
    let first: Log = Arc::default();
    let decoy: Log = Arc::default();
    let core = boot(
        &dir,
        agent(HarnessId::Graff, &first, "session-1", FirstRun::Ask),
        &decoy,
    );
    create_chat(&core, HarnessId::Graff);
    send(&core, HarnessId::Graff, "ship the fix", "msg-user-1");
    wait_for(
        || status(&core) == Some(SessionStatus::AwaitingInput),
        "the question",
    )
    .await;
    wait_for(
        || questions(&entries(&core)).len() == 1,
        "the question in the doc",
    )
    .await;
    core.shutdown().await;
    drop(core);

    let second: Log = Arc::default();
    let core = boot(
        &dir,
        agent(HarnessId::Graff, &second, "session-2", FirstRun::Answer),
        &decoy,
    );
    answer_after_restart(&core, &second, &decoy, "session-1").await;
    core.shutdown().await;
}

/// A kill -9 state: the doc holds the run's user prompt and the assistant
/// entry it left `streaming` (with `assistant_parts`), the journal the run's
/// graff session and no `Done`. No chat row, as when a crash beats the
/// debounced workspace write. `restart_marker`: a quit had started (and
/// written its shutdown marker) but didn't finish settling the run.
fn manufacture_crash(
    dir: &std::path::Path,
    assistant_parts: Vec<MessagePart>,
    restart_marker: bool,
) {
    std::fs::create_dir_all(dir).unwrap();
    std::fs::write(dir.join("device-id"), "dev-crash").unwrap();
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64;
    let store = DocsStore::open(dir.join(STORE)).unwrap();
    let doc = SessionDoc::init(CHAT).unwrap();
    for entry in [
        SessionMessageEntry {
            id: "msg-user-1".into(),
            role: MessageRole::User,
            parts: vec![MessagePart::Text {
                id: "t0".into(),
                text: "ship the fix".into(),
            }],
            created_at: now - 60_000,
            device_id: "dev-crash".into(),
            status: Some(MessageStatus::Complete),
            continuation_of: None,
            duration_ms: None,
        },
        SessionMessageEntry {
            id: "msg-assistant-1".into(),
            role: MessageRole::Assistant,
            parts: assistant_parts,
            created_at: now - 30_000,
            device_id: "dev-crash".into(),
            status: Some(MessageStatus::Streaming),
            continuation_of: None,
            duration_ms: None,
        },
    ] {
        doc.push_message(&entry).unwrap();
    }
    store
        .save_snapshot(CHAT, &doc.export_snapshot().unwrap())
        .unwrap();
    let journals = dir.join(STORE).join("journals");
    let journal = RunJournal::open(&journals).unwrap();
    journal
        .append(
            CHAT,
            &AgentEvent::SessionStarted {
                harness: HarnessId::Graff,
                model: MODEL.into(),
                tools: vec![],
                cwd: CWD.into(),
                session_id: "graff-crash".into(),
                assistant_message_id: "msg-assistant-1".into(),
            },
        )
        .unwrap();
    journal
        .append(
            CHAT,
            &AgentEvent::TextDelta {
                text: "partial…".into(),
            },
        )
        .unwrap();
    if restart_marker {
        std::fs::write(journals.join(format!("{CHAT}.restart")), "turn").unwrap();
    }
}

/// The crash path for graff: the run is re-sent on graff and its session,
/// even with no chat row to name the agent (the journal does).
#[tokio::test]
async fn a_crash_mid_graff_turn_resumes_it_on_the_same_graff_session() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path().join("data");
    manufacture_crash(
        &dir,
        vec![MessagePart::Text {
            id: "t0".into(),
            text: "partial…".into(),
        }],
        false,
    );
    let log: Log = Arc::default();
    let decoy: Log = Arc::default();
    let core = boot(
        &dir,
        agent(HarnessId::Graff, &log, "session-2", FirstRun::Answer),
        &decoy,
    );
    wait_for(
        || !prompts(&log).is_empty() || !prompts(&decoy).is_empty(),
        "the crashed run to be re-sent",
    )
    .await;
    assert!(prompts(&decoy).is_empty(), "ran on the wrong agent");
    let resumed = prompts(&log);
    assert_eq!(resumed.len(), 1, "{resumed:?}");
    assert_eq!(resumed[0].harness, HarnessId::Graff);
    assert_eq!(resumed[0].request.prompt, "ship the fix");
    assert_eq!(resumed[0].request.resume.as_deref(), Some("graff-crash"));
    wait_for(
        || complete_answers(&core) == 1,
        "the resumed turn to finish",
    )
    .await;
    assert_eq!(
        error_notes(&entries(&core)),
        vec![restart_note::resuming(None)]
    );
    core.shutdown().await;
}

/// A quit that wrote its shutdown marker but was cut off before the run
/// settled leaves both a marker and a crashed journal: the turn is re-sent
/// once, not by both recovery paths.
#[tokio::test]
async fn a_quit_cut_off_mid_drain_resumes_the_turn_once() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path().join("data");
    manufacture_crash(
        &dir,
        vec![MessagePart::Text {
            id: "t0".into(),
            text: "partial…".into(),
        }],
        true,
    );
    let log: Log = Arc::default();
    let decoy: Log = Arc::default();
    let core = boot(
        &dir,
        agent(HarnessId::Graff, &log, "session-2", FirstRun::Answer),
        &decoy,
    );
    wait_for(
        || complete_answers(&core) >= 1,
        "the resumed turn to finish",
    )
    .await;
    tokio::time::sleep(Duration::from_millis(1000)).await;
    let resumed: Vec<_> = prompts(&log).into_iter().chain(prompts(&decoy)).collect();
    assert_eq!(resumed.len(), 1, "re-sent more than once: {resumed:?}");
    assert_eq!(resumed[0].harness, HarnessId::Graff);
    core.shutdown().await;
}

/// The crash path under an open question (the reported transcript: an
/// interruption card, then the same question asked again). The run is not
/// re-sent; the one question stays answerable and the answer continues it.
#[tokio::test]
async fn a_crash_while_graff_waits_on_a_question_asks_it_once() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path().join("data");
    manufacture_crash(
        &dir,
        vec![MessagePart::Input {
            id: "req-1".into(),
            request_id: "req-1".into(),
            questions: vec![question()],
            resolved: false,
        }],
        false,
    );
    let log: Log = Arc::default();
    let decoy: Log = Arc::default();
    let core = boot(
        &dir,
        agent(HarnessId::Graff, &log, "session-2", FirstRun::Answer),
        &decoy,
    );
    // The answer's run config comes from the chat row, as in the app.
    create_chat(&core, HarnessId::Graff);
    answer_after_restart(&core, &log, &decoy, "graff-crash").await;
    core.shutdown().await;
}
