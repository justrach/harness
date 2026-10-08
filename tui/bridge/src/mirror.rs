//! Engine mode: keep one open thread in sync with its Harness chat.
//!
//! The chat doc is the source of truth, exactly as for the desktop and phone
//! apps. The mirror watches the chat's transcript and its session row and
//! turns what changes into the Codex events the TUI renders:
//!
//! - a session going `working` starts a Codex turn (the TUI's own
//!   `turn/start` already did, for a turn it asked for); going `idle` or
//!   `errored` completes it, after a short grace so the last tokens land
//!   inside the turn;
//! - new transcript text, reasoning and tool parts are replayed as agent
//!   events through the same translator standalone mode uses, so every row
//!   renders the same way;
//! - a user entry nobody in this TUI typed (the desktop, the phone, a queued
//!   message) shows as the user's message;
//! - an open question goes to the TUI as `item/tool/requestUserInput`, and
//!   the answer goes back to the chat as `RespondInput`.
//!
//! What the transcript held when the mirror attached is history: the TUI
//! got it from `thread/resume`, so it is marked seen and not replayed.

use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use std::time::Duration;

use harness_doc::{
    MessagePart, MessageRole, SessionCommandPayload, SessionMessageEntry, TranscriptFrame,
    apply_transcript_frame,
};
use harness_proto::{AgentEvent, Session, SessionStatus, UserInputAnswer, UserInputQuestion};
use harness_rpc::methods;
use serde_json::{Value, json};
use uuid::Uuid;

use crate::engine::Engine;
use crate::turn::Turn;
use crate::wire::Conn;

/// Gap between resubscribes when a watch ends (engine restart, doc cutover).
const RESUBSCRIBE_DELAY: Duration = Duration::from_millis(300);
/// After the session settles, frames still in flight finish the turn.
const SETTLE_GRACE: Duration = Duration::from_millis(400);

/// Start mirroring `chat_id` into thread `chat_id` (thread ids are chat ids).
pub fn start(conn: &Arc<Conn>, engine: Arc<Engine>, chat_id: String, cwd: String) {
    let mut mirrors = conn.mirrors.lock().expect("mirrors lock");
    if mirrors.get(&chat_id).is_some_and(|m| !m.is_finished()) {
        return;
    }
    let mirror = Mirror::new(conn.clone(), engine, chat_id.clone(), cwd);
    mirrors.insert(chat_id, tokio::spawn(mirror.run()));
}

pub fn stop(conn: &Conn, chat_id: &str) {
    if let Some(mirror) = conn.mirrors.lock().expect("mirrors lock").remove(chat_id) {
        mirror.abort();
    }
}

/// What the TUI has already been shown of one part.
#[derive(Default, Clone)]
struct Seen {
    /// Characters of text/reasoning already sent.
    chars: usize,
    tool_called: bool,
    tool_done: bool,
    asked: bool,
    error_shown: bool,
}

struct Mirror {
    conn: Arc<Conn>,
    engine: Arc<Engine>,
    chat_id: String,
    cwd: String,
    entries: Vec<SessionMessageEntry>,
    /// Entry id → part id → what was shown.
    seen: HashMap<String, HashMap<String, Seen>>,
    /// Entries already rendered as a whole (user messages).
    shown_entries: HashSet<String>,
    attached: bool,
    turn: Option<Turn>,
    text_part: Option<String>,
    reasoning_part: Option<String>,
    status: Option<SessionStatus>,
    settle_at: Option<tokio::time::Instant>,
    turn_error: Option<String>,
}

impl Mirror {
    fn new(conn: Arc<Conn>, engine: Arc<Engine>, chat_id: String, cwd: String) -> Self {
        Self {
            conn,
            engine,
            chat_id,
            cwd,
            entries: Vec::new(),
            seen: HashMap::new(),
            shown_entries: HashSet::new(),
            attached: false,
            turn: None,
            text_part: None,
            reasoning_part: None,
            status: None,
            settle_at: None,
            turn_error: None,
        }
    }

    async fn run(mut self) {
        loop {
            let doc = self
                .engine
                .client
                .subscribe(
                    methods::WATCH_DOC_MESSAGES,
                    json!({ "chatId": self.chat_id }),
                )
                .await;
            let sessions = self
                .engine
                .client
                .subscribe(methods::WATCH_SESSIONS, json!({}))
                .await;
            let (mut doc, mut sessions) = match (doc, sessions) {
                (Ok(doc), Ok(sessions)) => (doc, sessions),
                (Err(error), _) | (_, Err(error)) => {
                    tracing::warn!(chat = %self.chat_id, %error, "mirror subscribe failed");
                    tokio::time::sleep(RESUBSCRIBE_DELAY * 10).await;
                    continue;
                }
            };
            loop {
                let settle = self.settle_at;
                tokio::select! {
                    frame = doc.recv() => match frame {
                        Some(frame) => self.on_frame(frame),
                        None => break,
                    },
                    rows = sessions.recv() => match rows {
                        Some(rows) => self.on_sessions(rows),
                        None => break,
                    },
                    _ = async {
                        match settle {
                            Some(at) => tokio::time::sleep_until(at).await,
                            None => std::future::pending().await,
                        }
                    } => self.settle(),
                }
            }
            tokio::time::sleep(RESUBSCRIBE_DELAY).await;
        }
    }

