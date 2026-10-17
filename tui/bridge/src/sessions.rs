//! Session names, saved-session picker and transcript hydration for `/resume`.

use std::collections::HashMap;
use std::sync::Arc;

use serde_json::{Value, json};

use crate::session_store::{SavedSession, now};
use crate::wire::{Conn, RpcError, ThreadState};

pub fn thread_json(id: &str, thread: &ThreadState, include_turns: bool) -> Value {
    json!({
        "id": id, "sessionId": id, "cliVersion": env!("CARGO_PKG_VERSION"),
        "createdAt": thread.history.created_at, "updatedAt": thread.history.updated_at,
        "recencyAt": thread.history.updated_at, "cwd": thread.cwd, "ephemeral": false,
        "model": thread.model.as_ref().map(|m| crate::methods::qualified(thread.harness, m)),
        "modelProvider": "harness", "preview": thread.history.name.as_deref().unwrap_or_default(),
        "name": thread.history.name.as_deref().unwrap_or("New session"),
        "projectId": null, "source": "appServer", "historyMode": "legacy",
        "status": { "type": if thread.turn_id.is_some() { "active" } else { "idle" }, "activeFlags": [] },
        "turns": if include_turns { thread.history.turns.clone() } else { Vec::new() },
    })
}

pub fn checkpoint(conn: &Conn, id: &str, thread: &ThreadState) -> Result<(), RpcError> {
    conn.sessions.save(id, thread)
}

pub fn save_or_notify(conn: &Conn, id: &str, thread: &ThreadState) {
    if let Err(error) = checkpoint(conn, id, thread) {
        tracing::warn!(message = %error.message, "session checkpoint failed");
        conn.notify("error", json!({
            "threadId": id, "turnId": thread.turn_id, "willRetry": false,
            "error": { "message": error.message, "codexErrorInfo": null, "additionalDetails": null },
        }));
    }
}

pub fn begin_turn(
    conn: &Conn,
    id: &str,
    thread: &mut ThreadState,
    turn_id: &str,
    prompt: &str,
) -> Result<(), RpcError> {
    let before = thread.history.clone();
    if thread.history.name.is_none() {
        let name = prompt.split_whitespace().collect::<Vec<_>>().join(" ");
        thread.history.name = Some(if name.is_empty() {
            "Image conversation".into()
        } else {
            name.chars().take(90).collect()
        });
    }
    thread.history.updated_at = now();
    thread.history.turns.push(json!({
        "id": turn_id, "items": [], "itemsView": "full", "status": "inProgress",
        "error": null, "startedAt": now(), "completedAt": null, "durationMs": null,
    }));
    if let Err(error) = checkpoint(conn, id, thread) {
        thread.history = before;
        return Err(error);
    }
    Ok(())
}

pub fn notify_name(conn: &Conn, id: &str) {
    if let Some(thread) = conn.threads.lock().expect("threads lock").get(id) {
        conn.notify(
            "thread/name/updated",
            json!({ "threadId": id, "threadName": thread.history.name }),
        );
    }
}

pub fn record_item(conn: &Conn, id: &str, turn_id: &str, item: &Value) {
    let mut threads = conn.threads.lock().expect("threads lock");
    let Some(thread) = threads.get_mut(id) else {
        return;
    };
    let Some(turn) = thread.history.turns.iter_mut().find(|t| t["id"] == turn_id) else {
        return;
    };
    if let Some(items) = turn["items"].as_array_mut() {
        if let Some(old) = items.iter_mut().find(|old| old["id"] == item["id"]) {
            *old = item.clone();
        } else {
            items.push(item.clone());
        }
    }
    thread.history.updated_at = now();
    save_or_notify(conn, id, thread);
}

pub fn finish_turn(conn: &Conn, id: &str, turn_id: &str, status: &str, error: Option<&str>) {
    let mut threads = conn.threads.lock().expect("threads lock");
    let Some(thread) = threads.get_mut(id) else {
        return;
    };
    if let Some(turn) = thread.history.turns.iter_mut().find(|t| t["id"] == turn_id) {
        turn["status"] = status.into();
        turn["error"] = error
            .map(|message| json!({ "message": message }))
            .unwrap_or(Value::Null);
        turn["completedAt"] = now().into();
    }
    thread.history.updated_at = now();
    save_or_notify(conn, id, thread);
}

fn id(params: &Value) -> Result<&str, RpcError> {
    params["threadId"]
        .as_str()
        .ok_or_else(|| RpcError::invalid_params("missing threadId"))
}

fn get(conn: &Conn, params: &Value, include_turns: bool) -> Result<Value, RpcError> {
    let id = id(params)?;
    if let Some(thread) = conn.threads.lock().expect("threads lock").get(id) {
        return Ok(thread_json(id, thread, include_turns));
    }
    let saved = conn.sessions.read(id)?.into_thread();
    Ok(thread_json(id, &saved, include_turns))
}

