//! The phone's half of the session doc's command plane and queue (`SessionStore.sendRun` / `sendSteer` /
//! `sendInterrupt` / `respondInput` and `SessionQueue.swift` on iOS): entries this device appends, which the chat's
//! host drains.

use harness_doc::{
    COMMAND_DEFAULT_TTL_MS, CommandBasedOn, QueuedMessage, SessionCommandEntry,
    SessionCommandPayload, SessionCommandStatus,
};
use harness_proto::{RunRequest, SandboxLevel, UserInputAnswer};
use serde_json::{Map, Value, json};

use crate::records::{ChatRecord, UserInputAnswerRecord};

/// A pending command from this device, based on the transcript's last entry.
pub(crate) fn entry(
    device_id: &str,
    payload: SessionCommandPayload,
    based_on: Option<String>,
    now_ms: i64,
) -> SessionCommandEntry {
    SessionCommandEntry {
        id: new_id(),
        payload,
        issued_by: device_id.to_owned(),
        issued_at: now_ms,
        based_on: based_on.map(|turn_id| CommandBasedOn {
            turn_id: Some(turn_id),
            frontier: None,
        }),
        expires_at: Some(now_ms + COMMAND_DEFAULT_TTL_MS),
        status: SessionCommandStatus::Pending,
        resolution: None,
    }
}

/// A run with the chat's picks (harness, model, reasoning, options, sandbox) and folder. A pick this build does not
/// know is left out, so the host uses its own default rather than the command failing to parse.
pub(crate) fn run_request(
    chat: Option<&ChatRecord>,
    prompt: String,
    attachments: Vec<String>,
) -> RunRequest {
    let config = chat.and_then(|chat| chat.config.as_ref());
    RunRequest {
        prompt,
        harness: parse(config.map(|c| c.harness.as_str())),
        model: config.and_then(|c| c.model.clone()),
        reasoning: parse(config.and_then(|c| c.reasoning.as_deref())),
        model_options: config
            .map(|c| {
                c.model_options
                    .iter()
                    .map(|(k, v)| (k.clone(), Value::String(v.clone())))
                    .collect::<Map<_, _>>()
            })
            .unwrap_or_default(),
        cwd: chat.and_then(|chat| chat.cwd.clone()).unwrap_or_default(),
        sandbox: parse(config.and_then(|c| c.sandbox.as_deref()))
            .unwrap_or(SandboxLevel::WorkspaceWrite),
        auto_approve: false,
        resume: None,
        attachments,
        worktree: None,
    }
}

/// A pick by its wire name, or None when this build does not know it.
fn parse<T: serde::de::DeserializeOwned>(value: Option<&str>) -> Option<T> {
    value.and_then(|v| serde_json::from_value(json!(v)).ok())
}

pub(crate) fn answers(answers: Vec<UserInputAnswerRecord>) -> Vec<UserInputAnswer> {
    answers
        .into_iter()
        .map(|answer| UserInputAnswer {
            question_id: answer.question_id,
            labels: answer.labels,
        })
        .collect()
}

/// A queue row from this device.
pub(crate) fn queued(
    device_id: &str,
    text: String,
    attachments: Vec<String>,
    hold_for_turn_end: bool,
    now_ms: i64,
) -> QueuedMessage {
    QueuedMessage {
        attachments,
        hold_for_turn_end,
        issued_at: now_ms,
        ..QueuedMessage::new(new_id(), text, device_id)
    }
}

pub(crate) fn new_id() -> String {
    uuid::Uuid::new_v4().to_string().to_lowercase()
}
