//! A chat whose checkout changed branch since its last turn does not silently
//! continue there (#354): the send is held behind a question, and each answer
//! (continue on the new branch, switch back, don't send) does what it says,
//! including after an engine restart. And the recorded checkout is the one an
//! accepted run actually used (#356).

use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use futures::StreamExt;
use futures::stream::BoxStream;

use harness_adapters::{Harness, HarnessError, RunControls};
use harness_doc::{MessagePart, MessageRole, SessionCommandPayload, SessionCommandStatus};
use harness_engine::{EngineCore, HarnessRegistry};
use harness_proto::{
    AgentEvent, DoneStatus, HarnessId, Model, ReasoningLevel, RunRequest, SandboxLevel,
    SteeringMode, ToolCall, UserInputAnswer, UserInputQuestion,
};

const CHAT: &str = "chat-branch-drift";

struct FakeAgent {
    prompts: Arc<Mutex<Vec<String>>>,
}

#[async_trait]
impl Harness for FakeAgent {
    fn id(&self) -> HarnessId {
        HarnessId::Graff
    }
    fn display_name(&self) -> &str {
        "Graff"
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
        _controls: RunControls,
    ) -> Result<BoxStream<'static, Result<AgentEvent, HarnessError>>, HarnessError> {
        let turn = {
            let mut prompts = self.prompts.lock().unwrap();
            prompts.push(request.prompt.clone());
            prompts.len()
        };
        let mut events: Vec<Result<AgentEvent, HarnessError>> =
            vec![Ok(AgentEvent::SessionStarted {
                harness: HarnessId::Graff,
                model: "test-model".into(),
                tools: vec![],
                cwd: request.cwd.clone(),
                session_id: "sess-drift".into(),
                assistant_message_id: format!("a-{turn}"),
            })];
        // `shell: <command>` runs the command in the chat's folder as the
        // agent's own tool call, the way an agent renames its branch.
        if let Some(command) = request.prompt.strip_prefix("shell: ") {
            let status = std::process::Command::new("sh")
                .args(["-c", command])
                .current_dir(&request.cwd)
                .status()
                .unwrap();
            events.push(Ok(AgentEvent::ToolCall {
                id: format!("tool-{turn}"),
                call: ToolCall::Exec {
                    command: command.into(),
                },
            }));
            events.push(Ok(AgentEvent::ToolResult {
                id: format!("tool-{turn}"),
                is_error: !status.success(),
                output: None,
                diff: None,
            }));
        }
        events.extend([
            Ok(AgentEvent::TextDelta { text: "ok".into() }),
            Ok(AgentEvent::Done {
                status: DoneStatus::Completed,
                result: None,
                error: None,
                session_id: Some("sess-drift".into()),
            }),
        ]);
        Ok(futures::stream::iter(events).boxed())
    }
}

fn git(cwd: &Path, args: &[&str]) -> String {
    let output = std::process::Command::new("git")
        .args(["-c", "user.name=Test", "-c", "user.email=test@example.com"])
        .args(args)
        .current_dir(cwd)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout).unwrap().trim().to_string()
}

fn engine(data: &Path) -> (EngineCore, Arc<Mutex<Vec<String>>>) {
    let prompts = Arc::new(Mutex::new(Vec::new()));
    let registry = HarnessRegistry::new();
    registry.register(Arc::new(FakeAgent {
        prompts: prompts.clone(),
    }));
    let core = EngineCore::assemble(data, Arc::new(registry), HarnessId::Graff, None)
        .expect("engine core assembles");
    (core, prompts)
}

async fn wait_for(mut predicate: impl FnMut() -> bool, what: &str) {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    while !predicate() {
        assert!(
            tokio::time::Instant::now() < deadline,
            "timed out waiting for {what}"
        );
        tokio::time::sleep(Duration::from_millis(15)).await;
    }
}

fn send(core: &EngineCore, id: &str, text: &str, cwd: &str) -> String {
    send_full(core, id, text, cwd, HarnessId::Graff, Vec::new())
}

