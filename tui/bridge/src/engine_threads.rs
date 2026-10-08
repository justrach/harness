//! Engine-mode request handlers: Codex thread and turn methods answered
//! from Harness chats (see `engine.rs`). Thread ids are chat ids.

use std::sync::Arc;

use harness_doc::{MessagePart, MessageRole, SessionCommandPayload, SessionMessageEntry};
use harness_proto::{
    Chat, ChatConfig, HarnessId, RunRequest, SandboxLevel, Session, SessionStatus,
};
use serde_json::{Value, json};
use uuid::Uuid;

use crate::engine::Engine;
use crate::methods::{pick_model, qualified, split_model};
use crate::mirror;
use crate::wire::{After, Conn, RpcError, ThreadState};

type Reply = (Result<Value, RpcError>, After);

fn ok(value: Value) -> Reply {
    (Ok(value), None)
}

fn fail(message: impl Into<String>) -> Reply {
    (Err(RpcError::internal(message)), None)
}

fn invalid(message: impl Into<String>) -> Reply {
    (Err(RpcError::invalid_params(message)), None)
}

/// Requests engine mode answers; everything else keeps its standalone
/// handler (config, models, skills...).
pub async fn handle(
    conn: &Arc<Conn>,
    engine: &Arc<Engine>,
    method: &str,
    params: &Value,
) -> Option<Reply> {
    Some(match method {
        "thread/list" => thread_list(engine, params).await,
        "thread/start" => thread_start(conn, engine, params).await,
        "thread/resume" => thread_resume(conn, engine, params).await,
        "thread/read" => thread_read(engine, params).await,
        "thread/turns/list" => thread_turns_list(engine, params).await,
        "thread/name/set" => thread_set_name(engine, params).await,
        "thread/archive" => thread_set_archived(engine, params, true).await,
        "thread/unarchive" => thread_set_archived(engine, params, false).await,
        "thread/unsubscribe" => {
            if let Some(id) = params.get("threadId").and_then(Value::as_str) {
                mirror::stop(conn, id);
            }
            ok(json!({}))
        }
        "thread/settings/update" => thread_settings_update(conn, engine, params).await,
        "turn/start" => turn_start(conn, engine, params),
        "turn/steer" => turn_steer(conn, engine, params).await,
        "turn/interrupt" => turn_interrupt(conn, engine, params).await,
        _ => return None,
    })
}

// ---- reads ---------------------------------------------------------------

fn secs(at: chrono::DateTime<chrono::Utc>) -> i64 {
    at.timestamp()
}

fn chat_cwd(chat: &Chat, spaces: &[harness_proto::Space]) -> String {
    chat.cwd
        .clone()
        .or_else(|| {
            chat.space_id
                .as_deref()
                .and_then(|id| spaces.iter().find(|s| s.id == id))
                .map(|s| s.path.clone())
        })
        .unwrap_or_else(|| "/".into())
}

fn chat_model(chat: &Chat) -> Option<String> {
    let config = chat.config.as_ref()?;
    Some(qualified(
        config.harness,
        config.model.as_deref().unwrap_or("default"),
    ))
}

fn thread_status(chat: &Chat, sessions: &[Session]) -> Value {
    let row = sessions
        .iter()
        .filter(|s| s.chat_id == chat.id)
        .max_by_key(|s| s.updated_at);
    match row.map(|s| s.status) {
        Some(SessionStatus::Working) => json!({ "type": "active", "activeFlags": [] }),
        Some(SessionStatus::AwaitingInput) => {
            json!({ "type": "active", "activeFlags": ["waitingOnUserInput"] })
        }
        Some(SessionStatus::Errored) => json!({ "type": "systemError" }),
        _ => json!({ "type": "idle" }),
    }
}