    // ---- turns -------------------------------------------------------------

    /// The Codex turn new events belong to, starting one when the chat began
    /// working on its own (the desktop, the phone, a queued message).
    fn turn(&mut self) -> &mut Turn {
        if self.turn.is_none() {
            let (turn_id, announced) = {
                let mut threads = self.conn.threads.lock().expect("threads lock");
                match threads.get_mut(&self.chat_id) {
                    // The TUI's own turn/start already announced this turn.
                    Some(thread) if thread.turn_id.is_some() => {
                        (thread.turn_id.clone().unwrap(), true)
                    }
                    Some(thread) => {
                        let id = Uuid::new_v4().to_string();
                        thread.turn_id = Some(id.clone());
                        (id, false)
                    }
                    None => (Uuid::new_v4().to_string(), false),
                }
            };
            if !announced {
                self.conn.notify(
                    "turn/started",
                    json!({
                        "threadId": self.chat_id,
                        "turn": crate::turn::turn_json(&turn_id, "inProgress", None),
                    }),
                );
            }
            self.turn_error = None;
            self.turn = Some(Turn::new(
                self.conn.clone(),
                self.chat_id.clone(),
                turn_id,
                self.cwd.clone(),
            ));
        }
        self.turn.as_mut().unwrap()
    }

    fn on_sessions(&mut self, rows: Value) {
        let Ok(rows) = serde_json::from_value::<Vec<Session>>(rows) else {
            return;
        };
        let Some(row) = rows
            .into_iter()
            .filter(|s| s.chat_id == self.chat_id)
            .max_by_key(|s| s.updated_at)
        else {
            return;
        };
        let was = self.status.replace(row.status);
        match row.status {
            SessionStatus::Working => {
                self.settle_at = None;
                if self.attached {
                    self.turn();
                }
            }
            SessionStatus::AwaitingInput => self.settle_at = None,
            SessionStatus::Idle | SessionStatus::Errored => {
                let ours = self.turn.is_some()
                    || self
                        .conn
                        .threads
                        .lock()
                        .expect("threads lock")
                        .get(&self.chat_id)
                        .is_some_and(|t| t.turn_id.is_some());
                // A turn the TUI started settles only after the chat worked
                // on it; an idle row from before the command lands is not it.
                if ours
                    && was.is_some_and(|s| {
                        s != SessionStatus::Idle || row.status == SessionStatus::Errored
                    })
                {
                    self.settle_at = Some(tokio::time::Instant::now() + SETTLE_GRACE);
                }
            }
        }
    }

    fn settle(&mut self) {
        self.settle_at = None;
        if matches!(
            self.status,
            Some(SessionStatus::Working | SessionStatus::AwaitingInput)
        ) {
            return;
        }
        let (interrupted, announced) = {
            let mut threads = self.conn.threads.lock().expect("threads lock");
            match threads.get_mut(&self.chat_id) {
                Some(thread) => (
                    std::mem::take(&mut thread.interrupted),
                    thread.turn_id.take(),
                ),
                None => (false, None),
            }
        };
        self.text_part = None;
        self.reasoning_part = None;
        let errored = self.status == Some(SessionStatus::Errored);
        let error = self.turn_error.take();
        let turn = match (self.turn.take(), announced) {
            (Some(turn), _) => turn,
            // Announced by turn/start but nothing streamed (an instant error).
            (None, Some(turn_id)) => Turn::new(
                self.conn.clone(),
                self.chat_id.clone(),
                turn_id,
                self.cwd.clone(),
            ),
            (None, None) => return,
        };
        let status = if interrupted {
            "interrupted"
        } else if errored || error.is_some() {
            "failed"
        } else {
            "completed"
        };
        turn.complete(status, error.as_deref());
    }

    // ---- transcript --------------------------------------------------------

