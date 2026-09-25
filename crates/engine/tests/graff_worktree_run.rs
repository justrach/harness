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
use harness_proto::graff_worktree::{GraffWorktree, name_for_chat};
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
                std::fs::create_dir_all(&tree).unwrap();
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
            prompt: "work in your own tree".into(),
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
    std::fs::create_dir_all(&repo).unwrap();
    let repo_path = repo.to_string_lossy().to_string();

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

    let name = name_for_chat(CHAT);
    let tree = GraffWorktree::path_in(&repo_path, &name);
    let first = seen.lock().unwrap()[0].clone();
    assert_eq!(first.cwd, repo_path, "Graff launches from the repo");
    assert_eq!(first.agent_name.as_deref(), Some(name.as_str()), "with its per-chat tree name");
    assert!(!harness_trees.exists(), "the host mints no harness/<name> tree for Graff");

    let chat = core.workspace.chat(CHAT).unwrap().expect("chat row");
    assert_eq!(chat.cwd.as_deref(), Some(tree.as_str()), "the chat moved into Graff's tree");
    assert_eq!(chat.branch.as_deref(), Some(format!("worktree-{name}").as_str()));

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

    core.shutdown().await;
}