fn thread_json(chat: &Chat, cwd: &str, status: Value, turns: Vec<Value>) -> Value {
    let updated = chat.last_message_at.unwrap_or(chat.created_at);
    json!({
        "id": chat.id,
        "sessionId": chat.id,
        "cliVersion": env!("CARGO_PKG_VERSION"),
        "createdAt": secs(chat.created_at),
        "updatedAt": secs(updated),
        "cwd": cwd,
        "ephemeral": false,
        "model": chat_model(chat),
        "modelProvider": "harness",
        "name": chat.title,
        "preview": chat.last_message_preview.clone().or_else(|| chat.title.clone()).unwrap_or_default(),
        "projectId": null,
        "source": "appServer",
        "status": status,
        "turns": turns,
    })
}

async fn find_chat(engine: &Engine, id: &str) -> Result<Chat, RpcError> {
    let chats = engine
        .client
        .chats()
        .await
        .map_err(|e| RpcError::internal(e.to_string()))?;
    chats
        .into_iter()
        .find(|c| c.id == id)
        .ok_or_else(|| RpcError::invalid_params("unknown threadId"))
}

async fn thread_list(engine: &Engine, params: &Value) -> Reply {
    let (chats, sessions, spaces) = match tokio::try_join!(
        engine.client.chats(),
        engine.client.sessions(),
        engine.client.spaces()
    ) {
        Ok(all) => all,
        Err(error) => return fail(error.to_string()),
    };
    let archived = params
        .get("archived")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let cwd = params.get("cwd").and_then(Value::as_str);
    let mut chats: Vec<Chat> = chats
        .into_iter()
        .filter(|c| c.archived == archived)
        // Subagent chats belong to their parent's transcript.
        .filter(|c| c.parent_chat_id.is_none())
        .filter(|c| cwd.is_none_or(|cwd| chat_cwd(c, &spaces) == cwd))
        .collect();
    chats.sort_by_key(|c| std::cmp::Reverse(c.last_message_at.unwrap_or(c.created_at)));
    if let Some(limit) = params.get("limit").and_then(Value::as_u64) {
        chats.truncate(limit as usize);
    }
    let data: Vec<Value> = chats
        .iter()
        .map(|c| {
            thread_json(
                c,
                &chat_cwd(c, &spaces),
                thread_status(c, &sessions),
                Vec::new(),
            )
        })
        .collect();
    ok(json!({ "data": data, "nextCursor": null, "backwardsCursor": null }))
}

async fn thread_read(engine: &Engine, params: &Value) -> Reply {
    let Some(id) = params.get("threadId").and_then(Value::as_str) else {
        return invalid("missing threadId");
    };
    let chat = match find_chat(engine, id).await {
        Ok(chat) => chat,
        Err(error) => return (Err(error), None),
    };
    let include = params
        .get("includeTurns")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let (sessions, spaces) =
        match tokio::try_join!(engine.client.sessions(), engine.client.spaces()) {
            Ok(all) => all,
            Err(error) => return fail(error.to_string()),
        };
    let cwd = chat_cwd(&chat, &spaces);
    let turns = if include {
        match engine.client.transcript(id).await {
            Ok(entries) => turns_from(&entries, &cwd),
            Err(error) => return fail(error.to_string()),
        }
    } else {
        Vec::new()
    };
    ok(json!({ "thread": thread_json(&chat, &cwd, thread_status(&chat, &sessions), turns) }))
}

async fn thread_turns_list(engine: &Engine, params: &Value) -> Reply {
    let Some(id) = params.get("threadId").and_then(Value::as_str) else {
        return invalid("missing threadId");
    };
    let entries = match engine.client.transcript(id).await {
        Ok(entries) => entries,
        Err(error) => return fail(error.to_string()),
    };
    let mut turns = turns_from(&entries, "/");
    if params.get("sortDirection").and_then(Value::as_str) == Some("desc") {
        turns.reverse();
    }
    ok(json!({ "data": turns, "nextCursor": null, "backwardsCursor": null }))
}

