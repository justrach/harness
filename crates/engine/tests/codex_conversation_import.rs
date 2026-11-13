//! A local Codex link imports a read-only snapshot and continues only in graff.
//! Keep this in a single-test binary because engine assembly reads CODEX_HOME.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use futures::StreamExt;
use futures::stream::BoxStream;
use harness_adapters::{Harness, HarnessError, RunControls};
use harness_doc::{MessagePart, SessionCommandPayload};
use harness_engine::{EngineCore, HarnessRegistry};
use harness_proto::{
    AgentEvent, DoneStatus, HarnessId, Model, ReasoningLevel, RunRequest, SandboxLevel,
    SteeringMode,
};
use serde_json::json;

const THREAD_ID: &str = "12345678-1234-4123-8123-123456789abc";
const GRAFF_ID: &str = "graff-imported-codex";

struct GraffProbe(Arc<Mutex<Vec<RunRequest>>>);

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
        let cwd = request.cwd.clone();
        self.0.lock().unwrap().push(request);
        Ok(futures::stream::iter(vec![
            Ok(AgentEvent::SessionStarted {
                harness: HarnessId::Graff,
                model: "graff-default".into(),
                tools: vec![],
                cwd,
                session_id: GRAFF_ID.into(),
                assistant_message_id: "graff-reply".into(),
            }),
            Ok(AgentEvent::Done {
                status: DoneStatus::Completed,
                result: None,
                error: None,
                session_id: Some(GRAFF_ID.into()),
            }),
        ])
        .boxed())
    }
}