fn send_with(core: &EngineCore, id: &str, text: &str, cwd: &str, harness: HarnessId) -> String {
    send_full(core, id, text, cwd, harness, Vec::new())
}

fn send_with_attachments(
    core: &EngineCore,
    id: &str,
    text: &str,
    cwd: &str,
    attachments: Vec<String>,
) -> String {
    send_full(core, id, text, cwd, HarnessId::Graff, attachments)
}

fn send_full(
    core: &EngineCore,
    id: &str,
    text: &str,
    cwd: &str,
    harness: HarnessId,
    attachments: Vec<String>,
) -> String {
    let payload = SessionCommandPayload::Run {
        request: RunRequest {
            turn_origin: Default::default(),
            prompt: text.into(),
            harness: Some(harness),
            model: None,
            reasoning: None,
            model_options: Default::default(),
            cwd: cwd.into(),
            sandbox: SandboxLevel::WorkspaceWrite,
            auto_approve: true,
            attachments,
            resume: None,
            worktree: None,
        },
        message_id: id.into(),
    };
    core.doc_host
        .queue_command(CHAT, payload)
        .expect("queue run")
}

fn answer(core: &EngineCore, request_id: &str, label: &str) {
    let payload = SessionCommandPayload::RespondInput {
        request_id: request_id.into(),
        answers: vec![UserInputAnswer {
            question_id: "branch".into(),
            labels: vec![label.into()],
        }],
    };
    core.doc_host
        .queue_command(CHAT, payload)
        .expect("queue answer");
}

fn open_question(core: &EngineCore) -> Option<(String, UserInputQuestion)> {
    let entries = core.doc_host.open(CHAT).ok()?.doc().read_entries().ok()?;
    entries.iter().rev().find_map(|entry| {
        entry.parts.iter().find_map(|part| match part {
            MessagePart::Input {
                request_id,
                questions,
                resolved: false,
                ..
            } if request_id.starts_with("branch-drift-") => {
                Some((request_id.clone(), questions[0].clone()))
            }
            _ => None,
        })
    })
}

async fn wait_question(core: &EngineCore) -> (String, UserInputQuestion) {
    let mut found = None;
    wait_for(
        || {
            found = open_question(core);
            found.is_some()
        },
        "the branch drift question",
    )
    .await;
    found.unwrap()
}

fn context_branch(core: &EngineCore) -> String {
    let chat = core.workspace.chat(CHAT).unwrap().expect("chat row");
    chat.source_context.expect("source context").branch
}

