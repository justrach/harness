//! Request handlers: Codex app-server methods answered from Harness.
//!
//! Only the methods the TUI needs to boot and run a text turn are implemented;
//! anything else answers `-32601` and is logged, so the log is the work list.

use std::sync::Arc;

use harness_engine::HarnessRegistry;
use harness_proto::HarnessId;
use serde_json::{Value, json};
use uuid::Uuid;

use crate::wire::{After, Conn, RpcError, ThreadState};

type Reply = (Result<Value, RpcError>, After);

fn ok(value: Value) -> Reply {
    (Ok(value), None)
}

fn err(error: RpcError) -> Reply {
    (Err(error), None)
}

pub async fn handle(conn: &std::sync::Arc<Conn>, method: &str, params: Value) -> Reply {
    match method {
        "initialize" => ok(json!({
            // The TUI warns when the server's version differs from its own, so
            // report the version the bundled Codex source builds as.
            "userAgent": format!("harness-tui-bridge/{}", codex_compat_version()),
            "codexHome": codex_home(),
            "platformFamily": std::env::consts::FAMILY,
            "platformOs": std::env::consts::OS,
        })),
        // No OpenAI account: each agent owns its own sign-in in Harness.
        "account/read" => ok(json!({ "account": null, "requiresOpenaiAuth": false })),
        "configRequirements/read" => ok(json!({ "requirements": null })),
        "collaborationMode/list" => ok(json!({ "data": [] })),
        // Codex-side config, hooks, skills and plugins have no Harness counterpart yet.
        "config/read" => ok(json!({ "config": crate::config::read(), "origins": {} })),
        "config/batchWrite" => match crate::config::batch_write(&params) {
            Ok(response) => ok(response),
            Err(error) => err(error),
        },
        "thread/settings/update" => thread_settings_update(conn, &params),
        "hooks/list" | "skills/list" => ok(json!({ "data": [] })),
        "plugin/list" => ok(json!({ "marketplaces": [] })),
        // Session history is not bridged yet; every thread is new.
        "thread/list" => ok(json!({ "data": [], "nextCursor": null, "backwardsCursor": null })),
        "thread/loaded/list" => ok(json!({ "data": loaded_threads(conn), "nextCursor": null })),
        "model/list" => ok(json!({ "data": crate::models::list(&conn.registry).await, "nextCursor": null })),
        "thread/start" => thread_start(conn, params).await,
        "thread/read" => thread_read(conn, params),
        "thread/turns/list" => {
            ok(json!({ "data": [], "nextCursor": null, "backwardsCursor": null }))
        }
        "turn/start" => crate::turn::start(conn, params),
        "turn/steer" => crate::turn::steer(conn, params),
        "turn/interrupt" => turn_interrupt(conn, params),
        other => err(RpcError::method_not_found(other)),
    }
}

/// Source builds of `codex-rs` stamp `0.0.0`; override for a release build.
fn codex_compat_version() -> String {
    std::env::var("HARNESS_TUI_CODEX_VERSION").unwrap_or_else(|_| "0.0.0".into())
}

fn codex_home() -> String {
    crate::config::codex_home().display().to_string()
}

/// A model picked in the TUI applies to the thread's next turn.
fn thread_settings_update(conn: &std::sync::Arc<Conn>, params: &Value) -> Reply {
    let Some(thread_id) = params.get("threadId").and_then(Value::as_str) else {
        return err(RpcError::invalid_params("missing threadId"));
    };
    let mut threads = conn.threads.lock().expect("threads lock");
    let Some(thread) = threads.get_mut(thread_id) else {
        return err(RpcError::invalid_params("unknown threadId"));
    };
    if let Some((harness, model)) = params
        .get("model")
        .and_then(Value::as_str)
        .and_then(split_model)
    {
        thread.harness = harness;
        thread.model = Some(model);
    }
    if let Some(cwd) = params.get("cwd").and_then(Value::as_str) {
        thread.cwd = cwd.to_owned();
    }
    ok(json!({}))
}

/// A Codex model id is `<harness>/<model>`, so one picker spans every agent.
pub fn qualified(harness: HarnessId, model: &str) -> String {
    format!("{}/{model}", harness_slug(harness))
}

pub fn harness_slug(harness: HarnessId) -> String {
    serde_json::to_value(harness)
        .ok()
        .and_then(|v| v.as_str().map(str::to_owned))
        .unwrap_or_default()
}