/// The transcript as Codex turns: each user message opens a turn, and the
/// agent's text, thinking and tool calls after it are its items.
pub fn turns_from(entries: &[SessionMessageEntry], cwd: &str) -> Vec<Value> {
    let mut turns: Vec<Value> = Vec::new();
    let mut items: Vec<Value> = Vec::new();
    let mut turn_id: Option<String> = None;
    let mut started: Option<i64> = None;
    let flush = |turns: &mut Vec<Value>,
                 items: &mut Vec<Value>,
                 id: Option<String>,
                 started: Option<i64>| {
        if items.is_empty() {
            return;
        }
        turns.push(json!({
            "id": id.unwrap_or_else(|| Uuid::new_v4().to_string()),
            "items": std::mem::take(items),
            "itemsView": "full",
            "status": "completed",
            "error": null,
            "startedAt": started.map(|ms| ms / 1000),
            "completedAt": null,
            "durationMs": null,
        }));
    };
    for entry in entries {
        if entry.role == MessageRole::User {
            flush(&mut turns, &mut items, turn_id.take(), started.take());
            turn_id = Some(entry.id.clone());
            started = Some(entry.created_at);
            items.push(json!({
                "type": "userMessage",
                "id": entry.id,
                "clientId": null,
                "content": mirror::user_content(&entry.parts),
            }));
            continue;
        }
        for part in &entry.parts {
            match part {
                MessagePart::Text { id, text } if !text.is_empty() => {
                    items.push(json!({ "type": "agentMessage", "id": id, "text": text }));
                }
                MessagePart::Reasoning { id, text } if !text.is_empty() => {
                    items.push(
                        json!({ "type": "reasoning", "id": id, "summary": [], "content": [text] }),
                    );
                }
                MessagePart::Tool {
                    id,
                    call,
                    is_error,
                    output,
                    diff,
                    ..
                } => {
                    let status = if *is_error { "failed" } else { "completed" };
                    match crate::tools::shape(call) {
                        crate::tools::Shape::Command { command, actions } => {
                            items.push(crate::tools::command_item(
                                id,
                                &command,
                                &actions,
                                cwd,
                                status,
                                output.as_deref(),
                                Some(i32::from(*is_error)),
                                None,
                            ));
                        }
                        crate::tools::Shape::Edit { fallback, .. } => {
                            let changes = crate::tools::finished_changes(diff.as_ref(), fallback);
                            items.push(crate::tools::file_change_item(id, changes, status));
                        }
                    }
                }
                _ => {}
            }
        }
    }
    flush(&mut turns, &mut items, turn_id, started);
    turns
}

// ---- thread writes -------------------------------------------------------

async fn thread_start(conn: &Arc<Conn>, engine: &Arc<Engine>, params: &Value) -> Reply {
    let cwd = params
        .get("cwd")
        .and_then(Value::as_str)
        .map(str::to_owned)
        .or_else(|| {
            std::env::current_dir()
                .ok()
                .map(|p| p.display().to_string())
        })
        .unwrap_or_else(|| "/".into());
    let (harness, model) = pick_model(conn, params.get("model").and_then(Value::as_str)).await;
    // A project the desktop knows on this device files the chat under it.
    let space_id = engine.client.spaces().await.ok().and_then(|spaces| {
        spaces
            .into_iter()
            .find(|s| s.device_id == engine.device_id && s.path == cwd)
            .map(|s| s.id)
    });
    let chat_id = Uuid::new_v4().to_string();
    let config = ChatConfig {
        harness,
        model: model.clone(),
        reasoning: None,
        model_options: Default::default(),
        sandbox: SandboxLevel::WorkspaceWrite,
    };
    let mut mutate = json!({
        "op": "createChat",
        "chatId": chat_id,
        "deviceId": engine.device_id,
        "config": config,
        "cwd": cwd,
    });
    if let Some(space_id) = &space_id {
        mutate["spaceId"] = json!(space_id);
    }
    if let Err(error) = engine.client.mutate(mutate).await {
        return fail(error.to_string());
    }
    conn.threads.lock().expect("threads lock").insert(
        chat_id.clone(),
        ThreadState::new(cwd.clone(), harness, model.clone()),
    );
    mirror::start(conn, engine.clone(), chat_id.clone(), cwd.clone());
    let shown_model = model.as_ref().map(|m| qualified(harness, m));
    let thread = json!({
        "id": chat_id,
        "sessionId": chat_id,
        "cliVersion": env!("CARGO_PKG_VERSION"),
        "createdAt": chrono::Utc::now().timestamp(),
        "updatedAt": chrono::Utc::now().timestamp(),
        "cwd": cwd,
        "ephemeral": false,
        "model": shown_model,
        "modelProvider": "harness",
        "preview": "",
        "projectId": null,
        "source": "appServer",
        "status": { "type": "idle" },
        "turns": [],
    });
    let response = thread_response(thread.clone(), shown_model.unwrap_or_default(), &cwd);
    let conn = conn.clone();
    let after: After = Some(Box::pin(async move {
        conn.notify("thread/started", json!({ "thread": thread }));
    }));
    (Ok(response), after)
}