    fn on_frame(&mut self, raw: Value) {
        let frame: TranscriptFrame = match serde_json::from_value(raw) {
            Ok(frame) => frame,
            Err(error) => {
                tracing::warn!(chat = %self.chat_id, %error, "unreadable transcript frame");
                return;
            }
        };
        let touched: Vec<String> = match &frame {
            TranscriptFrame::Reset { reset } => reset.iter().map(|e| e.id.clone()).collect(),
            TranscriptFrame::Delta { upsert, append, .. } => upsert
                .iter()
                .map(|u| u.entry.id.clone())
                .chain(append.iter().map(|a| a.entry.clone()))
                .collect(),
        };
        if let Err(error) = apply_transcript_frame(&mut self.entries, frame) {
            // Out of step: the next subscribe opens with a fresh reset.
            tracing::warn!(chat = %self.chat_id, %error, "transcript desync");
            return;
        }
        if !self.attached {
            self.attached = true;
            self.mark_history();
            if self.status == Some(SessionStatus::Working) {
                self.turn();
            }
            return;
        }
        let mut done = HashSet::new();
        for id in touched {
            if !done.insert(id.clone()) {
                continue;
            }
            if let Some(entry) = self.entries.iter().find(|e| e.id == id).cloned() {
                self.on_entry(&entry);
            }
        }
    }

    /// Everything present at attach was delivered by `thread/resume`.
    fn mark_history(&mut self) {
        for entry in &self.entries {
            self.shown_entries.insert(entry.id.clone());
            let parts = self.seen.entry(entry.id.clone()).or_default();
            for part in &entry.parts {
                parts.insert(part_id(part).to_owned(), seen_now(part));
            }
        }
    }

    fn on_entry(&mut self, entry: &SessionMessageEntry) {
        match entry.role {
            MessageRole::User => {
                if self.shown_entries.insert(entry.id.clone()) {
                    let client_id = self
                        .conn
                        .threads
                        .lock()
                        .expect("threads lock")
                        .get_mut(&self.chat_id)
                        .and_then(|t| t.client_ids.remove(&entry.id));
                    let item = json!({
                        "type": "userMessage",
                        "id": entry.id,
                        "clientId": client_id,
                        "content": user_content(&entry.parts),
                    });
                    let turn = self.turn();
                    turn.close_reasoning();
                    turn.close_message();
                    turn.item_started(item.clone());
                    turn.item_completed(item);
                }
            }
            MessageRole::Assistant | MessageRole::System => {
                for part in &entry.parts {
                    self.on_part(&entry.id, part);
                }
            }
        }
    }

    fn on_part(&mut self, entry_id: &str, part: &MessagePart) {
        let id = part_id(part).to_owned();
        let mut seen = self
            .seen
            .get(entry_id)
            .and_then(|parts| parts.get(&id))
            .cloned()
            .unwrap_or_default();
        match part {
            MessagePart::Text { text, .. } => {
                if let Some(new) = text.get(seen.chars..).filter(|t| !t.is_empty()) {
                    let new = new.to_owned();
                    if self.text_part.as_deref() != Some(id.as_str()) {
                        self.turn().close_message();
                        self.text_part = Some(id.clone());
                    }
                    self.turn().on_event(AgentEvent::TextDelta { text: new });
                    seen.chars = text.len();
                }
            }
            MessagePart::Reasoning { text, .. } => {
                if let Some(new) = text.get(seen.chars..).filter(|t| !t.is_empty()) {
                    let new = new.to_owned();
                    if self.reasoning_part.as_deref() != Some(id.as_str()) {
                        self.turn().close_reasoning();
                        self.reasoning_part = Some(id.clone());
                    }
                    self.turn()
                        .on_event(AgentEvent::ReasoningDelta { text: new });
                    seen.chars = text.len();
                }
            }
            MessagePart::Tool {
                call,
                is_error,
                resolved,
                output,
                diff,
                ..
            } => {
                if !seen.tool_called {
                    seen.tool_called = true;
                    self.text_part = None;
                    self.turn().on_event(AgentEvent::ToolCall {
                        id: id.clone(),
                        call: call.clone(),
                    });
                }
                if *resolved && !seen.tool_done {
                    seen.tool_done = true;
                    self.turn().on_event(AgentEvent::ToolResult {
                        id: id.clone(),
                        is_error: *is_error,
                        output: output.clone(),
                        diff: diff.clone(),
                    });
                }
            }
            MessagePart::Input {
                request_id,
                questions,
                resolved,
                ..
            } => {
                if !*resolved && !seen.asked {
                    seen.asked = true;
                    let turn_id = self.turn().turn_id().to_owned();
                    self.ask(turn_id, id.clone(), request_id.clone(), questions.clone());
                }
            }
            MessagePart::Error { message, .. } => {
                if !seen.error_shown {
                    seen.error_shown = true;
                    let turn_id = self.turn().turn_id().to_owned();
                    self.turn_error = Some(message.clone());
                    self.conn.notify(
                        "error",
                        json!({
                            "threadId": self.chat_id,
                            "turnId": turn_id,
                            "willRetry": false,
                            "error": { "message": message, "codexErrorInfo": null, "additionalDetails": null },
                        }),
                    );
                }
            }
            _ => {}
        }
        self.seen
            .entry(entry_id.to_owned())
            .or_default()
            .insert(id, seen);
    }

