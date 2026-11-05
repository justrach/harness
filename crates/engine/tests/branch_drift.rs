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
use harness_doc::{
    MessagePart, MessageRole, MessageStatus, SessionCommandPayload, SessionCommandStatus,
    SessionMessageEntry,
};
use harness_engine::{EngineCore, HarnessRegistry};
use harness_proto::{
    AgentEvent, DoneStatus, HarnessId, Model, ReasoningLevel, RunRequest, SandboxLevel,
    SteeringMode, ToolCall, UserInputAnswer, UserInputQuestion,
};

const CHAT: &str = "chat-branch-drift";
const PEER: &str = "chat-branch-drift-peer";

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
                // A live document can expose the input before its questions
                // are populated; wait for a usable question instead of indexing.
                questions
                    .first()
                    .map(|question| (request_id.clone(), question.clone()))
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

/// The context is recorded once dispatch returns, which can be after the agent
/// saw the prompt.
async fn wait_context(core: &EngineCore, branch: &str) {
    wait_for(|| context_branch(core) == branch, "the recorded checkout").await;
}

/// Another chat in the same folder: the one case that still asks.
fn share_checkout(core: &EngineCore, cwd: &str) {
    core.workspace
        .create_chat(PEER, None, Some(&core.device_id), None, Some(cwd.into()))
        .unwrap();
}

/// A turn on a new branch went straight out, and the agent was told.
async fn assert_agent_told(
    core: &EngineCore,
    prompts: &Arc<Mutex<Vec<String>>>,
    turn: usize,
    from: &str,
    to: &str,
    label: &str,
) {
    wait_for(
        || prompts.lock().unwrap().len() >= turn || open_question(core).is_some(),
        "the turn on the new branch",
    )
    .await;
    assert!(open_question(core).is_none(), "asked: {label}");
    wait_turn(core, prompts, turn).await;
    let prompt = prompts.lock().unwrap()[turn - 1].clone();
    assert!(
        prompt.contains(&format!("now on `{to}`")) && prompt.contains(&format!("ran on `{from}`")),
        "{label}: {prompt}"
    );
    wait_context(core, to).await;
}