fn thread_response(thread: Value, model: String, cwd: &str) -> Value {
    json!({
        "thread": thread,
        "model": model,
        "modelProvider": "harness",
        "cwd": cwd,
        "approvalPolicy": "on-request",
        "approvalsReviewer": "user",
        "sandbox": { "type": "workspaceWrite" },
    })
}

async fn thread_resume(conn: &Arc<Conn>, engine: &Arc<Engine>, params: &Value) -> Reply {
    let Some(id) = params.get("threadId").and_then(Value::as_str) else {
        return invalid("missing threadId");
    };
    let chat = match find_chat(engine, id).await {
        Ok(chat) => chat,
        Err(error) => return (Err(error), None),
    };
    let (sessions, spaces, entries) = match tokio::try_join!(
        engine.client.sessions(),
        engine.client.spaces(),
        engine.client.transcript(id)
    ) {
        Ok(all) => all,
        Err(error) => return fail(error.to_string()),
    };
    let cwd = chat_cwd(&chat, &spaces);
    let (harness, model) = match &chat.config {
        Some(config) => (config.harness, config.model.clone()),
        None => (HarnessId::Graff, None),
    };
    let turns = turns_from(&entries, &cwd);
    conn.threads
        .lock()
        .expect("threads lock")
        .entry(chat.id.clone())
        .or_insert_with(|| ThreadState::new(cwd.clone(), harness, model.clone()));
    mirror::start(conn, engine.clone(), chat.id.clone(), cwd.clone());
    let thread = thread_json(&chat, &cwd, thread_status(&chat, &sessions), turns);
    ok(thread_response(
        thread,
        chat_model(&chat).unwrap_or_default(),
        &cwd,
    ))
}

async fn thread_set_name(engine: &Engine, params: &Value) -> Reply {
    let (Some(id), Some(name)) = (
        params.get("threadId").and_then(Value::as_str),
        params.get("name").and_then(Value::as_str),
    ) else {
        return invalid("missing threadId or name");
    };
    match engine
        .client
        .mutate(json!({ "op": "renameChat", "chatId": id, "title": name }))
        .await
    {
        Ok(_) => ok(json!({})),
        Err(error) => fail(error.to_string()),
    }
}

async fn thread_set_archived(engine: &Engine, params: &Value, archived: bool) -> Reply {
    let Some(id) = params.get("threadId").and_then(Value::as_str) else {
        return invalid("missing threadId");
    };
    match engine
        .client
        .mutate(json!({ "op": "setChatArchived", "chatId": id, "archived": archived }))
        .await
    {
        Ok(_) => ok(json!({})),
        Err(error) => fail(error.to_string()),
    }
}

/// A model picked in the TUI becomes the chat's model, as in the desktop.
async fn thread_settings_update(conn: &Arc<Conn>, engine: &Engine, params: &Value) -> Reply {
    let Some(id) = params.get("threadId").and_then(Value::as_str) else {
        return invalid("missing threadId");
    };
    if let Some((harness, model)) = params
        .get("model")
        .and_then(Value::as_str)
        .and_then(split_model)
    {
        let chat = match find_chat(engine, id).await {
            Ok(chat) => chat,
            Err(error) => return (Err(error), None),
        };
        let mut config = chat.config.unwrap_or(ChatConfig {
            harness,
            model: None,
            reasoning: None,
            model_options: Default::default(),
            sandbox: SandboxLevel::WorkspaceWrite,
        });
        config.harness = harness;
        config.model = Some(model.clone());
        if let Err(error) = engine
            .client
            .mutate(json!({ "op": "setChatConfig", "chatId": id, "config": config }))
            .await
        {
            return fail(error.to_string());
        }
        if let Some(thread) = conn.threads.lock().expect("threads lock").get_mut(id) {
            thread.harness = harness;
            thread.model = Some(model);
        }
    }
    ok(json!({}))
}