async fn wait_for(mut ready: impl FnMut() -> bool) {
    for _ in 0..200 {
        if ready() {
            return;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    panic!("timed out waiting for imported Codex continuation");
}

fn request(cwd: &str, prompt: &str) -> RunRequest {
    RunRequest {
        prompt: prompt.into(),
        turn_origin: Default::default(),
        // Even callers that name the source agent must reach graff.
        harness: Some(HarnessId::Codex),
        model: Some("codex-source-model".into()),
        reasoning: None,
        model_options: Default::default(),
        cwd: cwd.into(),
        sandbox: SandboxLevel::WorkspaceWrite,
        auto_approve: true,
        attachments: vec![],
        worktree: None,
        resume: None,
    }
}

#[tokio::test]
async fn codex_link_preview_import_reopen_and_graff_continuation() {
    let dir = tempfile::tempdir().unwrap();
    let codex_home = dir.path().join("codex");
    let archived = codex_home.join("archived_sessions");
    std::fs::create_dir_all(&archived).unwrap();
    let original_cwd = dir.path().join("removed-codex-worktree");
    let selected_cwd = dir.path().join("selected-project");
    let other_cwd = dir.path().join("different-project");
    std::fs::create_dir_all(&selected_cwd).unwrap();
    std::fs::create_dir_all(&other_cwd).unwrap();
    let source = archived.join(format!("rollout-2026-10-29-{THREAD_ID}.jsonl"));
    let rows = [
        json!({"type":"session_meta","payload":{"id":THREAD_ID,"cwd":original_cwd,"history_mode":"paginated","source":"vscode"}}),
        json!({"type":"response_item","ordinal":0,"payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"Source-only instructions"}]}}),
        json!({"type":"response_item","ordinal":1,"timestamp":"2026-10-29T10:00:00Z","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Add a retry for timeouts"},{"type":"input_image","image_url":"data:image/png;base64,fixture"}]}}),
        json!({"type":"response_item","ordinal":2,"timestamp":"2026-10-29T10:00:01Z","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Retry implemented; verification remains."}]}}),
    ];
    let body = format!(
        "{}\n{{\"type\":",
        rows.iter()
            .map(ToString::to_string)
            .collect::<Vec<_>>()
            .join("\n")
    );
    std::fs::write(&source, &body).unwrap();
    // SAFETY: this binary contains one test; environment is set before assembly.
    unsafe {
        std::env::set_var("CODEX_HOME", &codex_home);
        std::env::set_var("CLAUDE_CONFIG_DIR", dir.path().join("claude"));
    }
    let requests = Arc::new(Mutex::new(Vec::new()));
    let registry = HarnessRegistry::new();
    registry.register(Arc::new(GraffProbe(requests.clone())));
    let core = EngineCore::assemble(
        &dir.path().join("data"),
        Arc::new(registry),
        HarnessId::Mock,
        None,
    )
    .unwrap();
    let client = harness_rpc::memory_client(core.rpc_service());
    let reference = format!("codex://threads/{THREAD_ID}?view=review#latest");
    let chat_id = format!("ext-codex-{THREAD_ID}");

    let invalid = client
        .call(
            harness_rpc::methods::CODEX_CONVERSATION_PREVIEW,
            json!({"reference": format!("https://example.com/{THREAD_ID}")}),
        )
        .await;
    assert!(invalid.is_err());
    let preview = client
        .call(
            harness_rpc::methods::CODEX_CONVERSATION_PREVIEW,
            json!({"reference":reference}),
        )
        .await
        .unwrap();
    assert_eq!(preview["id"], THREAD_ID);
    assert_eq!(preview["title"], "Add a retry for timeouts");
    assert_eq!(preview["messageCount"], 2);
    assert_eq!(preview["archived"], true);
    assert_eq!(preview["cwdAvailable"], false);
    assert_eq!(preview["alreadyImported"], false);
    assert!(preview["warnings"].as_array().unwrap().len() >= 2);
    assert!(
        core.workspace.chat(&chat_id).unwrap().is_none(),
        "preview creates no chat"
    );
    assert!(
        requests.lock().unwrap().is_empty(),
        "preview starts no agent"
    );

    let unavailable = client
        .call(
            harness_rpc::methods::CODEX_CONVERSATION_IMPORT,
            json!({"reference":reference}),
        )
        .await;
    assert!(unavailable.is_err(), "missing source cwd requires a folder");
    let relative = client
        .call(
            harness_rpc::methods::CODEX_CONVERSATION_IMPORT,
            json!({"reference":reference,"cwd":"."}),
        )
        .await;
    assert!(
        relative.is_err(),
        "relative paths must not depend on engine cwd"
    );
    let imported = client
        .call(
            harness_rpc::methods::CODEX_CONVERSATION_IMPORT,
            json!({"reference":reference,"cwd":selected_cwd}),
        )
        .await
        .unwrap();
    assert_eq!(imported["chatId"], chat_id);
    assert_eq!(imported["alreadyImported"], false);
    let row = core.workspace.chat(&chat_id).unwrap().unwrap();
    assert_eq!(row.cwd.as_deref(), selected_cwd.to_str());
    assert_eq!(row.config.unwrap().harness, HarnessId::Graff);
    assert!(row.harness_session_id.is_none());
    assert!(
        requests.lock().unwrap().is_empty(),
        "import starts no agent"
    );
    assert_eq!(
        std::fs::read_to_string(&source).unwrap(),
        body,
        "source stays read-only"
    );

    let reopened = client
        .call(
            harness_rpc::methods::CODEX_CONVERSATION_IMPORT,
            json!({"reference":reference}),
        )
        .await
        .unwrap();
    assert_eq!(reopened["chatId"], chat_id);
    assert_eq!(reopened["alreadyImported"], true);
    let retargeted = client
        .call(
            harness_rpc::methods::CODEX_CONVERSATION_IMPORT,
            json!({"reference":reference,"cwd":other_cwd}),
        )
        .await;
    assert!(
        retargeted.is_err(),
        "reopening cannot silently retarget the chat"
    );

    // A prior import remains usable after Codex's source file is removed.
    std::fs::remove_file(&source).unwrap();
    let preview_again = client
        .call(
            harness_rpc::methods::CODEX_CONVERSATION_PREVIEW,
            json!({"reference":reference}),
        )
        .await
        .unwrap();
    assert_eq!(preview_again["alreadyImported"], true);
    assert_eq!(preview_again["chatId"], chat_id);
    assert_eq!(preview_again["cwdAvailable"], true);
    let handle = core.doc_host.open(&chat_id).unwrap();
    let history = handle.doc().read_entries().unwrap();
    assert_eq!(history.len(), 2);
    assert!(
        matches!(&history[0].parts[0], MessagePart::Text { text, .. } if text == "Add a retry for timeouts")
    );

    core.doc_host
        .queue_command(
            &chat_id,
            SessionCommandPayload::Run {
                request: request(
                    selected_cwd.to_str().unwrap(),
                    "Run the remaining verification",
                ),
                message_id: "follow-up-1".into(),
            },
        )
        .unwrap();
    wait_for(|| {
        core.workspace
            .chat(&chat_id)
            .unwrap()
            .unwrap()
            .harness_session_id
            .as_deref()
            == Some(GRAFF_ID)
    })
    .await;
    let first = requests.lock().unwrap()[0].clone();
    assert!(first.resume.is_none(), "Codex native IDs never resume");
    assert!(first.model.is_none(), "source model IDs do not reach graff");
    assert!(
        first
            .prompt
            .contains("started in Codex and continues here in graff")
    );
    assert!(first.prompt.contains("User: Add a retry for timeouts"));
    assert!(
        first
            .prompt
            .contains("Retry implemented; verification remains.")
    );
    assert!(!first.prompt.contains("Source-only instructions"));
    assert!(!first.prompt.contains("data:image"));
    assert!(
        first
            .prompt
            .ends_with("</earlier-conversation>\n\nRun the remaining verification")
    );

    core.doc_host
        .queue_command(
            &chat_id,
            SessionCommandPayload::Run {
                request: request(selected_cwd.to_str().unwrap(), "Keep going"),
                message_id: "follow-up-2".into(),
            },
        )
        .unwrap();
    wait_for(|| requests.lock().unwrap().len() == 2).await;
    let second = requests.lock().unwrap()[1].clone();
    assert_eq!(second.resume.as_deref(), Some(GRAFF_ID));
    assert_eq!(second.prompt, "Keep going");
    core.shutdown().await;
}
