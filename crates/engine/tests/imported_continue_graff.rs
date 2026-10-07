//! Imported Claude Code / Codex chats continue in graff (#168): the first
//! prompt runs a FRESH graff session seeded with the earlier transcript —
//! the source agent is never re-launched or resumed, even when an older
//! build recorded its native session id, and even if the request or chat
//! row still names the source harness. Once graff reports its own session
//! id, later turns resume it like any graff conversation.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use futures::StreamExt;
use futures::stream::BoxStream;

use harness_adapters::{Harness, HarnessError, RunControls};
use harness_doc::{
    MessagePart, MessageRole, MessageStatus, SessionCommandPayload, SessionMessageEntry,
};
use harness_engine::{EngineCore, HarnessRegistry};
use harness_proto::{
    AgentEvent, ChatConfig, DoneStatus, HarnessId, Model, ReasoningLevel, RunRequest, SandboxLevel,
    SteeringMode,
};

const CHAT: &str = "ext-claude-s1";

type RequestLog = Arc<Mutex<Vec<RunRequest>>>;

/// A fake standing in for graff: records what the run actually received.
struct GraffProbe {
    requests: RequestLog,
    session_id: String,
}

#[async_trait]
impl Harness for GraffProbe {
    fn id(&self) -> HarnessId {
        HarnessId::Graff
    }
    fn display_name(&self) -> &str {
        "GraffProbe"
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
        self.requests.lock().expect("request log").push(request);
        let session_id = self.session_id.clone();
        Ok(futures::stream::iter(vec![
            Ok(AgentEvent::SessionStarted {
                harness: HarnessId::Graff,
                model: "graff-1".into(),
                tools: vec![],
                cwd: "/w/app".into(),
                session_id: session_id.clone(),
                assistant_message_id: "a-1".into(),
            }),
            Ok(AgentEvent::Done {
                status: DoneStatus::Completed,
                result: None,
                error: None,
                session_id: Some(session_id),
            }),
        ])
        .boxed())
    }
}

fn entry(role: MessageRole, text: &str, id: &str) -> SessionMessageEntry {
    SessionMessageEntry {
        id: id.into(),
        role,
        parts: vec![MessagePart::Text {
            id: format!("{id}-p"),
            text: text.into(),
        }],
        created_at: 0,
        device_id: "dev".into(),
        status: Some(MessageStatus::Complete),
        continuation_of: None,
        duration_ms: None,
    }
}

fn run_request(prompt: &str) -> RunRequest {
    RunRequest {
        prompt: prompt.into(),
        // Even a request pinned to the source harness must not reach it.
        harness: Some(HarnessId::ClaudeCode),
        model: None,
        reasoning: None,
        model_options: Default::default(),
        cwd: "/w/app".into(),
        sandbox: SandboxLevel::WorkspaceWrite,
        auto_approve: true,
        attachments: Vec::new(),
        worktree: None,
        resume: None,
    }
}

async fn wait_for<F>(mut predicate: F, what: &str)
where
    F: FnMut() -> bool,
{
    for _ in 0..200 {
        if predicate() {
            return;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    panic!("timed out waiting for {what}");
}

#[tokio::test]
async fn imported_claude_chat_continues_in_graff_seeded_and_never_resumed() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path().join("data");
    let requests: RequestLog = Arc::new(Mutex::new(Vec::new()));
    let registry = HarnessRegistry::new();
    registry.register(Arc::new(GraffProbe {
        requests: requests.clone(),
        session_id: "graff-live-1".into(),
    }));
    let core = EngineCore::assemble(&dir, Arc::new(registry), HarnessId::Mock, None)
        .expect("engine assembles");

    // A chat row the way an older build left it: Claude's config and the
    // native id as the stored harness session.
    core.workspace
        .create_chat(
            CHAT,
            None,
            Some(&core.device_id),
            Some(ChatConfig {
                harness: HarnessId::ClaudeCode,
                model: None,
                reasoning: None,
                model_options: Default::default(),
                sandbox: SandboxLevel::WorkspaceWrite,
            }),
            Some("/w/app".into()),
        )
        .unwrap();
    core.workspace
        .set_chat_harness_session(CHAT, "s1", "/w/app");
    let handle = core.doc_host.open(CHAT).unwrap();
    handle
        .doc()
        .push_message(&entry(MessageRole::User, "make the build faster", "m1"))
        .unwrap();
    handle
        .doc()
        .push_message(&entry(MessageRole::Assistant, "Cached the deps.", "m2"))
        .unwrap();

    // First prompt: forced to graff, fresh session, seeded prompt.
    core.doc_host
        .queue_command(
            CHAT,
            SessionCommandPayload::Run {
                request: run_request("keep going"),
                message_id: "u3".into(),
            },
        )
        .unwrap();
    wait_for(
        || !requests.lock().unwrap().is_empty(),
        "the first graff run",
    )
    .await;
    let first = requests.lock().unwrap()[0].clone();
    assert_eq!(first.resume, None, "the native id is never a graff resume");
    let block = first
        .prompt
        .split("<earlier-conversation>")
        .nth(1)
        .expect("the earlier transcript rides the first prompt");
    assert!(block.contains("User: make the build faster"));
    assert!(block.contains("Assistant: Cached the deps."));
    assert!(
        first
            .prompt
            .ends_with("</earlier-conversation>\n\nkeep going")
    );
    assert!(
        first
            .prompt
            .contains("started in Claude Code and continues here in graff"),
        "{}",
        first.prompt
    );

    // The recorded graff session id now resumes; no re-seeding.
    core.workspace
        .set_chat_harness_session(CHAT, "graff-live-1", "/w/app");
    core.doc_host
        .queue_command(
            CHAT,
            SessionCommandPayload::Run {
                request: run_request("and again"),
                message_id: "u4".into(),
            },
        )
        .unwrap();
    wait_for(|| requests.lock().unwrap().len() >= 2, "the resume run").await;
    let second = requests.lock().unwrap()[1].clone();
    assert_eq!(second.resume.as_deref(), Some("graff-live-1"));
    assert_eq!(second.prompt, "and again", "resumed turns stay unseeded");

    core.shutdown().await;
}
