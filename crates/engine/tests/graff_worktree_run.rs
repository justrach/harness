//! Graff owns its worktrees: a Run carrying a `WorktreeSpec` for a Graff chat
//! mints no `harness/<name>` tree on the host. The adapter is handed a
//! per-chat `agent_name` (it launches `graff acp -w <name>` from the repo),
//! and once the session reports the tree Graff ran it in, the chat row moves
//! there — so the next run spawns and resumes inside the tree.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use futures::StreamExt;
use futures::stream::BoxStream;

use harness_adapters::{Harness, HarnessError, RunControls};
use harness_doc::{MessageRole, MessageStatus, SessionCommandPayload};
use harness_engine::{EngineCore, HarnessRegistry};
use harness_proto::graff_worktree::GraffWorktree;
use harness_proto::{
    AgentEvent, DoneStatus, HarnessId, Model, ReasoningLevel, RunRequest, SandboxLevel,
    SteeringMode, WorktreeSpec,
};

const CHAT: &str = "chat-graff-tree";

#[derive(Debug, Clone)]
struct Seen {
    cwd: String,
    agent_name: Option<String>,
    resume: Option<String>,
}

/// Behaves like `graff acp [-w <name>]`: with a name, the session runs in
/// `<cwd>/.graff/worktrees/<name>` and SessionStarted reports that tree.
struct FakeGraff {
    seen: Arc<Mutex<Vec<Seen>>>,
}

#[async_trait]
impl Harness for FakeGraff {
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
        let agent_name = request.worktree.as_ref().and_then(|spec| spec.agent_name.clone());
        self.seen.lock().unwrap().push(Seen {
            cwd: request.cwd.clone(),
            agent_name: agent_name.clone(),
            resume: request.resume.clone(),
        });
        let cwd = match &agent_name {
            Some(name) => {
                let tree = GraffWorktree::path_in(&request.cwd, name);
                if !std::path::Path::new(&tree).exists() {
                    git(
                        &request.cwd,
                        &["worktree", "add", "-b", &format!("actual-{name}"), &tree],
                    );
                }
                tree
            }
            None => request.cwd.clone(),
        };
        let events: Vec<Result<AgentEvent, HarnessError>> = vec![
            Ok(AgentEvent::SessionStarted {
                harness: HarnessId::Graff,
                model: "codex/gpt-6-sol".into(),
                tools: vec![],
                cwd,
                session_id: "sess-graff".into(),
                assistant_message_id: format!("a-{}", self.seen.lock().unwrap().len()),
            }),
            Ok(AgentEvent::TextDelta { text: format!("ack: {}", request.prompt) }),
            Ok(AgentEvent::Done {
                status: DoneStatus::Completed,
                result: None,
                error: None,
                session_id: Some("sess-graff".into()),
            }),
        ];
        Ok(futures::stream::iter(events).boxed())
    }
}

