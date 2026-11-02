//! Legacy chats sharing the primary checkout ask before continuing, even when
//! its branch has not changed. Recovery forks only the consenting chat from its
//! recorded context; it never switches, cleans, or copies the shared checkout.
//! Existing linked worktrees are already isolated and must not be re-migrated.

use std::ffi::OsString;
use std::path::{Path, PathBuf};
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
    SteeringMode, UserInputAnswer, UserInputQuestion,
};

const CHAT: &str = "legacy-shared-chat";
const PEER: &str = "other-shared-chat";
const OLD_PROMPT: &str = "remember the synthetic migration plan";
const HELD_PROMPT: &str = "implement the synthetic next step";

// Each scenario owns its synthetic worktree destination. Serializing this
// integration-test binary keeps its process-wide override from racing.
static WORKTREE_ENV: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());
type RequestLog = Arc<Mutex<Vec<RunRequest>>>;

struct WorktreeEnv(Option<OsString>);

impl WorktreeEnv {
    fn new(path: &Path) -> Self {
        let previous = std::env::var_os("HARNESS_WORKTREES_DIR");
        unsafe { std::env::set_var("HARNESS_WORKTREES_DIR", path) };
        Self(previous)
    }
}

impl Drop for WorktreeEnv {
    fn drop(&mut self) {
        unsafe {
            match &self.0 {
                Some(previous) => std::env::set_var("HARNESS_WORKTREES_DIR", previous),
                None => std::env::remove_var("HARNESS_WORKTREES_DIR"),
            }
        }
    }
}

struct FakeAgent {
    requests: RequestLog,
}

