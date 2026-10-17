use super::*;
use crate::session_store::SessionStore;
use harness_adapters::{Harness, HarnessError, RunControls};
use harness_engine::HarnessRegistry;
use harness_proto::{AgentEvent, DoneStatus, HarnessId, Model, RunRequest};
use std::sync::Mutex;
use tokio::sync::mpsc;

fn connection(
    root: &std::path::Path,
    registry: Arc<HarnessRegistry>,
) -> (Arc<Conn>, mpsc::UnboundedReceiver<Value>) {
    let (mut conn, rx) = Conn::for_test(registry);
    Arc::get_mut(&mut conn).unwrap().sessions = SessionStore::new(root.into());
    (conn, rx)
}

async fn call(conn: &Arc<Conn>, method: &str, params: Value) -> Value {
    let (result, after) = crate::methods::handle(conn, method, params).await;
    let response = result.unwrap_or_else(|e| panic!("{method}: {}", e.message));
    if let Some(after) = after {
        after.await;
    }
    response
}

struct Agent {
    requests: Arc<Mutex<Vec<RunRequest>>>,
}

#[async_trait::async_trait]
impl Harness for Agent {
    fn id(&self) -> HarnessId {
        HarnessId::Mock
    }
    fn display_name(&self) -> &str {
        "Session fixture"
    }
    fn supports_steering(&self) -> bool {
        false
    }
    fn steering_mode(&self) -> harness_proto::SteeringMode {
        harness_proto::SteeringMode::TurnBoundary
    }
    fn reasoning_levels(&self) -> &[harness_proto::ReasoningLevel] {
        &[]
    }
    async fn models(&self) -> Result<Vec<Model>, HarnessError> {
        Ok(Vec::new())
    }
    async fn run(
        &self,
        request: RunRequest,
        _: RunControls,
    ) -> Result<futures::stream::BoxStream<'static, Result<AgentEvent, HarnessError>>, HarnessError>
    {
        self.requests.lock().unwrap().push(request.clone());
        Ok(Box::pin(futures::stream::iter([
            Ok(AgentEvent::SessionStarted {
                harness: HarnessId::Mock,
                model: "fixture".into(),
                tools: Vec::new(),
                cwd: request.cwd,
                session_id: request.resume.unwrap_or("native-fixture".into()),
                assistant_message_id: "assistant".into(),
            }),
            Ok(AgentEvent::TextDelta {
                text: "Saved reply".into(),
            }),
            Ok(AgentEvent::Done {
                status: DoneStatus::Completed,
                error: None,
                result: None,
                session_id: None,
            }),
        ])))
    }
}

fn registry() -> (Arc<HarnessRegistry>, Arc<Mutex<Vec<RunRequest>>>) {
    let requests = Arc::new(Mutex::new(Vec::new()));
    let registry = Arc::new(HarnessRegistry::new());
    registry.register(Arc::new(Agent {
        requests: requests.clone(),
    }));
    (registry, requests)
}

async fn saved(conn: &Arc<Conn>, cwd: &str, prompt: &str) -> String {
    let start = call(
        conn,
        "thread/start",
        json!({ "model": "mock/fixture", "cwd": cwd }),
    )
    .await;
    assert_eq!(start["thread"]["name"], "New session");
    let id = start["thread"]["id"].as_str().unwrap().to_string();
    call(
        conn,
        "turn/start",
        json!({ "threadId": id, "input": [{ "type": "text", "text": prompt }] }),
    )
    .await;
    id
}

#[tokio::test]
async fn resume_after_bridge_restart_restores_name_history_agent_and_native_token() {
    let dir = tempfile::tempdir().unwrap();
    let (registry, requests) = registry();
    let (conn, mut events) = connection(dir.path(), registry.clone());
    let id = saved(&conn, "/project-a", " Fix  the\n session picker ").await;
    let mut named = false;
    while let Ok(event) = events.try_recv() {
        if event["method"] == "thread/name/updated" {
            assert_eq!(event["params"]["threadName"], "Fix the session picker");
            named = true;
        }
    }
    assert!(named);
    drop(conn);
    let (conn, _events) = connection(dir.path(), registry);
    let listing = call(&conn, "thread/list", json!({})).await;
    assert_eq!(listing["data"][0]["id"], id);
    assert_eq!(listing["data"][0]["name"], "Fix the session picker");
    assert_eq!(listing["data"][0]["turns"], json!([]));
    let response = call(
        &conn,
        "thread/resume",
        json!({ "threadId": id, "cwd": "/launch-folder" }),
    )
    .await;
    assert_eq!(response["cwd"], "/project-a");
    assert_eq!(response["model"], "mock/fixture");
    assert_eq!(response["thread"]["name"], "Fix the session picker");
    assert_eq!(
        response["thread"]["turns"][0]["items"][1]["text"],
        "Saved reply"
    );
    assert_eq!(response["thread"]["turns"][0]["status"], "completed");
    call(
        &conn,
        "turn/start",
        json!({ "threadId": id, "input": [{ "type": "text", "text": "Continue" }] }),
    )
    .await;
    let requests = requests.lock().unwrap();
    assert_eq!(requests.len(), 2);
    assert_eq!(requests[0].resume, None);
    assert_eq!(requests[1].resume.as_deref(), Some("native-fixture"));
    assert_eq!(requests[1].cwd, "/project-a");
    assert_eq!(requests[1].harness, Some(HarnessId::Mock));
    assert_eq!(requests[1].prompt, "Continue"); // UI replay is not re-submitted to the agent.
    assert_eq!(
        conn.threads.lock().unwrap()[&id].history.name.as_deref(),
        Some("Fix the session picker")
    );
}