pub fn split_model(qualified: &str) -> Option<(HarnessId, String)> {
    let (slug, model) = qualified.split_once('/')?;
    let harness = serde_json::from_value(Value::String(slug.to_owned())).ok()?;
    Some((harness, model.to_owned()))
}

pub async fn harness_ids(registry: &Arc<HarnessRegistry>) -> Vec<HarnessId> {
    let registry = registry.clone();
    let mut ids = tokio::task::spawn_blocking(move || registry.enabled_set())
        .await
        .unwrap_or_default();
    ids.retain(|id| *id != HarnessId::Mock);
    if std::env::var_os("HARNESS_TUI_MOCK").is_some() {
        ids.push(HarnessId::Mock);
    }
    ids
}

fn now_secs() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or_default()
}

fn thread_json(id: &str, cwd: &str, model: Option<&str>) -> Value {
    json!({
        "id": id,
        "sessionId": id,
        "cliVersion": env!("CARGO_PKG_VERSION"),
        "createdAt": now_secs(),
        "updatedAt": now_secs(),
        "cwd": cwd,
        "ephemeral": false,
        "model": model,
        "modelProvider": "harness",
        "preview": "",
        "projectId": null,
        "source": "appServer",
        "status": { "type": "idle" },
        "turns": [],
    })
}

async fn thread_start(conn: &std::sync::Arc<Conn>, params: Value) -> Reply {
    let cwd = params
        .get("cwd")
        .and_then(Value::as_str)
        .map(str::to_owned)
        .or_else(|| std::env::current_dir().ok().map(|p| p.display().to_string()))
        .unwrap_or_else(|| "/".into());
    let requested = params.get("model").and_then(Value::as_str);
    tracing::info!(?requested, "thread/start model");
    let (harness, model) = match requested.and_then(split_model) {
        Some((harness, model)) => (harness, Some(model)),
        // The TUI sends no model on a fresh thread and expects the server to
        // pick one, so use the first entry of the same list `model/list` serves.
        None => {
            let first = crate::models::list(&conn.registry).await.into_iter().next();
            match first
                .as_ref()
                .and_then(|m| m.get("model"))
                .and_then(Value::as_str)
                .and_then(split_model)
            {
                Some((harness, model)) => (harness, Some(model)),
                None => (HarnessId::Graff, None),
            }
        }
    };
    let id = Uuid::new_v4().to_string();
    let shown_model = model.as_ref().map(|m| qualified(harness, m));
    let thread = thread_json(&id, &cwd, shown_model.as_deref());
    conn.threads.lock().expect("threads lock").insert(
        id.clone(),
        ThreadState {
            cwd: cwd.clone(),
            harness,
            model: model.clone(),
            resume: None,
            interrupt: None,
            turn_id: None,
            steer: None,
            steers: Default::default(),
            steerable: false,
        },
    );
    let response = json!({
        "thread": thread.clone(),
        "model": shown_model.clone().unwrap_or_default(),
        "modelProvider": "harness",
        "cwd": cwd,
        "approvalPolicy": "on-request",
        "approvalsReviewer": "user",
        "sandbox": { "type": "workspaceWrite" },
    });
    let conn = conn.clone();
    let after: After = Some(Box::pin(async move {
        conn.notify("thread/started", json!({ "thread": thread }));
    }));
    (Ok(response), after)
}

fn thread_read(conn: &std::sync::Arc<Conn>, params: Value) -> Reply {
    let Some(id) = params.get("threadId").and_then(Value::as_str) else {
        return err(RpcError::invalid_params("missing threadId"));
    };
    let threads = conn.threads.lock().expect("threads lock");
    let Some(thread) = threads.get(id) else {
        return err(RpcError::invalid_params("unknown threadId"));
    };
    let model = thread.model.as_ref().map(|m| qualified(thread.harness, m));
    ok(json!({ "thread": thread_json(id, &thread.cwd, model.as_deref()) }))
}

fn loaded_threads(conn: &std::sync::Arc<Conn>) -> Vec<String> {
    conn.threads.lock().expect("threads lock").keys().cloned().collect()
}

fn turn_interrupt(conn: &std::sync::Arc<Conn>, params: Value) -> Reply {
    let Some(thread_id) = params.get("threadId").and_then(Value::as_str) else {
        return err(RpcError::invalid_params("missing threadId"));
    };
    if let Some(thread) = conn.threads.lock().expect("threads lock").get(thread_id)
        && let Some(token) = &thread.interrupt
    {
        token.cancel();
    }
    ok(json!({}))
}