pub fn read(conn: &Conn, params: &Value) -> Result<Value, RpcError> {
    Ok(json!({ "thread": get(conn, params, params["includeTurns"] == true)? }))
}

pub fn resume(conn: &Arc<Conn>, params: &Value) -> Result<Value, RpcError> {
    let id = id(params)?;
    let mut threads = conn.threads.lock().expect("threads lock");
    if !threads.contains_key(id) {
        let saved = conn.sessions.read(id)?;
        if saved.resume.is_none() {
            return Err(RpcError::invalid_params("session has not started yet"));
        }
        threads.insert(id.into(), saved.into_thread());
    }
    let thread = threads.get_mut(id).expect("inserted thread");
    // A remote client's launch cwd must not silently move a resumed agent.
    // Keep the saved cwd, just as the saved native resume token belongs to its agent.
    if let Some((harness, model)) = params["model"]
        .as_str()
        .and_then(crate::methods::split_model)
    {
        if harness != thread.harness {
            return Err(RpcError::invalid_params(
                "cannot resume a session with a different agent",
            ));
        }
        if thread.turn_id.is_none() {
            thread.model = Some(model);
        }
    }
    checkpoint(conn, id, thread)?;
    Ok(json!({
        "thread": thread_json(id, thread, params["excludeTurns"] != true),
        "model": thread.model.as_ref().map(|m| crate::methods::qualified(thread.harness, m)).unwrap_or_default(),
        "modelProvider": "harness", "cwd": thread.cwd, "approvalPolicy": "on-request",
        "approvalsReviewer": "user", "sandbox": { "type": "workspaceWrite" },
        "disabledPluginIds": [], "instructionSources": [],
        "turnsBackwardsCursor": null, "itemsBackwardsCursor": null,
    }))
}

pub fn list(conn: &Conn, params: &Value) -> Result<Value, RpcError> {
    if params["archived"] == true {
        return Ok(json!({ "data": [], "nextCursor": null, "backwardsCursor": null }));
    }
    let mut saved: HashMap<String, SavedSession> = conn
        .sessions
        .list()?
        .into_iter()
        .map(|s| (s.id.clone(), s))
        .collect();
    for (id, thread) in conn.threads.lock().expect("threads lock").iter() {
        if thread.resume.is_some() {
            saved.insert(id.clone(), SavedSession::capture(id, thread));
        }
    }
    let search = params["searchTerm"]
        .as_str()
        .unwrap_or_default()
        .to_lowercase();
    let mut records: Vec<_> = saved
        .into_values()
        .filter(|s| {
            let cwd_matches = match &params["cwd"] {
                Value::String(cwd) => cwd == &s.cwd,
                Value::Array(cwds) => cwds.iter().any(|cwd| cwd.as_str() == Some(&s.cwd)),
                _ => true,
            };
            cwd_matches
                && (search.is_empty()
                    || s.history
                        .name
                        .as_deref()
                        .unwrap_or_default()
                        .to_lowercase()
                        .contains(&search)
                    || s.id.contains(&search))
        })
        .collect();
    let created = params["sortKey"] == "created_at";
    records.sort_by(|a, b| {
        let stamp = |s: &SavedSession| {
            if created {
                s.history.created_at
            } else {
                s.history.updated_at
            }
        };
        stamp(b).cmp(&stamp(a)).then_with(|| a.id.cmp(&b.id))
    });
    if params["sortDirection"] == "asc" {
        records.reverse();
    }
    let start = match params["cursor"].as_str() {
        Some(cursor) => records
            .iter()
            .position(|s| s.id == cursor)
            .map(|n| n + 1)
            .ok_or_else(|| RpcError::invalid_params("invalid session cursor"))?,
        None => 0,
    };
    let limit = params["limit"].as_u64().unwrap_or(50).clamp(1, 200) as usize;
    let page = &records[start..records.len().min(start.saturating_add(limit))];
    let next = (start + page.len() < records.len())
        .then(|| page.last().map(|s| s.id.clone()))
        .flatten();
    let data: Vec<_> = page
        .iter()
        .map(|s| {
            thread_json(
                &s.id,
                &SavedSession {
                    id: s.id.clone(),
                    cwd: s.cwd.clone(),
                    harness: s.harness,
                    model: s.model.clone(),
                    resume: s.resume.clone(),
                    history: s.history.clone(),
                }
                .into_thread(),
                false,
            )
        })
        .collect();
    Ok(json!({ "data": data, "nextCursor": next, "backwardsCursor": null }))
}

pub fn turns(conn: &Conn, params: &Value) -> Result<Value, RpcError> {
    let thread = get(conn, params, true)?;
    let mut data = thread["turns"].as_array().cloned().unwrap_or_default();
    if params["sortDirection"] == "desc" {
        data.reverse();
    }
    Ok(json!({ "data": data, "nextCursor": null, "backwardsCursor": null }))
}

#[cfg(test)]
#[path = "sessions_tests.rs"]
mod tests;