fn git(cwd: &str, args: &[&str]) -> String {
    let output = std::process::Command::new("git")
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

fn init_repo(path: &std::path::Path) -> String {
    std::fs::create_dir_all(path).unwrap();
    let cwd = path.to_string_lossy().into_owned();
    git(&cwd, &["init", "-b", "main"]);
    git(
        &cwd,
        &[
            "-c",
            "user.name=Test",
            "-c",
            "user.email=test@example.com",
            "commit",
            "--allow-empty",
            "-m",
            "initial",
        ],
    );
    cwd
}

async fn wait_for(mut predicate: impl FnMut() -> bool, what: &str) {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    while !predicate() {
        assert!(tokio::time::Instant::now() < deadline, "timed out waiting for {what}");
        tokio::time::sleep(Duration::from_millis(15)).await;
    }
}

fn completed_turns(core: &EngineCore) -> usize {
    core.doc_host
        .open(CHAT)
        .ok()
        .and_then(|h| h.doc().read_entries().ok())
        .unwrap_or_default()
        .iter()
        .filter(|e| e.role == MessageRole::Assistant && e.status == Some(MessageStatus::Complete))
        .count()
}

fn run(message_id: &str, cwd: &str, worktree: Option<WorktreeSpec>) -> SessionCommandPayload {
    SessionCommandPayload::Run {
        request: RunRequest {
            turn_origin: Default::default(),
            prompt: "Fix login redirect after sign-in".into(),
            harness: Some(HarnessId::Graff),
            model: None,
            reasoning: None,
            model_options: Default::default(),
            cwd: cwd.into(),
            sandbox: SandboxLevel::WorkspaceWrite,
            auto_approve: true,
            attachments: Vec::new(),
            resume: None,
            worktree,
        },
        message_id: message_id.into(),
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn graff_chats_run_and_resume_in_graffs_own_worktree() {
    let tmp = tempfile::tempdir().unwrap();
    let tmp_path = tmp.path().canonicalize().unwrap();
    let harness_trees = tmp_path.join("harness-worktrees");
    unsafe { std::env::set_var("HARNESS_WORKTREES_DIR", &harness_trees) };
    let repo = tmp_path.join("repo");
    let repo_path = init_repo(&repo);

    let seen = Arc::new(Mutex::new(Vec::new()));
    let registry = HarnessRegistry::new();
    registry.register(Arc::new(FakeGraff { seen: seen.clone() }));
    let core = EngineCore::assemble(&tmp_path.join("data"), Arc::new(registry), HarnessId::Graff, None)
        .expect("engine core assembles");
    let client = harness_rpc::memory_client(core.rpc_service());
    client
        .call(
            harness_rpc::methods::MUTATE,
            serde_json::json!({ "op": "createChat", "chatId": CHAT, "deviceId": core.device_id }),
        )
        .await
        .expect("createChat");
    core.workspace.rename_chat(CHAT, "Pre-titled").expect("rename chat");

    let spec = WorktreeSpec {
        repo_path: repo_path.clone(),
        base: "main".into(),
        space_id: None,
        agent_name: None,
    };
    core.doc_host
        .queue_command(CHAT, run("msg-1", &repo_path, Some(spec)))
        .expect("queue first run");
    wait_for(|| completed_turns(&core) == 1, "first turn").await;

    let name = "fix-login-redirect-after-sign-in-1a7188e911beeb31".to_string();
    let tree = GraffWorktree::path_in(&repo_path, &name);
    let first = seen.lock().unwrap()[0].clone();
    assert_eq!(first.cwd, repo_path, "Graff launches from the repo");
    assert_eq!(first.agent_name.as_deref(), Some(name.as_str()), "with its per-chat tree name");
    assert!(!harness_trees.exists(), "the host mints no harness/<name> tree for Graff");

    let chat = core.workspace.chat(CHAT).unwrap().expect("chat row");
    assert_eq!(
        chat.cwd.as_deref(),
        Some(tree.as_str()),
        "the chat moved into Graff's tree"
    );
    assert_eq!(
        chat.branch.as_deref(),
        Some(format!("actual-{name}").as_str())
    );
    let context = chat
        .source_context
        .as_ref()
        .expect("runtime source context");
    assert_eq!(context.cwd, tree);
    assert_eq!(context.repo_root, tree);
    assert_eq!(
        context.branch,
        format!("actual-{name}"),
        "read Git, not the path-derived branch"
    );
    assert_eq!(
        context.head_sha.as_deref(),
        Some(git(&tree, &["rev-parse", "HEAD"]).as_str())
    );
    let identity = core
        .repos
        .checkout_identity(std::path::Path::new(&tree))
        .await
        .unwrap();
    let parent_identity = core.repos.checkout_identity(&repo).await.unwrap();
    assert_eq!(context.checkout_id, identity.id);
    assert_eq!(chat.checkout_id.as_deref(), Some(identity.id.as_str()));
    assert_ne!(
        context.checkout_id, parent_identity.id,
        "never retain the parent PR identity"
    );

    // The composer's next send carries the chat's cwd: the tree itself.
    core.doc_host
        .queue_command(CHAT, run("msg-2", &tree, None))
        .expect("queue second run");
    wait_for(|| completed_turns(&core) == 2, "second turn").await;
    let second = seen.lock().unwrap()[1].clone();
    assert_eq!(second.cwd, tree, "later runs spawn inside the tree");
    assert_eq!(second.agent_name, None);
    assert_eq!(
        second.resume.as_deref(),
        Some("sess-graff"),
        "the session recorded in the tree resumes there"
    );

    let resumed = core.workspace.chat(CHAT).unwrap().unwrap();
    let resumed_context = resumed.source_context.as_ref().unwrap();
    assert_eq!(resumed_context.cwd, context.cwd);
    assert_eq!(resumed_context.repo_root, context.repo_root);
    assert_eq!(resumed_context.branch, context.branch);
    assert_eq!(resumed_context.checkout_id, context.checkout_id);
    assert_eq!(resumed_context.head_sha, context.head_sha);

    // A retry carrying the original directive and a different prompt must keep
    // the existing tree rather than derive another branch from the new task.
    let mut retry = run(
        "msg-3",
        &repo_path,
        Some(WorktreeSpec {
            repo_path: repo_path.clone(),
            base: "main".into(),
            space_id: None,
            agent_name: None,
        }),
    );
    if let SessionCommandPayload::Run { request, .. } = &mut retry {
        request.prompt = "Now test the callback".into();
    }
    core.doc_host.queue_command(CHAT, retry).unwrap();
    wait_for(|| completed_turns(&core) == 3, "retry turn").await;
    let retry = seen.lock().unwrap()[2].clone();
    // Queued directives can carry a stale name. A recorded checkout is the
    // authority for this conversation, not an old name in another request.
    core.doc_host
        .queue_command(
            CHAT,
            run(
                "msg-4",
                &repo_path,
                Some(WorktreeSpec {
                    repo_path: repo_path.clone(),
                    base: "main".into(),
                    space_id: None,
                    agent_name: Some("stale-queued-name".into()),
                }),
            ),
        )
        .unwrap();
    wait_for(|| completed_turns(&core) == 4, "retry with a stale name").await;
    let stale = seen.lock().unwrap()[3].clone();
    core.shutdown().await;
    assert_eq!(retry.agent_name.as_deref(), Some(name.as_str()));
    assert_eq!(retry.cwd, repo_path);
    assert_eq!(
        stale.agent_name.as_deref(),
        Some(name.as_str()),
        "a stale directive must not move an existing conversation"
    );
    assert!(
        !std::path::Path::new(&GraffWorktree::path_in(&repo_path, "stale-queued-name")).exists()
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn unchanged_checkout_keeps_its_complete_source_context() {
    let tmp = tempfile::tempdir().unwrap();
    let repo = tmp.path().canonicalize().unwrap().join("repo");
    let cwd = init_repo(&repo);
    let registry = HarnessRegistry::new();
    registry.register(Arc::new(FakeGraff {
        seen: Arc::new(Mutex::new(Vec::new())),
    }));
    let core = EngineCore::assemble(
        &tmp.path().join("data"),
        Arc::new(registry),
        HarnessId::Graff,
        None,
    )
    .unwrap();
    core.workspace
        .create_chat(CHAT, None, Some(&core.device_id), None, Some(cwd.clone()))
        .unwrap();
    core.workspace.rename_chat(CHAT, "Pre-titled").unwrap();
    core.doc_host
        .queue_command(CHAT, run("msg-local", &cwd, None))
        .unwrap();
    wait_for(|| completed_turns(&core) == 1, "local turn").await;
    let chat = core.workspace.chat(CHAT).unwrap().unwrap();
    let context = chat.source_context.as_ref().unwrap();
    let identity = core.repos.checkout_identity(&repo).await.unwrap();
    assert_eq!(chat.cwd.as_deref(), Some(cwd.as_str()));
    assert_eq!(chat.branch.as_deref(), Some("main"));
    assert_eq!(chat.checkout_id.as_deref(), Some(identity.id.as_str()));
    assert_eq!(context.cwd, cwd);
    assert_eq!(context.repo_root, cwd);
    assert_eq!(context.branch, "main");
    assert_eq!(context.checkout_id, identity.id);
    assert_eq!(
        context.head_sha.as_deref(),
        Some(git(&cwd, &["rev-parse", "HEAD"]).as_str())
    );
    core.shutdown().await;
}