#[async_trait]
impl Harness for FakeAgent {
    fn id(&self) -> HarnessId {
        HarnessId::Codex
    }
    fn display_name(&self) -> &str {
        "Synthetic native adapter"
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
        let cwd = request.cwd.clone();
        let turn = {
            let mut requests = self.requests.lock().unwrap();
            requests.push(request);
            requests.len()
        };
        let session_id = format!("synthetic-native-{turn}");
        let events: Vec<Result<AgentEvent, HarnessError>> = vec![
            Ok(AgentEvent::SessionStarted {
                harness: HarnessId::Codex,
                model: "test-model".into(),
                tools: vec![],
                cwd,
                session_id: session_id.clone(),
                assistant_message_id: format!("assistant-{turn}"),
            }),
            Ok(AgentEvent::TextDelta {
                text: format!("synthetic reply {turn}"),
            }),
            Ok(AgentEvent::Done {
                status: DoneStatus::Completed,
                result: None,
                error: None,
                session_id: Some(session_id),
            }),
        ];
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

fn test_repo(root: &Path) -> (PathBuf, String) {
    let repo = root.join("repo");
    std::fs::create_dir_all(&repo).unwrap();
    git(&repo, &["init", "-b", "alpha"]);
    std::fs::write(repo.join("tracked.txt"), b"recorded baseline\n").unwrap();
    git(&repo, &["add", "tracked.txt"]);
    git(&repo, &["commit", "-m", "initial"]);
    let cwd = repo.to_string_lossy().into_owned();
    (repo, cwd)
}

fn engine(data: &Path) -> (EngineCore, RequestLog) {
    let requests = Arc::new(Mutex::new(Vec::new()));
    let registry = HarnessRegistry::new();
    registry.register(Arc::new(FakeAgent {
        requests: requests.clone(),
    }));
    let core = EngineCore::assemble(data, Arc::new(registry), HarnessId::Codex, None)
        .expect("engine core assembles");
    (core, requests)
}

fn create_chat(core: &EngineCore, id: &str, cwd: &str) {
    core.workspace
        .create_chat(id, None, Some(&core.device_id), None, Some(cwd.into()))
        .unwrap();
    core.workspace.rename_chat(id, "Synthetic task").unwrap();
}

fn send(core: &EngineCore, id: &str, prompt: &str, cwd: &str) -> String {
    core.doc_host
        .queue_command(
            CHAT,
            SessionCommandPayload::Run {
                request: RunRequest {
                    turn_origin: Default::default(),
                    prompt: prompt.into(),
                    harness: Some(HarnessId::Codex),
                    model: None,
                    reasoning: None,
                    model_options: Default::default(),
                    cwd: cwd.into(),
                    sandbox: SandboxLevel::WorkspaceWrite,
                    auto_approve: true,
                    attachments: Vec::new(),
                    resume: None,
                    worktree: None,
                },
                message_id: id.into(),
            },
        )
        .expect("queue run")
}

fn answer(core: &EngineCore, request_id: &str, label: &str) -> String {
    core.doc_host
        .queue_command(
            CHAT,
            SessionCommandPayload::RespondInput {
                request_id: request_id.into(),
                answers: vec![UserInputAnswer {
                    question_id: "branch".into(),
                    labels: vec![label.into()],
                }],
            },
        )
        .expect("queue answer")
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

async fn wait_question(core: &EngineCore) -> (String, UserInputQuestion) {
    let mut question = None;
    wait_for(
        || {
            question = open_question(core);
            question.is_some()
        },
        "shared checkout consent",
    )
    .await;
    question.unwrap()
}

async fn wait_command(core: &EngineCore, id: &str, status: SessionCommandStatus) {
    wait_for(
        || {
            core.doc_host
                .open(CHAT)
                .unwrap()
                .doc()
                .read_commands()
                .unwrap()
                .iter()
                .any(|command| command.id == id && command.status == status)
        },
        "the command acknowledgement",
    )
    .await;
}

async fn wait_turn(core: &EngineCore, requests: &RequestLog, count: usize) {
    wait_for(
        || requests.lock().unwrap().len() == count && !core.sessions.turn_in_flight(CHAT),
        "the completed native turn",
    )
    .await;
    // Source context is stamped immediately after dispatch returns, separately
    // from the adapter's event stream completing.
    wait_for(
        || {
            let row = core.workspace.chat(CHAT).unwrap().unwrap();
            row.source_context
                .as_ref()
                .is_some_and(|context| context.cwd == requests.lock().unwrap().last().unwrap().cwd)
        },
        "the accepted checkout context",
    )
    .await;
}

fn assert_shared_options(question: &UserInputQuestion, branch: &str) {
    assert!(
        question
            .options
            .iter()
            .any(|label| label == "Continue independently"),
        "{question:?}"
    );
    assert!(
        question.options.contains(&format!("Continue on {branch}")),
        "explicit shared continuation remains available: {question:?}"
    );
    assert!(
        question
            .options
            .iter()
            .all(|label| !label.starts_with("Switch back")),
        "shared checkout consent must never offer a checkout mutation: {question:?}"
    );
}

#[derive(Debug, PartialEq, Eq)]
struct CheckoutSnapshot {
    branch: String,
    head: String,
    status: String,
    index: String,
    unstaged_diff: String,
    staged_diff: String,
    files: Vec<Option<Vec<u8>>>,
}

fn snapshot(repo: &Path) -> CheckoutSnapshot {
    CheckoutSnapshot {
        branch: git(repo, &["branch", "--show-current"]),
        head: git(repo, &["rev-parse", "HEAD"]),
        status: git(repo, &["status", "--porcelain=v1", "--untracked-files=all"]),
        index: git(repo, &["ls-files", "--stage"]),
        unstaged_diff: git(repo, &["diff", "--binary"]),
        staged_diff: git(repo, &["diff", "--cached", "--binary"]),
        files: [
            "tracked.txt",
            "staged.txt",
            "untracked/scratch.bin",
            "peer.txt",
        ]
        .iter()
        .map(|name| match std::fs::read(repo.join(name)) {
            Ok(bytes) => Some(bytes),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
            Err(error) => panic!("read synthetic fixture {name}: {error}"),
        })
        .collect(),
    }
}

fn user_text(core: &EngineCore, id: &str) -> String {
    let entries = core
        .doc_host
        .open(CHAT)
        .unwrap()
        .doc()
        .read_entries()
        .unwrap();
    let matching: Vec<_> = entries.iter().filter(|entry| entry.id == id).collect();
    assert_eq!(matching.len(), 1, "one durable entry per user send");
    assert_eq!(matching[0].role, MessageRole::User);
    matching[0]
        .parts
        .iter()
        .filter_map(|part| match part {
            MessagePart::Text { text, .. } => Some(text.as_str()),
            _ => None,
        })
        .collect::<Vec<_>>()
        .join("")
}

#[tokio::test(flavor = "multi_thread")]
async fn unchanged_shared_primary_checkout_forks_from_recorded_head_without_copying_dirty_work() {
    let _serial = WORKTREE_ENV.lock().await;
    for archived_restore in [false, true] {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path().canonicalize().unwrap();
        let worktrees = root.join("worktrees");
        let _env = WorktreeEnv::new(&worktrees);
        let (repo, cwd) = test_repo(&root);
        let data = root.join("data");
        let (core, requests) = engine(&data);
        create_chat(&core, CHAT, &cwd);
        send(&core, "old", OLD_PROMPT, &cwd);
        wait_turn(&core, &requests, 1).await;
        let recorded = core
            .workspace
            .chat(CHAT)
            .unwrap()
            .unwrap()
            .source_context
            .unwrap();
        let recorded_head = recorded.head_sha.clone().unwrap();

        if archived_restore {
            core.workspace.set_chat_archived(CHAT, true).unwrap();
        }
        create_chat(&core, PEER, &cwd);
        core.workspace
            .set_chat_source_context(PEER, &recorded)
            .unwrap();
        let peer_before = core.workspace.chat(PEER).unwrap().unwrap();
        // Another task committed on the SAME branch after this chat's last
        // run. Recovery must use the recorded commit, not today's branch tip.
        std::fs::write(repo.join("tracked.txt"), b"other task committed progress\n").unwrap();
        std::fs::write(repo.join("peer.txt"), b"other task committed file\n").unwrap();
        git(&repo, &["add", "."]);
        git(&repo, &["commit", "-m", "other task progress"]);
        std::fs::write(repo.join("tracked.txt"), b"dirty shared bytes\n\0keep me\n").unwrap();
        std::fs::write(repo.join("staged.txt"), b"staged shared bytes\n").unwrap();
        git(&repo, &["add", "staged.txt"]);
        std::fs::create_dir_all(repo.join("untracked")).unwrap();
        std::fs::write(repo.join("untracked/scratch.bin"), b"\0untracked\xff\n").unwrap();
        let before = snapshot(&repo);
        assert_ne!(before.head, recorded_head);
        assert_eq!(before.branch, recorded.branch);

        // Restoring an archived conversation after restart must take the
        // same consent path as an already-open legacy conversation.
        let (core, requests, previous_turns) = if archived_restore {
            core.shutdown().await;
            drop(core);
            let (core, requests) = engine(&data);
            core.workspace.set_chat_archived(CHAT, false).unwrap();
            (core, requests, 0)
        } else {
            (core, requests, 1)
        };
        let held = send(&core, "held", HELD_PROMPT, &cwd);
        let (request_id, question) = wait_question(&core).await;
        wait_command(&core, &held, SessionCommandStatus::Applied).await;
        assert_shared_options(&question, "alpha");
        assert_eq!(
            requests.lock().unwrap().len(),
            previous_turns,
            "send is held"
        );
        assert_eq!(snapshot(&repo), before, "asking cannot touch shared work");

        answer(&core, &request_id, "Continue independently");
        wait_turn(&core, &requests, previous_turns + 1).await;
        let independent = requests.lock().unwrap()[previous_turns].clone();
        let isolated = Path::new(&independent.cwd);
        assert_ne!(independent.cwd, cwd);
        assert!(isolated.starts_with(&worktrees));
        assert!(
            isolated.join(".git").is_file(),
            "a linked worktree, not a copy"
        );
        assert_eq!(git(isolated, &["rev-parse", "HEAD"]), recorded_head);
        let isolated_branch = git(isolated, &["branch", "--show-current"]);
        assert_ne!(isolated_branch, before.branch);
        assert_eq!(git(isolated, &["status", "--porcelain"]), "");
        assert_eq!(
            std::fs::read(isolated.join("tracked.txt")).unwrap(),
            b"recorded baseline\n"
        );
        for absent in ["staged.txt", "untracked/scratch.bin", "peer.txt"] {
            assert!(
                !isolated.join(absent).exists(),
                "shared-root work was not copied: {absent}"
            );
        }
        assert_eq!(independent.resume, None, "native sessions are cwd-scoped");
        assert!(
            independent.prompt.contains(OLD_PROMPT),
            "{}",
            independent.prompt
        );
        assert!(
            independent.prompt.contains("synthetic reply 1"),
            "{}",
            independent.prompt
        );
        assert!(
            independent.prompt.contains("read-only"),
            "{}",
            independent.prompt
        );
        assert_eq!(
            independent.prompt.matches(HELD_PROMPT).count(),
            1,
            "the held prompt must not also be seeded as history"
        );
        assert!(independent.prompt.ends_with(HELD_PROMPT));
        assert_eq!(
            user_text(&core, "old"),
            OLD_PROMPT,
            "history stays read-only"
        );
        assert_eq!(user_text(&core, "held"), HELD_PROMPT);
        assert_eq!(
            snapshot(&repo),
            before,
            "root HEAD, index and dirty bytes are unchanged"
        );
        let peer_after = core.workspace.chat(PEER).unwrap().unwrap();
        assert_eq!(peer_after.cwd, peer_before.cwd);
        assert_eq!(peer_after.source_context, peer_before.source_context);
        assert_eq!(
            peer_after.harness_session_id,
            peer_before.harness_session_id
        );
        let recovered = core.workspace.chat(CHAT).unwrap().unwrap();
        assert_eq!(recovered.cwd.as_deref(), Some(independent.cwd.as_str()));
        assert_ne!(
            recovered.source_context.as_ref().unwrap().checkout_id,
            recorded.checkout_id
        );
        assert_eq!(
            core.sessions.last_request(CHAT).unwrap().cwd,
            independent.cwd
        );
        assert!(open_question(&core).is_none());

        // A queued command captured before recovery still names the shared
        // cwd. The durable move must retarget it, not return to the root.
        send(&core, "follow-up", "synthetic follow-up", &cwd);
        wait_turn(&core, &requests, previous_turns + 2).await;
        let follow_up = requests.lock().unwrap()[previous_turns + 1].clone();
        assert_eq!(follow_up.cwd, independent.cwd);
        assert_eq!(
            follow_up.prompt, "synthetic follow-up",
            "seed context only once"
        );
        assert!(follow_up.resume.is_some(), "resume the new native session");
        assert!(
            open_question(&core).is_none(),
            "independent continuation asks only once"
        );
        assert_eq!(snapshot(&repo), before);
        assert_eq!(
            git(&repo, &["worktree", "list", "--porcelain"])
                .matches("worktree ")
                .count(),
            2
        );
        core.shutdown().await;
        assert_eq!(
            isolated_branch, "task/synthetic-task",
            "recovery uses the existing task title"
        );
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn shared_clean_drift_refuses_forged_switch_back_and_falls_back_to_recorded_branch() {
    let _serial = WORKTREE_ENV.lock().await;
    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path().canonicalize().unwrap();
    let _env = WorktreeEnv::new(&root.join("worktrees"));
    let (repo, cwd) = test_repo(&root);
    let (core, requests) = engine(&root.join("data"));
    create_chat(&core, CHAT, &cwd);
    send(&core, "old", OLD_PROMPT, &cwd);
    wait_turn(&core, &requests, 1).await;
    let recorded_head = git(&repo, &["rev-parse", "HEAD"]);
    let mut recorded = core
        .workspace
        .chat(CHAT)
        .unwrap()
        .unwrap()
        .source_context
        .unwrap();
    recorded.head_sha = None; // Older rows know the branch but not its commit.
    core.workspace
        .set_chat_source_context(CHAT, &recorded)
        .unwrap();
    create_chat(&core, PEER, &cwd);
    git(&repo, &["switch", "-c", "beta"]);
    git(
        &repo,
        &["commit", "--allow-empty", "-m", "other branch progress"],
    );
    let before = snapshot(&repo);
    assert_eq!(
        before.status, "",
        "clean checkout would otherwise permit Switch back"
    );
    send(&core, "held", HELD_PROMPT, &cwd);
    let (request_id, question) = wait_question(&core).await;
    assert_shared_options(&question, "beta");

    let forged = answer(&core, &request_id, "Switch back to alpha");
    wait_command(&core, &forged, SessionCommandStatus::Rejected).await;
    assert_eq!(
        snapshot(&repo),
        before,
        "a forged option cannot switch a shared checkout"
    );
    assert_eq!(
        requests.lock().unwrap().len(),
        1,
        "forged consent cannot dispatch"
    );
    let (request_id, question) =
        open_question(&core).expect("the held request still needs consent");
    assert_shared_options(&question, "beta");
    answer(&core, &request_id, "Continue independently");
    wait_turn(&core, &requests, 2).await;
    let independent = requests.lock().unwrap()[1].clone();
    assert_ne!(independent.cwd, cwd);
    assert_eq!(
        git(Path::new(&independent.cwd), &["rev-parse", "HEAD"]),
        recorded_head,
        "without a head SHA, fork the chat's last branch, not current beta"
    );
    assert_eq!(independent.prompt.matches(HELD_PROMPT).count(), 1);
    assert_eq!(snapshot(&repo), before);
    assert_eq!(
        core.workspace.chat(PEER).unwrap().unwrap().cwd.as_deref(),
        Some(cwd.as_str())
    );
    core.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn explicit_shared_continuation_is_acknowledged_once_even_after_restart() {
    let _serial = WORKTREE_ENV.lock().await;
    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path().canonicalize().unwrap();
    let _env = WorktreeEnv::new(&root.join("worktrees"));
    let (repo, cwd) = test_repo(&root);
    let data = root.join("data");
    let (core, requests) = engine(&data);
    create_chat(&core, CHAT, &cwd);
    send(&core, "old", OLD_PROMPT, &cwd);
    wait_turn(&core, &requests, 1).await;
    create_chat(&core, PEER, &cwd);
    let before = snapshot(&repo);
    send(&core, "held", HELD_PROMPT, &cwd);
    let (request_id, question) = wait_question(&core).await;
    assert_shared_options(&question, "alpha");
    assert_eq!(requests.lock().unwrap().len(), 1);
    answer(&core, &request_id, "Continue on alpha");
    wait_turn(&core, &requests, 2).await;
    let continued = requests.lock().unwrap()[1].clone();
    assert_eq!(continued.cwd, cwd);
    assert_eq!(continued.resume.as_deref(), Some("synthetic-native-1"));
    assert_eq!(continued.prompt.matches(HELD_PROMPT).count(), 1);
    assert_eq!(snapshot(&repo), before);
    assert!(open_question(&core).is_none());
    core.shutdown().await;
    drop(core);

    let (core, requests) = engine(&data);
    send(&core, "follow-up", "acknowledged shared follow-up", &cwd);
    wait_turn(&core, &requests, 1).await;
    assert!(
        open_question(&core).is_none(),
        "the explicit acknowledgement is durable"
    );
    let follow_up = requests.lock().unwrap()[0].clone();
    assert_eq!(follow_up.cwd, cwd);
    assert_eq!(follow_up.prompt, "acknowledged shared follow-up");
    assert_eq!(follow_up.resume.as_deref(), Some("synthetic-native-2"));
    assert_eq!(
        git(&repo, &["worktree", "list", "--porcelain"])
            .matches("worktree ")
            .count(),
        1
    );
    assert_eq!(snapshot(&repo), before);
    core.shutdown().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn existing_linked_worktree_chats_are_not_migrated_again_including_archived_restore() {
    let _serial = WORKTREE_ENV.lock().await;
    for archived_restore in [false, true] {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path().canonicalize().unwrap();
        let _env = WorktreeEnv::new(&root.join("new-worktrees"));
        let (repo, root_cwd) = test_repo(&root);
        let linked = root.join("already-isolated");
        git(
            &repo,
            &[
                "worktree",
                "add",
                "-b",
                "existing-task",
                linked.to_str().unwrap(),
                "alpha",
            ],
        );
        let cwd = linked.to_string_lossy().into_owned();
        let data = root.join("data");
        let (core, requests) = engine(&data);
        create_chat(&core, CHAT, &cwd);
        send(&core, "old", OLD_PROMPT, &cwd);
        wait_turn(&core, &requests, 1).await;
        let recorded = core
            .workspace
            .chat(CHAT)
            .unwrap()
            .unwrap()
            .source_context
            .unwrap();
        create_chat(&core, PEER, &cwd);
        create_chat(&core, "root-chat", &root_cwd);
        let before = snapshot(&repo);
        let (core, requests, previous_turns) = if archived_restore {
            core.workspace.set_chat_archived(CHAT, true).unwrap();
            core.shutdown().await;
            drop(core);
            let (core, requests) = engine(&data);
            core.workspace.set_chat_archived(CHAT, false).unwrap();
            (core, requests, 0)
        } else {
            (core, requests, 1)
        };
        send(
            &core,
            "follow-up",
            "stay in the existing linked checkout",
            &cwd,
        );
        wait_turn(&core, &requests, previous_turns + 1).await;
        let request = requests.lock().unwrap()[previous_turns].clone();
        assert_eq!(request.cwd, cwd);
        assert_eq!(request.prompt, "stay in the existing linked checkout");
        assert!(request.resume.is_some());
        assert!(
            open_question(&core).is_none(),
            "only legacy primary checkouts need recovery"
        );
        let context = core
            .workspace
            .chat(CHAT)
            .unwrap()
            .unwrap()
            .source_context
            .unwrap();
        assert_eq!(context.checkout_id, recorded.checkout_id);
        assert_eq!(context.branch, "existing-task");
        assert_eq!(
            git(&repo, &["worktree", "list", "--porcelain"])
                .matches("worktree ")
                .count(),
            2
        );
        assert_eq!(snapshot(&repo), before);
        core.shutdown().await;
    }
}