/// The last message the person sent, as the transcript shows it.
fn last_user_text(core: &EngineCore) -> String {
    let entries = core
        .doc_host
        .open(CHAT)
        .unwrap()
        .doc()
        .read_entries()
        .unwrap();
    let entry = entries
        .iter()
        .rfind(|entry| entry.role == MessageRole::User)
        .expect("a user message");
    match &entry.parts[..] {
        [MessagePart::Text { text, .. }] => text.clone(),
        parts => panic!("{parts:?}"),
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn a_changed_branch_goes_ahead_without_asking_and_tells_the_agent() {
    let tmp = tempfile::tempdir().unwrap();
    let (repo, cwd) = test_repo(tmp.path());
    let (core, prompts) = engine(&tmp.path().join("data"));
    create_chat(&core, &cwd);

    send(&core, "m1", "first", &cwd);
    wait_turn(&core, &prompts, 1).await;
    assert_eq!(context_branch(&core), "alpha");

    // A commit on the same branch is the task progressing, not drift.
    git(&repo, &["commit", "--allow-empty", "-m", "progress"]);
    send(&core, "m2", "second", &cwd);
    wait_turn(&core, &prompts, 2).await;
    assert_eq!(prompts.lock().unwrap()[1], "second");

    // Another branch: the turn runs there, with a note only the agent sees.
    git(&repo, &["switch", "-c", "beta"]);
    send(&core, "m3", "third", &cwd);
    assert_agent_told(&core, &prompts, 3, "alpha", "beta", "new branch").await;
    assert!(prompts.lock().unwrap()[2].ends_with("third"));
    assert_eq!(last_user_text(&core), "third");

    // Told once: the next turn on the same branch has no note.
    send(&core, "m4", "fourth", &cwd);
    wait_turn(&core, &prompts, 4).await;
    assert_eq!(prompts.lock().unwrap()[3], "fourth");

    // Uncommitted work doesn't change that, and nothing touches the checkout.
    std::fs::write(repo.join("scratch.txt"), "wip").unwrap();
    git(&repo, &["switch", "-c", "delta"]);
    send(&core, "m5", "fifth", &cwd);
    assert_agent_told(&core, &prompts, 5, "beta", "delta", "uncommitted work").await;
    assert_eq!(git(&repo, &["branch", "--show-current"]), "delta");
    assert!(repo.join("scratch.txt").exists());

    // A command has to start the prompt to run, so it goes as typed.
    git(&repo, &["switch", "-c", "epsilon"]);
    send(&core, "m6", "/compact", &cwd);
    wait_turn(&core, &prompts, 6).await;
    assert!(open_question(&core).is_none());
    assert_eq!(prompts.lock().unwrap()[5], "/compact");
    core.shutdown().await;
}

/// Writes the question earlier versions asked on any branch change, over a
/// message waiting behind it.
fn seed_old_question(core: &EngineCore, held: &str, options: &[&str]) -> String {
    let handle = core.doc_host.open(CHAT).unwrap();
    handle
        .write_user_message(&format!("message-{held}"), held, 1)
        .unwrap();
    let request_id = format!("branch-drift-saved-{held}");
    handle
        .doc()
        .push_message(&SessionMessageEntry {
            id: format!("question-{held}"),
            role: MessageRole::Assistant,
            parts: vec![MessagePart::Input {
                id: request_id.clone(),
                request_id: request_id.clone(),
                questions: vec![UserInputQuestion {
                    id: "branch".into(),
                    header: "Branch changed".into(),
                    question: "This chat's checkout moved. How should it continue?".into(),
                    options: options.iter().map(|option| option.to_string()).collect(),
                    multi_select: false,
                    prefill: None,
                    multiline: false,
                }],
                resolved: false,
            }],
            created_at: 2,
            device_id: core.device_id.clone(),
            status: Some(MessageStatus::Complete),
            continuation_of: None,
            duration_ms: None,
        })
        .unwrap();
    request_id
}

#[tokio::test(flavor = "multi_thread")]
async fn a_question_saved_by_an_older_version_closes_and_still_sends_its_message() {
    let tmp = tempfile::tempdir().unwrap();
    let (repo, cwd) = test_repo(tmp.path());
    let (core, prompts) = engine(&tmp.path().join("data"));
    create_chat(&core, &cwd);
    send(&core, "m1", "first", &cwd);
    wait_turn(&core, &prompts, 1).await;
    git(&repo, &["switch", "-c", "beta"]);
    seed_old_question(&core, "held", &["Continue on beta", "Don't send"]);
    assert!(open_question(&core).is_some());

    // The next send closes it and takes the waiting message along.
    send(&core, "m2", "next", &cwd);
    wait_turn(&core, &prompts, 2).await;
    assert_agent_told(&core, &prompts, 2, "alpha", "beta", "old question").await;
    assert!(
        prompts.lock().unwrap()[1].ends_with("held\n\nnext"),
        "{}",
        prompts.lock().unwrap()[1]
    );
    core.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn answering_a_saved_question_still_works_even_if_the_branch_moved_again() {
    let tmp = tempfile::tempdir().unwrap();
    let (repo, cwd) = test_repo(tmp.path());
    let (core, prompts) = engine(&tmp.path().join("data"));
    create_chat(&core, &cwd);
    send(&core, "m1", "first", &cwd);
    wait_turn(&core, &prompts, 1).await;
    git(&repo, &["switch", "-c", "beta"]);
    let request_id = seed_old_question(
        &core,
        "held",
        &["Continue on beta", "Switch back to alpha", "Don't send"],
    );

    // It showed beta and the folder is on gamma now: it isn't asked again.
    git(&repo, &["switch", "-c", "gamma"]);
    answer(&core, &request_id, "Continue on beta");
    wait_turn(&core, &prompts, 2).await;
    assert_agent_told(&core, &prompts, 2, "alpha", "gamma", "moved again").await;
    assert!(prompts.lock().unwrap()[1].ends_with("held"));

    // Switch back is still honored where a saved question offers it.
    git(&repo, &["switch", "-c", "delta"]);
    let request_id = seed_old_question(
        &core,
        "held again",
        &["Continue on delta", "Switch back to gamma", "Don't send"],
    );
    answer(&core, &request_id, "Switch back to gamma");
    wait_turn(&core, &prompts, 3).await;
    assert_eq!(git(&repo, &["branch", "--show-current"]), "gamma");
    assert_eq!(prompts.lock().unwrap()[2], "held again");
    assert!(open_question(&core).is_none());
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

    // A rename the chat did not run, from outside Harness, gets the note.
    git(&repo, &["branch", "-m", "outside"]);
    send(&core, "m4", "fourth", &cwd);
    assert_agent_told(
        &core,
        &prompts,
        4,
        "feature/renamed",
        "outside",
        "outside rename",
    )
    .await;

    // A rename followed by a real switch is a switch.
    send(
        &core,
        "m5",
        "shell: git branch -m renamed-again && git switch -q -c side",
        &cwd,
    );
    wait_turn(&core, &prompts, 5).await;
    send(&core, "m6", "sixth", &cwd);
    assert_agent_told(&core, &prompts, 6, "outside", "side", "rename then switch").await;
    core.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn the_chats_own_new_branch_does_not_ask() {
    let tmp = tempfile::tempdir().unwrap();
    let (repo, cwd) = test_repo(tmp.path());
    let data = tmp.path().join("data");
    let (core, prompts) = engine(&data);
    create_chat(&core, &cwd);
    send(&core, "m1", "establish alpha", &cwd);
    wait_turn(&core, &prompts, 1).await;

    send(
        &core,
        "m2",
        "shell: git switch -c feature/example && git -c user.name=Test -c user.email=test@example.com commit -q --allow-empty -m 'task; work'",
        &cwd,
    );
    wait_turn(&core, &prompts, 2).await;
    assert_eq!(git(&repo, &["branch", "--show-current"]), "feature/example");

    send(&core, "m3", "follow-up", &cwd);
    wait_for(
        || prompts.lock().unwrap().len() == 3 || open_question(&core).is_some(),
        "the follow-up to dispatch or ask",
    )
    .await;
    assert!(
        open_question(&core).is_none(),
        "the chat's own fresh branch must not require redundant consent"
    );
    wait_turn(&core, &prompts, 3).await;
    assert_eq!(prompts.lock().unwrap()[2], "follow-up", "no drift note");
    assert_eq!(context_branch(&core), "feature/example");
    let chat = core.workspace.chat(CHAT).unwrap().unwrap();
    assert_eq!(chat.branch.as_deref(), Some("feature/example"));
    core.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn owned_branch_creation_from_an_explicit_base_survives_restart() {
    for operation in ["git switch --create", "git checkout -q -b"] {
        let tmp = tempfile::tempdir().unwrap();
        let (repo, cwd) = test_repo(tmp.path());
        git(&repo, &["branch", "base"]);
        git(&repo, &["commit", "--allow-empty", "-m", "advance alpha"]);
        let base_sha = git(&repo, &["rev-parse", "base"]);
        assert_ne!(base_sha, git(&repo, &["rev-parse", "HEAD"]));
        let data = tmp.path().join("data");
        let (core, prompts) = engine(&data);
        create_chat(&core, &cwd);
        send(&core, "m1", "establish alpha", &cwd);
        wait_turn(&core, &prompts, 1).await;
        send(
            &core,
            "m2",
            &format!("shell: git status --short; {operation} feature/example base"),
            &cwd,
        );
        wait_turn(&core, &prompts, 2).await;
        assert_eq!(git(&repo, &["rev-parse", "HEAD"]), base_sha);
        core.shutdown().await;
        drop(core);

        let (core, prompts) = engine(&data);
        send(&core, "m3", "follow-up after restart", &cwd);
        wait_for(
            || prompts.lock().unwrap().len() == 1 || open_question(&core).is_some(),
            "the restored follow-up to dispatch or ask",
        )
        .await;
        assert!(open_question(&core).is_none(), "{operation}");
        wait_turn(&core, &prompts, 1).await;
        assert_eq!(prompts.lock().unwrap()[0], "follow-up after restart");
        let chat = core.workspace.chat(CHAT).unwrap().unwrap();
        let context = chat.source_context.unwrap();
        assert_eq!(context.branch, "feature/example");
        assert_eq!(context.head_sha.as_deref(), Some(base_sha.as_str()));
        assert_eq!(chat.branch.as_deref(), Some("feature/example"));
        core.shutdown().await;
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn unrelated_or_unproven_branch_creation_still_gets_the_note() {
    for (command, outside_creation) in [
        ("echo git switch -c feature/example", true),
        ("git switch -c feature/example missing-base", true),
        ("git switch -C feature/example", false),
        ("git checkout -B feature/example", false),
        (
            "git switch -c feature/example && git switch alpha && git switch feature/example",
            false,
        ),
    ] {
        let tmp = tempfile::tempdir().unwrap();
        let (repo, cwd) = test_repo(tmp.path());
        let (core, prompts) = engine(&tmp.path().join("data"));
        create_chat(&core, &cwd);
        send(&core, "m1", "establish alpha", &cwd);
        wait_turn(&core, &prompts, 1).await;
        send(&core, "m2", &format!("shell: {command}"), &cwd);
        wait_turn(&core, &prompts, 2).await;
        if outside_creation {
            git(&repo, &["switch", "-c", "feature/example"]);
        }
        send(&core, "m3", "follow-up", &cwd);
        assert_agent_told(&core, &prompts, 3, "alpha", "feature/example", command).await;
        core.shutdown().await;
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn skipped_or_failed_creation_cannot_claim_an_external_switch() {
    for (command, reserve_branch) in [
        ("false && git switch -c feature/example; true", false),
        ("exit 0; git switch -c feature/example", false),
        ("e''xit 0; git switch -c feature/example", false),
        ("{ exit 0; }; git switch -c feature/example", false),
        ("exec true; git switch -c feature/example", false),
        (
            "trap 'exit 0' EXIT; false && git switch -c feature/example",
            false,
        ),
        ("if false; then\ngit switch -c feature/example\nfi", false),
        ("git switch -c feature/example; git status --short", true),
    ] {
        let tmp = tempfile::tempdir().unwrap();
        let (repo, cwd) = test_repo(tmp.path());
        let (core, prompts) = engine(&tmp.path().join("data"));
        create_chat(&core, &cwd);
        send(&core, "m1", "establish alpha", &cwd);
        wait_turn(&core, &prompts, 1).await;
        if reserve_branch {
            git(&repo, &["branch", "feature/example"]);
        }
        send(&core, "m2", &format!("shell: {command}"), &cwd);
        wait_turn(&core, &prompts, 2).await;
        assert_eq!(git(&repo, &["branch", "--show-current"]), "alpha");
        if reserve_branch {
            git(&repo, &["switch", "feature/example"]);
        } else {
            git(&repo, &["switch", "-c", "feature/example"]);
        }
        send(&core, "m3", "follow-up", &cwd);
        assert_agent_told(&core, &prompts, 3, "alpha", "feature/example", command).await;
        core.shutdown().await;
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn owned_creation_gets_the_note_when_git_evidence_is_missing_or_mismatched() {
    for evidence in ["branch", "head", "start-point"] {
        let tmp = tempfile::tempdir().unwrap();
        let (repo, cwd) = test_repo(tmp.path());
        let (core, prompts) = engine(&tmp.path().join("data"));
        create_chat(&core, &cwd);
        send(&core, "m1", "establish alpha", &cwd);
        wait_turn(&core, &prompts, 1).await;
        send(&core, "m2", "shell: git switch -c feature/example", &cwd);
        wait_turn(&core, &prompts, 2).await;
        let branch_log = repo.join(".git/logs/refs/heads/feature/example");
        match evidence {
            "branch" => std::fs::remove_file(&branch_log).unwrap(),
            "head" => std::fs::remove_file(repo.join(".git/logs/HEAD")).unwrap(),
            _ => {
                let original = std::fs::read_to_string(&branch_log).unwrap();
                assert!(original.contains("branch: Created from HEAD"));
                std::fs::write(
                    &branch_log,
                    original.replace(
                        "branch: Created from HEAD",
                        "branch: Created from other-base",
                    ),
                )
                .unwrap();
            }
        }
        send(&core, "m3", "follow-up", &cwd);
        assert_agent_told(&core, &prompts, 3, "alpha", "feature/example", evidence).await;
        core.shutdown().await;
    }
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

    share_checkout(&core, &cwd);
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
    share_checkout(&core, &cwd);
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
    assert_eq!(question.options[1], "Continue on gamma");
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
    share_checkout(&core, &cwd);
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
    assert_eq!(question.options[1], "Continue on gamma");
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
    share_checkout(&core, &cwd);
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

    // No longer shared, and back on its branch: the question has no reason left.
    core.workspace
        .set_chat_cwd(PEER, &tmp.path().to_string_lossy())
        .unwrap();
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
    // Recorded once dispatch returns, which can be after the agent saw the prompt.
    wait_for(
        || chat(&core).source_context_unavailable_at.is_some(),
        "the checkout marked unavailable",
    )
    .await;
    let outside = chat(&core);
    assert_eq!(
        outside.source_context.as_ref().unwrap().cwd,
        cwd,
        "history kept"
    );

    // Back in the repository: observed again, current again.
    core.workspace.set_chat_cwd(CHAT, &cwd).unwrap();
    send(&core, "m4", "fourth", &cwd);
    wait_for(turns(3), "the turn back in the repository").await;
    wait_for(
        || chat(&core).source_context_unavailable_at.is_none(),
        "the checkout observed again",
    )
    .await;
    let back = chat(&core);
    assert_eq!(
        back.source_context.unwrap().head_sha.as_deref(),
        Some(git(&repo, &["rev-parse", "HEAD"]).as_str())
    );
    core.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_command_continued_after_a_branch_change_still_starts_the_prompt() {
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
    send(&core, "m1", "first", &cwd);
    wait_for(turns(1), "first turn").await;

    // `/compact` held behind the question, then continued: the branch note
    // went in front of it, so the agent read the command as plain text.
    share_checkout(&core, &cwd);
    git(&repo, &["switch", "-c", "beta"]);
    send(&core, "m2", "/compact", &cwd);
    let (request_id, _) = wait_question(&core).await;
    answer(&core, &request_id, "Continue on beta");
    wait_for(turns(2), "the continued command").await;
    assert_eq!(prompts.lock().unwrap()[1], "/compact");
    wait_context(&core, "beta").await;
}