// ---- turns -----------------------------------------------------------------

fn turn_start(conn: &Arc<Conn>, engine: &Arc<Engine>, params: &Value) -> Reply {
    let Some(chat_id) = params
        .get("threadId")
        .and_then(Value::as_str)
        .map(str::to_owned)
    else {
        return invalid("missing threadId");
    };
    let input = params.get("input").cloned().unwrap_or(Value::Null);
    let (prompt, attachments) = crate::turn::prompt_and_attachments(&input);
    let client_id = params
        .get("clientUserMessageId")
        .and_then(Value::as_str)
        .map(str::to_owned);
    let request = {
        let mut threads = conn.threads.lock().expect("threads lock");
        let Some(thread) = threads.get_mut(&chat_id) else {
            return invalid("unknown threadId");
        };
        if let Some((harness, model)) = params
            .get("model")
            .and_then(Value::as_str)
            .and_then(split_model)
        {
            thread.harness = harness;
            thread.model = Some(model);
        }
        RunRequest {
            prompt,
            harness: Some(thread.harness),
            model: thread.model.clone(),
            reasoning: params
                .get("effort")
                .and_then(Value::as_str)
                .and_then(|e| serde_json::from_value(Value::String(e.to_owned())).ok()),
            model_options: Default::default(),
            cwd: thread.cwd.clone(),
            sandbox: SandboxLevel::WorkspaceWrite,
            auto_approve: params.get("approvalPolicy").and_then(Value::as_str) == Some("never"),
            resume: None,
            attachments,
            worktree: None,
        }
    };
    let turn_id = Uuid::new_v4().to_string();
    let message_id = Uuid::new_v4().to_string();
    let response = json!({ "turn": crate::turn::turn_json(&turn_id, "inProgress", None) });
    let conn = conn.clone();
    let engine = engine.clone();
    // Announce the turn, then hand it to the chat: the mirror must find the
    // turn id set before the chat starts working on it.
    let after: After = Some(Box::pin(async move {
        {
            let mut threads = conn.threads.lock().expect("threads lock");
            if let Some(thread) = threads.get_mut(&chat_id) {
                thread.turn_id = Some(turn_id.clone());
                thread.interrupted = false;
                if let Some(client_id) = client_id {
                    thread.client_ids.insert(message_id.clone(), client_id);
                }
            }
        }
        conn.notify(
            "turn/started",
            json!({ "threadId": chat_id, "turn": crate::turn::turn_json(&turn_id, "inProgress", None) }),
        );
        let command = SessionCommandPayload::Run {
            request,
            message_id,
        };
        if let Err(error) = engine.client.queue_command(&chat_id, &command).await {
            if let Some(thread) = conn.threads.lock().expect("threads lock").get_mut(&chat_id) {
                thread.turn_id = None;
            }
            let message = error.to_string();
            conn.notify(
                "turn/completed",
                json!({ "threadId": chat_id, "turn": crate::turn::turn_json(&turn_id, "failed", Some(&message)) }),
            );
        }
    }));
    (Ok(response), after)
}