#[tokio::test(flavor = "multi_thread")]
async fn a_drifted_checkout_asks_before_the_chat_continues() {
    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path().canonicalize().unwrap();
    let repo = root.join("repo");
    std::fs::create_dir_all(&repo).unwrap();
    git(&repo, &["init", "-b", "alpha"]);
    git(&repo, &["commit", "--allow-empty", "-m", "initial"]);
    let cwd = repo.to_string_lossy().into_owned();
    let data = root.join("data");

    let (core, prompts) = engine(&data);
    core.workspace
        .create_chat(CHAT, None, Some(&core.device_id), None, Some(cwd.clone()))
        .unwrap();
    core.workspace.rename_chat(CHAT, "Pre-titled").unwrap();
    let turns = |n: usize| {
        let prompts = prompts.clone();
        move || prompts.lock().unwrap().len() == n
    };

    send(&core, "m1", "first", &cwd);
    wait_for(turns(1), "first turn").await;
    assert_eq!(context_branch(&core), "alpha");

    // A commit on the same branch is the task progressing, not drift.
    git(&repo, &["commit", "--allow-empty", "-m", "progress"]);
    send(&core, "m2", "second", &cwd);
    wait_for(turns(2), "second turn").await;
    assert!(open_question(&core).is_none());

    // Another branch: the send waits behind a question.
    git(&repo, &["switch", "-c", "beta"]);
    send(&core, "m3", "third", &cwd);
    let (request_id, question) = wait_question(&core).await;
    assert_eq!(
        question.options,
        ["Continue on beta", "Switch back to alpha", "Don't send"]
    );
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert_eq!(prompts.lock().unwrap().len(), 2, "nothing ran on beta yet");
    assert_eq!(
        context_branch(&core),
        "alpha",
        "the accepted context is kept"
    );

    // Continue: the agent runs on beta and is told the branch moved.
    answer(&core, &request_id, "Continue on beta");
    wait_for(turns(3), "the continued turn").await;
    let continued = prompts.lock().unwrap()[2].clone();
    assert!(continued.ends_with("third"), "{continued}");
    assert!(
        continued.contains("now on `beta`") && continued.contains("ran on `alpha`"),
        "{continued}"
    );
    assert_eq!(context_branch(&core), "beta");
    assert!(open_question(&core).is_none());

    // Switch back: the checkout returns to beta and the turn runs there.
    git(&repo, &["switch", "-c", "gamma"]);
    send(&core, "m4", "fourth", &cwd);
    let (request_id, _) = wait_question(&core).await;
    answer(&core, &request_id, "Switch back to beta");
    wait_for(turns(4), "the turn after switching back").await;
    assert_eq!(git(&repo, &["branch", "--show-current"]), "beta");
    assert_eq!(prompts.lock().unwrap()[3], "fourth");

    // Uncommitted work: switching back is not offered, and dismissing sends
    // nothing.
    std::fs::write(repo.join("scratch.txt"), "wip").unwrap();
    git(&repo, &["switch", "-c", "delta"]);
    send(&core, "m5", "fifth", &cwd);
    let (request_id, question) = wait_question(&core).await;
    assert_eq!(question.options, ["Continue on delta", "Don't send"]);
    core.doc_host
        .queue_command(
            CHAT,
            SessionCommandPayload::DismissInput {
                request_id: request_id.clone(),
            },
        )
        .unwrap();
    wait_for(|| open_question(&core).is_none(), "dismissal").await;
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert_eq!(
        prompts.lock().unwrap().len(),
        4,
        "a dismissed send never runs"
    );
    assert_eq!(context_branch(&core), "beta");

    // Switched back outside Harness: the next send takes the held one with
    // it and the question closes.
    send(&core, "m6", "sixth", &cwd);
    wait_question(&core).await;
    git(&repo, &["switch", "beta"]);
    send(&core, "m7", "seventh", &cwd);
    wait_for(turns(5), "the turn after an outside switch back").await;
    assert_eq!(prompts.lock().unwrap()[4], "sixth\n\nseventh");
    assert!(open_question(&core).is_none());

    // Typed text instead of a choice continues on the branch the question
    // showed, sending the text too. It used to ask again, so typing "go on"
    // looped on the same question.
    git(&repo, &["switch", "-c", "epsilon"]);
    send(&core, "m8", "eighth", &cwd);
    let (first, _) = wait_question(&core).await;
    answer(&core, &first, "go on");
    wait_for(turns(6), "the turn after a typed answer").await;
    let both = prompts.lock().unwrap()[5].clone();
    assert!(both.ends_with("eighth\n\ngo on"), "{both}");
    assert!(both.contains("now on `epsilon`"), "{both}");
    assert!(open_question(&core).is_none(), "not asked again");
    assert_eq!(context_branch(&core), "epsilon");
    let entries = core
        .doc_host
        .open(CHAT)
        .unwrap()
        .doc()
        .read_entries()
        .unwrap();
    let typed = entries
        .iter()
        .filter(|entry| entry.role == MessageRole::User)
        .next_back()
        .expect("the typed answer is in the transcript");
    assert!(
        matches!(&typed.parts[..], [MessagePart::Text { text, .. }] if text == "go on"),
        "{typed:?}"
    );

    // A question left open across a restart still sends its message.
    git(&repo, &["switch", "-c", "zeta"]);
    send(&core, "m9", "ninth", &cwd);
    let (request_id, _) = wait_question(&core).await;
    // Sent while the question waits: held with it, after it in the transcript.
    send(&core, "m10", "tenth", &cwd);
    // The optimistic transcript entry precedes the async checkout check;
    // wait until this command is actually held before restarting the engine.
    wait_send_applied(&core, "m10").await;
    core.shutdown().await;
    drop(core);

    let (core, prompts) = engine(&data);
    answer(&core, &request_id, "Continue on zeta");
    wait_for(
        || prompts.lock().unwrap().len() == 1,
        "the turn after restart",
    )
    .await;
    let resumed = prompts.lock().unwrap()[0].clone();
    assert!(resumed.ends_with("ninth\n\ntenth"), "{resumed}");
    assert!(!resumed.contains("eighth"), "{resumed}");
    assert_eq!(context_branch(&core), "zeta");
    core.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn the_chats_own_branch_rename_does_not_ask() {
    let tmp = tempfile::tempdir().unwrap();
    let (repo, cwd) = test_repo(tmp.path());
    let data = tmp.path().join("data");
    let (core, prompts) = engine(&data);
    create_chat(&core, &cwd);
    send(&core, "m1", "establish alpha", &cwd);
    wait_turn(&core, &prompts, 1).await;

    // The agent renames its branch while preparing a PR, and commits there.
    send(
        &core,
        "m2",
        "shell: git branch -m feature/renamed && git -c user.name=T -c user.email=t@t commit -q --allow-empty -m pr",
        &cwd,
    );
    wait_turn(&core, &prompts, 2).await;
    assert_eq!(git(&repo, &["branch", "--show-current"]), "feature/renamed");

    // The follow-up goes straight out, and the chat follows the new name.
    send(&core, "m3", "follow-up", &cwd);
    wait_turn(&core, &prompts, 3).await;
    assert!(open_question(&core).is_none());
    assert_eq!(prompts.lock().unwrap()[2], "follow-up", "no drift note");
    assert_eq!(context_branch(&core), "feature/renamed");
    let chat = core.workspace.chat(CHAT).unwrap().unwrap();
    assert_eq!(chat.branch.as_deref(), Some("feature/renamed"));

    // A rename the chat did not run, from outside Harness, still asks.
    git(&repo, &["branch", "-m", "outside"]);
    send(&core, "m4", "fourth", &cwd);
    let (request_id, question) = wait_question(&core).await;
    assert_eq!(question.options[0], "Continue on outside");
    answer(&core, &request_id, "Continue on outside");
    wait_turn(&core, &prompts, 4).await;

    // A rename followed by a real switch is a switch.
    send(
        &core,
        "m5",
        "shell: git branch -m renamed-again && git switch -q -c side",
        &cwd,
    );
    wait_turn(&core, &prompts, 5).await;
    send(&core, "m6", "sixth", &cwd);
    let (_, question) = wait_question(&core).await;
    assert_eq!(question.options[0], "Continue on side");
    assert_eq!(prompts.lock().unwrap().len(), 5, "held behind the question");
    core.shutdown().await;
}

fn test_repo(root: &Path) -> (std::path::PathBuf, String) {
    let repo = root.canonicalize().unwrap().join("repo");
    std::fs::create_dir_all(&repo).unwrap();
    git(&repo, &["init", "-b", "alpha"]);
    git(&repo, &["commit", "--allow-empty", "-m", "initial"]);
    let cwd = repo.to_string_lossy().into_owned();
    (repo, cwd)
}

fn create_chat(core: &EngineCore, cwd: &str) {
    core.workspace
        .create_chat(CHAT, None, Some(&core.device_id), None, Some(cwd.into()))
        .unwrap();
    core.workspace.rename_chat(CHAT, "Pre-titled").unwrap();
}

async fn wait_turn(core: &EngineCore, prompts: &Arc<Mutex<Vec<String>>>, count: usize) {
    wait_for(
        || prompts.lock().unwrap().len() == count && !core.sessions.turn_in_flight(CHAT),
        "the completed turn",
    )
    .await;
}

async fn wait_send_applied(core: &EngineCore, id: &str) {
    wait_for(
        || core.doc_host.open(CHAT).unwrap().doc().read_commands().unwrap().iter().any(|command| {
            matches!(&command.payload, SessionCommandPayload::Run { message_id, .. } if message_id == id)
                && command.status == SessionCommandStatus::Applied
        }),
        "the held send to finish persisting",
    ).await;
}

fn attachment(core: &EngineCore, name: &str) -> String {
    std::fs::create_dir_all(core.uploads.dir()).unwrap();
    let path = core.uploads.dir().join(name);
    std::fs::write(&path, b"fixture image bytes").unwrap();
    path.to_string_lossy().into_owned()
}

#[tokio::test(flavor = "multi_thread")]
async fn held_attachments_survive_restart_without_relying_on_prompt_trailers() {
    let tmp = tempfile::tempdir().unwrap();
    let (repo, cwd) = test_repo(tmp.path());
    let data = tmp.path().join("data");
    let (core, prompts) = engine(&data);
    create_chat(&core, &cwd);
    send(&core, "first", "establish alpha", &cwd);
    wait_turn(&core, &prompts, 1).await;

    git(&repo, &["switch", "-c", "beta"]);
    let first = attachment(&core, "first.png");
    let second = attachment(&core, "second.png");
    send_with_attachments(&core, "image-1", "first image", &cwd, vec![first.clone()]);
    let (request_id, _) = wait_question(&core).await;
    send_with_attachments(&core, "image-2", "second image", &cwd, vec![second.clone()]);
    wait_send_applied(&core, "image-2").await;
    core.shutdown().await;
    drop(core);

    let (core, prompts) = engine(&data);
    answer(&core, &request_id, "Continue on beta");
    wait_turn(&core, &prompts, 1).await;
    let request = core.sessions.last_request(CHAT).unwrap();
    assert_eq!(request.attachments, [first, second]);
    assert!(
        request.prompt.ends_with("first image\n\nsecond image"),
        "{}",
        request.prompt
    );
    assert!(open_question(&core).is_none());
    core.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn stale_continue_requires_new_consent_and_preserves_the_held_request() {
    let tmp = tempfile::tempdir().unwrap();
    let (repo, cwd) = test_repo(tmp.path());
    let data = tmp.path().join("data");
    let (core, prompts) = engine(&data);
    create_chat(&core, &cwd);
    send(&core, "first", "establish alpha", &cwd);
    wait_turn(&core, &prompts, 1).await;
    git(&repo, &["switch", "-c", "beta"]);
    let image = attachment(&core, "held.png");
    send_with_attachments(
        &core,
        "held",
        "keep this request",
        &cwd,
        vec![image.clone()],
    );
    let (old_id, _) = wait_question(&core).await;
    wait_send_applied(&core, "held").await;
    core.shutdown().await;
    drop(core);

    // The displayed beta question survives restart, but the folder changed again.
    git(&repo, &["switch", "-c", "gamma"]);
    let (core, prompts) = engine(&data);
    answer(&core, &old_id, "Continue on beta");
    let mut new_question = None;
    wait_for(
        || {
            new_question = open_question(&core).filter(|(id, _)| id != &old_id);
            new_question.is_some()
        },
        "fresh consent for gamma",
    )
    .await;
    let (new_id, question) = new_question.unwrap();
    assert_eq!(question.options[0], "Continue on gamma");
    assert!(
        prompts.lock().unwrap().is_empty(),
        "stale consent must not dispatch"
    );
    assert_eq!(
        context_branch(&core),
        "alpha",
        "stale consent must not advance context"
    );
    core.shutdown().await;
    drop(core);

    // Re-prompting must not lose the original request on a second restart.
    let (core, prompts) = engine(&data);
    answer(&core, &new_id, "Continue on gamma");
    wait_turn(&core, &prompts, 1).await;
    let request = core.sessions.last_request(CHAT).unwrap();
    assert_eq!(request.attachments, [image]);
    assert!(request.prompt.ends_with("keep this request"));
    assert!(request.prompt.contains("now on `gamma`"));
    assert!(request.prompt.contains("ran on `alpha`"));
    assert_eq!(context_branch(&core), "gamma");
    core.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_typed_answer_only_consents_to_the_branch_it_was_shown() {
    let tmp = tempfile::tempdir().unwrap();
    let (repo, cwd) = test_repo(tmp.path());
    let data = tmp.path().join("data");
    let (core, prompts) = engine(&data);
    create_chat(&core, &cwd);
    send(&core, "first", "establish alpha", &cwd);
    wait_turn(&core, &prompts, 1).await;
    git(&repo, &["switch", "-c", "beta"]);
    send(&core, "held", "keep this request", &cwd);
    let (old_id, _) = wait_question(&core).await;

    // The folder moved again after the beta question was shown.
    git(&repo, &["switch", "-c", "gamma"]);
    answer(&core, &old_id, "go on");
    let mut new_question = None;
    wait_for(
        || {
            new_question = open_question(&core).filter(|(id, _)| id != &old_id);
            new_question.is_some()
        },
        "fresh consent for gamma",
    )
    .await;
    let (new_id, question) = new_question.unwrap();
    assert_eq!(question.options[0], "Continue on gamma");
    assert_eq!(prompts.lock().unwrap().len(), 1, "nothing ran on gamma");
    assert_eq!(context_branch(&core), "alpha");

    answer(&core, &new_id, "Continue on gamma");
    wait_turn(&core, &prompts, 2).await;
    let request = core.sessions.last_request(CHAT).unwrap();
    assert!(
        request.prompt.ends_with("keep this request\n\ngo on"),
        "{}",
        request.prompt
    );
    assert_eq!(context_branch(&core), "gamma");
    core.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn many_held_sends_cannot_hide_the_question_even_after_restart() {
    let tmp = tempfile::tempdir().unwrap();
    let (repo, cwd) = test_repo(tmp.path());
    let data = tmp.path().join("data");
    let (core, prompts) = engine(&data);
    create_chat(&core, &cwd);
    send(&core, "first", "establish alpha", &cwd);
    wait_turn(&core, &prompts, 1).await;
    git(&repo, &["switch", "-c", "beta"]);
    send(&core, "held-first", "held first", &cwd);
    let (request_id, _) = wait_question(&core).await;
    for index in 0..70 {
        let id = format!("held-{index}");
        send(&core, &id, &format!("held {index}"), &cwd);
        wait_send_applied(&core, &id).await;
    }
    wait_send_applied(&core, "held-69").await;
    assert_eq!(
        open_question(&core).unwrap().0,
        request_id,
        "do not create another question"
    );
    let tail = core
        .doc_host
        .open(CHAT)
        .unwrap()
        .doc()
        .read_opening_tail(64)
        .unwrap();
    assert!(
        !tail.iter().flat_map(|entry| &entry.parts).any(|part| {
            matches!(
                part,
                MessagePart::Input {
                    resolved: false,
                    ..
                }
            )
        }),
        "this fixture really pushes the question outside the small tail"
    );
    core.shutdown().await;
    drop(core);

    let (core, prompts) = engine(&data);
    send(&core, "after-restart", "after restart", &cwd);
    wait_send_applied(&core, "after-restart").await;
    let entries = core
        .doc_host
        .open(CHAT)
        .unwrap()
        .doc()
        .read_entries()
        .unwrap();
    let open_count = entries
        .iter()
        .flat_map(|entry| &entry.parts)
        .filter(|part| {
            matches!(part, MessagePart::Input { request_id, resolved: false, .. }
            if request_id.starts_with("branch-drift-"))
        })
        .count();
    assert_eq!(open_count, 1, "restart must find the original question");
    assert_eq!(open_question(&core).unwrap().0, request_id);
    assert!(prompts.lock().unwrap().is_empty());

    git(&repo, &["switch", "alpha"]);
    send(&core, "release", "release", &cwd);
    wait_turn(&core, &prompts, 1).await;
    let prompt = prompts.lock().unwrap()[0].clone();
    let expected = std::iter::once("held first".to_string())
        .chain((0..70).map(|index| format!("held {index}")))
        .chain(["after restart".to_string(), "release".to_string()])
        .collect::<Vec<_>>()
        .join("\n\n");
    assert_eq!(
        prompt, expected,
        "all held sends are delivered once, in order"
    );
    assert!(open_question(&core).is_none());
    core.shutdown().await;
}

/// #356: the source context records where an ACCEPTED run ran. A request
/// rejected before it ran leaves the previous one; a run whose checkout
/// can't be observed keeps the last known one but marks it unavailable,
/// until a later run observes its checkout again.
#[tokio::test(flavor = "multi_thread")]
async fn only_an_accepted_run_records_its_checkout() {
    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path().canonicalize().unwrap();
    let repo = root.join("repo");
    std::fs::create_dir_all(&repo).unwrap();
    git(&repo, &["init", "-b", "alpha"]);
    git(&repo, &["commit", "--allow-empty", "-m", "initial"]);
    let cwd = repo.to_string_lossy().into_owned();

    let (core, prompts) = engine(&root.join("data"));
    core.workspace
        .create_chat(CHAT, None, Some(&core.device_id), None, Some(cwd.clone()))
        .unwrap();
    core.workspace.rename_chat(CHAT, "Pre-titled").unwrap();
    let turns = |n: usize| {
        let prompts = prompts.clone();
        move || prompts.lock().unwrap().len() == n
    };
    let chat = |core: &EngineCore| core.workspace.chat(CHAT).unwrap().expect("chat row");

    send(&core, "m1", "first", &cwd);
    wait_for(turns(1), "first turn").await;
    let first = chat(&core).source_context.expect("context");

    // Rejected before it ran (no such agent here): nothing is recorded.
    git(&repo, &["commit", "--allow-empty", "-m", "second"]);
    let command = send_with(&core, "m2", "rejected", &cwd, HarnessId::Codex);
    wait_for(
        || {
            let handle = core.doc_host.open(CHAT).unwrap();
            handle
                .doc()
                .read_commands()
                .unwrap()
                .iter()
                .any(|c| c.id == command && c.status == SessionCommandStatus::Rejected)
        },
        "the rejected command",
    )
    .await;
    let after_rejection = chat(&core);
    assert_eq!(
        after_rejection.source_context.as_ref().unwrap().head_sha,
        first.head_sha,
        "a rejected request does not record the checkout it would have used"
    );
    assert_eq!(after_rejection.source_context_unavailable_at, None);

    // Moved to a folder that is not a repository: the run goes ahead, and the
    // repository context is kept only as the last known one.
    let plain = root.join("plain");
    std::fs::create_dir_all(&plain).unwrap();
    let plain = plain.to_string_lossy().into_owned();
    core.workspace.set_chat_cwd(CHAT, &plain).unwrap();
    send(&core, "m3", "third", &plain);
    wait_for(turns(2), "the turn outside a repository").await;
    let outside = chat(&core);
    assert!(outside.source_context_unavailable_at.is_some());
    assert_eq!(
        outside.source_context.as_ref().unwrap().cwd,
        cwd,
        "history kept"
    );

    // Back in the repository: observed again, current again.
    core.workspace.set_chat_cwd(CHAT, &cwd).unwrap();
    send(&core, "m4", "fourth", &cwd);
    wait_for(turns(3), "the turn back in the repository").await;
    let back = chat(&core);
    assert_eq!(back.source_context_unavailable_at, None);
    assert_eq!(
        back.source_context.unwrap().head_sha.as_deref(),
        Some(git(&repo, &["rev-parse", "HEAD"]).as_str())
    );
    core.shutdown().await;
}
