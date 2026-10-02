//! `turn/start`: run one Harness turn and translate its events into Codex items.

use std::collections::HashMap;
use std::sync::Arc;

use futures::StreamExt;
use harness_adapters::{CancellationToken, RunControls};
use harness_proto::{AgentEvent, DoneStatus, RunRequest, SandboxLevel};
use serde_json::{Value, json};
use tokio::sync::{mpsc, oneshot};
use uuid::Uuid;

use crate::wire::{After, Conn, RpcError};

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or_default()
}

fn turn_json(id: &str, status: &str, error: Option<&str>) -> Value {
    json!({
        "id": id,
        "items": [],
        "status": status,
        "error": error.map(|message| json!({ "message": message })),
    })
}

fn sandbox_level(params: &Value) -> SandboxLevel {
    match params
        .pointer("/sandboxPolicy/type")
        .and_then(Value::as_str)
    {
        Some("dangerFullAccess") => SandboxLevel::DangerFullAccess,
        Some("readOnly") => SandboxLevel::ReadOnly,
        _ => SandboxLevel::WorkspaceWrite,
    }
}

pub fn start(conn: &Arc<Conn>, params: Value) -> (Result<Value, RpcError>, After) {
    let Some(thread_id) = params
        .get("threadId")
        .and_then(Value::as_str)
        .map(str::to_owned)
    else {
        return (Err(RpcError::invalid_params("missing threadId")), None);
    };
    let input = params.get("input").cloned().unwrap_or(Value::Null);
    let items = input.as_array().cloned().unwrap_or_default();
    let prompt = items
        .iter()
        .filter(|item| item.get("type").and_then(Value::as_str) == Some("text"))
        .filter_map(|item| item.get("text").and_then(Value::as_str))
        .collect::<Vec<_>>()
        .join("\n");
    let attachments = items
        .iter()
        .filter(|item| item.get("type").and_then(Value::as_str) == Some("localImage"))
        .filter_map(|item| item.get("path").and_then(Value::as_str).map(str::to_owned))
        .collect::<Vec<_>>();

    let token = CancellationToken::new();
    let (harness_id, request) = {
        let mut threads = conn.threads.lock().expect("threads lock");
        let Some(thread) = threads.get_mut(&thread_id) else {
            return (Err(RpcError::invalid_params("unknown threadId")), None);
        };
        thread.interrupt = Some(token.clone());
        // A per-turn model override picks the agent too (`<harness>/<model>`).
        let (harness, model) = match params
            .get("model")
            .and_then(Value::as_str)
            .and_then(crate::methods::split_model)
        {
            Some((harness, model)) => (harness, Some(model)),
            None => (thread.harness, thread.model.clone()),
        };
        thread.harness = harness;
        thread.model = model.clone();
        (
            harness,
            RunRequest {
                prompt,
                harness: Some(harness),
                model,
                reasoning: params
                    .get("effort")
                    .and_then(Value::as_str)
                    .and_then(|e| serde_json::from_value(Value::String(e.to_owned())).ok()),
                model_options: Default::default(),
                cwd: thread.cwd.clone(),
                sandbox: sandbox_level(&params),
                // Approvals are not bridged yet; `never` asks for no prompts.
                auto_approve: params.get("approvalPolicy").and_then(Value::as_str) == Some("never"),
                resume: thread.resume.clone(),
                attachments,
                worktree: None,
            },
        )
    };

    let turn_id = Uuid::new_v4().to_string();
    let response = json!({ "turn": turn_json(&turn_id, "inProgress", None) });
    let conn = conn.clone();
    let after: After = Some(Box::pin(async move {
        run(conn, thread_id, turn_id, harness_id, request, input, token).await;
    }));
    (Ok(response), after)
}

/// One Codex item in flight: its id and the text streamed into it so far.
struct Open {
    id: String,
    text: String,
}

/// A tool call between its call event and its result.
struct Tool {
    item_id: String,
    shape: crate::tools::Shape,
    started: std::time::Instant,
}