#[tokio::test]
async fn list_filters_searches_and_paginates_saved_sessions() {
    let dir = tempfile::tempdir().unwrap();
    let (registry, _) = registry();
    let (conn, _events) = connection(dir.path(), registry);
    let a = saved(&conn, "/a", "Alpha λ session").await;
    let b = saved(&conn, "/b", "Beta session").await;
    let all = call(&conn, "thread/list", json!({})).await;
    assert_eq!(all["data"].as_array().unwrap().len(), 2);
    let first = call(&conn, "thread/list", json!({ "limit": 1 })).await;
    let second = call(
        &conn,
        "thread/list",
        json!({ "limit": 1, "cursor": first["nextCursor"] }),
    )
    .await;
    assert_ne!(first["data"][0]["id"], second["data"][0]["id"]);
    assert!(second["nextCursor"].is_null());
    assert_eq!(
        call(&conn, "thread/list", json!({ "cwd": ["/a"] })).await["data"][0]["id"],
        a
    );
    assert_eq!(
        call(&conn, "thread/list", json!({ "searchTerm": "BETA" })).await["data"][0]["id"],
        b
    );
    assert_eq!(
        call(&conn, "thread/list", json!({ "archived": true })).await["data"],
        json!([])
    );
    let read = call(
        &conn,
        "thread/read",
        json!({ "threadId": a, "includeTurns": true }),
    )
    .await;
    assert_eq!(read["thread"]["turns"].as_array().unwrap().len(), 1);
}

#[tokio::test]
async fn corrupt_files_and_unknown_ids_do_not_erase_or_replace_the_current_session() {
    let dir = tempfile::tempdir().unwrap();
    let (registry, _) = registry();
    let (conn, _events) = connection(dir.path(), registry.clone());
    let id = saved(&conn, "/a", "Keep this conversation").await;
    std::fs::write(
        dir.path().join(format!("{}.json", uuid::Uuid::new_v4())),
        "broken",
    )
    .unwrap();
    let (fresh, _) = connection(dir.path(), registry);
    assert_eq!(
        call(&fresh, "thread/list", json!({})).await["data"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    for invalid in [
        "../../outside".to_string(),
        uuid::Uuid::new_v4().to_string(),
    ] {
        let (response, _) =
            crate::methods::handle(&conn, "thread/resume", json!({ "threadId": invalid })).await;
        assert!(response.is_err());
    }
    assert!(conn.threads.lock().unwrap().contains_key(&id));
    let (result, _) = crate::methods::handle(
        &fresh,
        "thread/resume",
        json!({ "threadId": id, "model": "graff/other" }),
    )
    .await;
    assert!(result.is_err());
    assert_eq!(fresh.threads.lock().unwrap()[&id].harness, HarnessId::Mock);
}

#[tokio::test]
async fn interrupted_history_is_recovered_without_a_phantom_running_turn() {
    let dir = tempfile::tempdir().unwrap();
    let (registry, _) = registry();
    let (conn, _) = connection(dir.path(), registry.clone());
    let id = saved(&conn, "/a", "Interrupted conversation").await;
    {
        let mut threads = conn.threads.lock().unwrap();
        let thread = threads.get_mut(&id).unwrap();
        thread.history.turns[0]["status"] = "inProgress".into();
        checkpoint(&conn, &id, thread).unwrap();
    }
    let (fresh, _) = connection(dir.path(), registry);
    let response = call(&fresh, "thread/resume", json!({ "threadId": id })).await;
    assert_eq!(response["thread"]["turns"][0]["status"], "interrupted");
    assert!(fresh.threads.lock().unwrap()[&id].turn_id.is_none());
}