    /// Put the agent's question to the TUI; answer or dismiss it in the chat.
    fn ask(
        &self,
        turn_id: String,
        item_id: String,
        request_id: String,
        questions: Vec<UserInputQuestion>,
    ) {
        let conn = self.conn.clone();
        let engine = self.engine.clone();
        let chat_id = self.chat_id.clone();
        tokio::spawn(async move {
            let params = json!({
                "threadId": chat_id,
                "turnId": turn_id,
                "itemId": item_id,
                "isBlocking": true,
                "questions": questions.iter().map(question_json).collect::<Vec<_>>(),
            });
            let command = match conn.request("item/tool/requestUserInput", params).await {
                Ok(reply) => SessionCommandPayload::RespondInput {
                    request_id,
                    answers: answers_from(&questions, &reply),
                },
                Err(_) => SessionCommandPayload::DismissInput { request_id },
            };
            if let Err(error) = engine.client.queue_command(&chat_id, &command).await {
                tracing::warn!(chat = %chat_id, %error, "could not deliver the answer");
            }
        });
    }
}

fn part_id(part: &MessagePart) -> &str {
    match part {
        MessagePart::Text { id, .. }
        | MessagePart::Image { id, .. }
        | MessagePart::Reasoning { id, .. }
        | MessagePart::Tool { id, .. }
        | MessagePart::Delegation { id, .. }
        | MessagePart::Input { id, .. }
        | MessagePart::Error { id, .. } => id,
        #[allow(unreachable_patterns)]
        _ => "",
    }
}

fn seen_now(part: &MessagePart) -> Seen {
    match part {
        MessagePart::Text { text, .. } | MessagePart::Reasoning { text, .. } => Seen {
            chars: text.len(),
            ..Seen::default()
        },
        MessagePart::Tool { resolved, .. } => Seen {
            tool_called: true,
            tool_done: *resolved,
            ..Seen::default()
        },
        // An open question at attach still needs an answer: leave it unasked.
        MessagePart::Input { resolved, .. } => Seen {
            asked: *resolved,
            ..Seen::default()
        },
        MessagePart::Error { .. } => Seen {
            error_shown: true,
            ..Seen::default()
        },
        _ => Seen::default(),
    }
}

/// A user entry's parts as Codex `UserInput` items.
pub fn user_content(parts: &[MessagePart]) -> Vec<Value> {
    parts
        .iter()
        .filter_map(|part| match part {
            MessagePart::Text { text, .. } => {
                Some(json!({ "type": "text", "text": text, "text_elements": [] }))
            }
            MessagePart::Image { path, .. } => Some(json!({ "type": "localImage", "path": path })),
            _ => None,
        })
        .collect()
}

fn question_json(q: &UserInputQuestion) -> Value {
    json!({
        "id": q.id,
        "header": q.header,
        "question": q.question,
        "isOther": true,
        "isSecret": false,
        "options": if q.options.is_empty() {
            Value::Null
        } else {
            Value::Array(q.options.iter().map(|o| json!({ "label": o, "description": "" })).collect())
        },
    })
}

/// The TUI's `{answers: {questionId: {answers: [..]}}}` as the chat's answers.
fn answers_from(questions: &[UserInputQuestion], reply: &Value) -> Vec<UserInputAnswer> {
    questions
        .iter()
        .map(|q| UserInputAnswer {
            question_id: q.id.clone(),
            labels: reply
                .pointer(&format!("/answers/{}/answers", q.id))
                .and_then(Value::as_array)
                .map(|a| {
                    a.iter()
                        .filter_map(Value::as_str)
                        .map(str::to_owned)
                        .collect()
                })
                .unwrap_or_default(),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn answers_map_by_question_id() {
        let questions = vec![UserInputQuestion {
            id: "q1".into(),
            header: "Pick".into(),
            question: "Which?".into(),
            options: vec!["A".into(), "B".into()],
            multi_select: false,
        }];
        let reply = json!({ "answers": { "q1": { "answers": ["B"] } } });
        let answers = answers_from(&questions, &reply);
        assert_eq!(answers.len(), 1);
        assert_eq!(answers[0].question_id, "q1");
        assert_eq!(answers[0].labels, vec!["B".to_string()]);
        assert!(answers_from(&questions, &json!({}))[0].labels.is_empty());
    }

    #[test]
    fn questions_offer_their_options_and_free_text() {
        let q = UserInputQuestion {
            id: "q1".into(),
            header: "Pick".into(),
            question: "Which?".into(),
            options: vec!["A".into()],
            multi_select: false,
        };
        let v = question_json(&q);
        assert_eq!(v["options"][0]["label"], "A");
        assert_eq!(v["isOther"], true);
    }
}