struct Turn {
    conn: Arc<Conn>,
    thread_id: String,
    turn_id: String,
    message: Option<Open>,
    reasoning: Option<Open>,
    /// Tool call id → what is on screen for it.
    tools: HashMap<String, Tool>,
    cwd: String,
}

impl Turn {
    fn item_started(&self, item: Value) {
        self.conn.notify(
            "item/started",
            json!({
                "item": item, "threadId": self.thread_id,
                "turnId": self.turn_id, "startedAtMs": now_ms(),
            }),
        );
    }

    fn item_completed(&self, item: Value) {
        self.conn.notify(
            "item/completed",
            json!({
                "item": item, "threadId": self.thread_id,
                "turnId": self.turn_id, "completedAtMs": now_ms(),
            }),
        );
    }

    fn delta(&self, method: &str, item_id: &str, delta: &str, extra: Value) {
        let mut params = json!({
            "threadId": self.thread_id, "turnId": self.turn_id,
            "itemId": item_id, "delta": delta,
        });
        if let (Some(params), Some(extra)) = (params.as_object_mut(), extra.as_object()) {
            params.extend(extra.clone());
        }
        self.conn.notify(method, params);
    }

    fn close_reasoning(&mut self) {
        if let Some(open) = self.reasoning.take() {
            self.item_completed(
                json!({ "type": "reasoning", "id": open.id, "summary": [], "content": [open.text] }),
            );
        }
    }

    fn close_message(&mut self) {
        if let Some(open) = self.message.take() {
            self.item_completed(
                json!({ "type": "agentMessage", "id": open.id, "text": open.text }),
            );
        }
    }

    fn on_event(&mut self, event: AgentEvent) {
        match event {
            AgentEvent::TextDelta { text } => {
                self.close_reasoning();
                let open = self.message.get_or_insert_with(|| Open {
                    id: Uuid::new_v4().to_string(),
                    text: String::new(),
                });
                let (id, fresh) = (open.id.clone(), open.text.is_empty());
                open.text.push_str(&text);
                if fresh {
                    self.item_started(json!({ "type": "agentMessage", "id": id, "text": "" }));
                }
                self.delta("item/agentMessage/delta", &id, &text, json!({}));
            }
            AgentEvent::ReasoningDelta { text } => {
                let open = self.reasoning.get_or_insert_with(|| Open {
                    id: Uuid::new_v4().to_string(),
                    text: String::new(),
                });
                let (id, fresh) = (open.id.clone(), open.text.is_empty());
                open.text.push_str(&text);
                if fresh {
                    self.item_started(
                        json!({ "type": "reasoning", "id": id, "summary": [], "content": [] }),
                    );
                }
                self.delta(
                    "item/reasoning/textDelta",
                    &id,
                    &text,
                    json!({ "contentIndex": 0 }),
                );
            }
            AgentEvent::ToolCall { id, call } => {
                self.close_reasoning();
                self.close_message();
                let shape = crate::tools::shape(&call);
                let item_id = Uuid::new_v4().to_string();
                if let crate::tools::Shape::Command { command, actions } = &shape {
                    self.item_started(crate::tools::command_item(
                        &item_id,
                        command,
                        actions,
                        &self.cwd,
                        "inProgress",
                        None,
                        None,
                        None,
                    ));
                }
                self.tools.insert(
                    id,
                    Tool {
                        item_id,
                        shape,
                        started: std::time::Instant::now(),
                    },
                );
            }
            AgentEvent::ToolResult {
                id,
                is_error,
                output,
                diff,
            } => {
                let Some(tool) = self.tools.remove(&id) else {
                    return;
                };
                let status = if is_error { "failed" } else { "completed" };
                let duration_ms = Some(tool.started.elapsed().as_millis() as i64);
                match tool.shape {
                    crate::tools::Shape::Command { command, actions } => {
                        self.item_completed(crate::tools::command_item(
                            &tool.item_id,
                            &command,
                            &actions,
                            &self.cwd,
                            status,
                            output.as_deref(),
                            Some(i32::from(is_error)),
                            duration_ms,
                        ));
                    }
                    crate::tools::Shape::Edit { path, fallback } => {
                        let changes = crate::tools::finished_changes(diff.as_ref(), fallback);
                        if is_error || changes.is_empty() {
                            // A failed edit has no diff to draw, so show why as a command row.
                            let command = format!("bash -lc 'edit {path}'");
                            let item = crate::tools::command_item(
                                &tool.item_id,
                                &command,
                                &[],
                                &self.cwd,
                                status,
                                output.as_deref(),
                                Some(i32::from(is_error)),
                                duration_ms,
                            );
                            self.item_started(item.clone());
                            self.item_completed(item);
                        } else {
                            let running = crate::tools::file_change_item(
                                &tool.item_id,
                                changes.clone(),
                                "inProgress",
                            );
                            self.item_started(running);
                            self.item_completed(crate::tools::file_change_item(
                                &tool.item_id,
                                changes,
                                status,
                            ));
                        }
                    }
                }
            }
            other => {
                tracing::debug!(event = ?std::mem::discriminant(&other), "event not mapped yet")
            }
        }
    }
}