/// Mid-turn input for agents that take it (the desktop's "Steer"). For the
/// rest the TUI queues the message and sends it when the turn ends, like the
/// desktop's queue.
async fn turn_steer(conn: &Arc<Conn>, engine: &Engine, params: &Value) -> Reply {
    let Some(chat_id) = params.get("threadId").and_then(Value::as_str) else {
        return invalid("missing threadId");
    };
    let (active, harness) = {
        let threads = conn.threads.lock().expect("threads lock");
        let Some(thread) = threads.get(chat_id) else {
            return invalid("unknown threadId");
        };
        (thread.turn_id.clone(), thread.harness)
    };
    let Some(active) = active else {
        return invalid("no active turn to steer");
    };
    if let Some(expected) = params.get("expectedTurnId").and_then(Value::as_str)
        && expected != active
    {
        return invalid(format!(
            "expected active turn id `{expected}` but found `{active}`"
        ));
    }
    let steers = engine
        .client
        .harnesses()
        .await
        .ok()
        .and_then(|list| list.into_iter().find(|h| h.id == harness))
        .is_some_and(|h| h.steers_mid_turn());
    if !steers {
        return (
            Err(RpcError::not_steerable(
                "this agent takes new input when its turn ends",
            )),
            None,
        );
    }
    let input = params.get("input").cloned().unwrap_or(Value::Null);
    let (prompt, _) = crate::turn::prompt_and_attachments(&input);
    let message_id = Uuid::new_v4().to_string();
    if let Some(client_id) = params.get("clientUserMessageId").and_then(Value::as_str)
        && let Some(thread) = conn.threads.lock().expect("threads lock").get_mut(chat_id)
    {
        thread
            .client_ids
            .insert(message_id.clone(), client_id.to_owned());
    }
    let command = SessionCommandPayload::Steer {
        prompt,
        message_id: Some(message_id),
    };
    match engine.client.queue_command(chat_id, &command).await {
        Ok(_) => ok(json!({ "turnId": active })),
        Err(error) => fail(error.to_string()),
    }
}

async fn turn_interrupt(conn: &Arc<Conn>, engine: &Engine, params: &Value) -> Reply {
    let Some(chat_id) = params.get("threadId").and_then(Value::as_str) else {
        return invalid("missing threadId");
    };
    if let Some(thread) = conn.threads.lock().expect("threads lock").get_mut(chat_id) {
        thread.interrupted = true;
    }
    match engine
        .client
        .queue_command(chat_id, &SessionCommandPayload::Interrupt {})
        .await
    {
        Ok(_) => ok(json!({})),
        Err(error) => fail(error.to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use harness_doc::MessageStatus;

    fn entry(id: &str, role: MessageRole, parts: Vec<MessagePart>) -> SessionMessageEntry {
        SessionMessageEntry {
            id: id.into(),
            role,
            parts,
            created_at: 1_700_000_000_000,
            device_id: "d".into(),
            status: Some(MessageStatus::Complete),
            continuation_of: None,
            duration_ms: None,
        }
    }

    #[test]
    fn each_user_message_opens_a_turn_with_the_agent_items_after_it() {
        let entries = vec![
            entry(
                "u1",
                MessageRole::User,
                vec![MessagePart::Text {
                    id: "t".into(),
                    text: "hi".into(),
                }],
            ),
            entry(
                "a1",
                MessageRole::Assistant,
                vec![
                    MessagePart::Reasoning {
                        id: "r".into(),
                        text: "thinking".into(),
                    },
                    MessagePart::Text {
                        id: "x".into(),
                        text: "hello".into(),
                    },
                ],
            ),
            entry(
                "u2",
                MessageRole::User,
                vec![MessagePart::Text {
                    id: "t2".into(),
                    text: "again".into(),
                }],
            ),
            entry(
                "a2",
                MessageRole::Assistant,
                vec![MessagePart::Text {
                    id: "y".into(),
                    text: "sure".into(),
                }],
            ),
        ];
        let turns = turns_from(&entries, "/repo");
        assert_eq!(turns.len(), 2);
        assert_eq!(turns[0]["id"], "u1");
        let kinds: Vec<&str> = turns[0]["items"]
            .as_array()
            .unwrap()
            .iter()
            .map(|i| i["type"].as_str().unwrap())
            .collect();
        assert_eq!(kinds, ["userMessage", "reasoning", "agentMessage"]);
        assert_eq!(turns[0]["items"][0]["content"][0]["text"], "hi");
        assert_eq!(turns[1]["items"][1]["text"], "sure");
    }

    #[test]
    fn an_empty_transcript_has_no_turns() {
        assert!(turns_from(&[], "/").is_empty());
    }
}