async fn run(
    conn: Arc<Conn>,
    thread_id: String,
    turn_id: String,
    harness_id: harness_proto::HarnessId,
    request: RunRequest,
    input: Value,
    token: CancellationToken,
) {
    let mut turn = Turn {
        conn: conn.clone(),
        thread_id: thread_id.clone(),
        turn_id: turn_id.clone(),
        message: None,
        reasoning: None,
        tools: HashMap::new(),
        cwd: request.cwd.clone(),
    };
    conn.notify(
        "turn/started",
        json!({ "threadId": thread_id, "turn": turn_json(&turn_id, "inProgress", None) }),
    );
    let user_item =
        json!({ "type": "userMessage", "id": Uuid::new_v4().to_string(), "content": input });
    turn.item_started(user_item.clone());
    turn.item_completed(user_item);

    let (status, error) = drive(&mut turn, harness_id, request, token).await;
    turn.close_reasoning();
    turn.close_message();
    conn.notify(
        "turn/completed",
        json!({ "threadId": thread_id, "turn": turn_json(&turn_id, status, error.as_deref()) }),
    );
    if let Some(thread) = conn
        .threads
        .lock()
        .expect("threads lock")
        .get_mut(&thread_id)
    {
        thread.interrupt = None;
    }
}

async fn drive(
    turn: &mut Turn,
    harness_id: harness_proto::HarnessId,
    request: RunRequest,
    token: CancellationToken,
) -> (&'static str, Option<String>) {
    let harness = match turn.conn.registry.resolve(harness_id) {
        Ok(harness) => harness,
        Err(error) => return ("failed", Some(error.to_string())),
    };
    let (_steer, steering) = mpsc::channel(1);
    let controls = RunControls {
        // Questions are not bridged yet: dropping the sender answers "cancelled".
        request_input: Box::new(|_| {
            let (_tx, rx) = oneshot::channel();
            rx
        }),
        steering,
        interrupt: token,
        origin: None,
    };
    let mut stream = match harness.run(request, controls).await {
        Ok(stream) => stream,
        Err(error) => return ("failed", Some(error.to_string())),
    };
    let mut outcome = ("completed", None);
    while let Some(event) = stream.next().await {
        match event {
            Ok(AgentEvent::SessionStarted { session_id, .. }) => {
                if let Some(thread) = turn
                    .conn
                    .threads
                    .lock()
                    .expect("threads lock")
                    .get_mut(&turn.thread_id)
                {
                    thread.resume = Some(session_id);
                }
            }
            Ok(AgentEvent::Done { status, error, .. }) => {
                outcome = match status {
                    DoneStatus::Completed => ("completed", None),
                    DoneStatus::Interrupted | DoneStatus::Cancelled => ("interrupted", None),
                    DoneStatus::Errored | DoneStatus::Disconnected => (
                        "failed",
                        Some(error.unwrap_or_else(|| format!("{status:?}"))),
                    ),
                };
                break;
            }
            Ok(event) => turn.on_event(event),
            Err(error) => {
                outcome = ("failed", Some(error.to_string()));
                break;
            }
        }
    }
    outcome
}
