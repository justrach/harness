//! Drives the in-chat ChatGPT reconnect (`reauth_recovery.rs`) without leaving the chat: the same
//! StartAgentLogin / PollAgentLogin / CancelAgentLogin calls Settings → Accounts makes, aimed at the
//! chat's execution host. The draft, the history and the selected pane are never touched.

use super::*;
use crate::reauth_recovery::{
    RESUME_PROMPT, ReauthAction, ReauthKey, ReauthRow, RecoveryPhase, start_params, start_supported,
};
use harness_proto::{AgentLoginPoll, AgentLoginStart, AgentLoginStatus, ReauthProvider};

/// How often a waiting approval is checked (Accounts polls at the same pace).
const POLL_EVERY: std::time::Duration = std::time::Duration::from_millis(1500);

impl Shell {
    pub(super) fn on_reauth_action(
        &mut self,
        chat_id: &str,
        row_id: &str,
        provider: ReauthProvider,
        action: ReauthAction,
        cx: &mut Context<Self>,
    ) {
        let chat = self
            .state
            .read(cx)
            .chats
            .iter()
            .find(|chat| chat.id == chat_id)
            .cloned();
        let Some(chat) = chat.filter(|chat| !chat.device_id.is_empty()) else {
            // A missing owner must never route the sign-in to the viewer instead.
            self.sidebar_notice =
                Some("Chat host unavailable. Open the chat's host in Accounts to sign in.".into());
            cx.notify();
            return;
        };
        let key = ReauthKey {
            host: chat.device_id.clone(),
            provider,
        };
        let row = ReauthRow {
            chat_id: chat_id.to_string(),
            row_id: row_id.to_string(),
        };
        match action {
            ReauthAction::Reconnect | ReauthAction::Retry => {
                let starts = self.state.update(cx, |state, cx| {
                    let starts = state.reauth.request(&key, row);
                    cx.notify();
                    starts
                });
                // Already starting or waiting: this card attaches to it.
                if starts {
                    self.start_reauth(key, cx);
                }
            }
            ReauthAction::Cancel => self.cancel_reauth(&key, cx),
            ReauthAction::Resume => self.resume_after_reauth(chat, row, cx),
        }
    }

    /// Start (or attach to, on the host) the recovery for `key`, then poll it until the host
    /// verifies the renewed sign-in, it fails, or someone cancels it.
    fn start_reauth(&mut self, key: ReauthKey, cx: &mut Context<Self>) {
        let Some(engine) = self.state.read(cx).engine().cloned() else {
            self.state.update(cx, |state, cx| {
                state.reauth.set(
                    &key,
                    RecoveryPhase::Failed("Harness's engine isn't connected.".into()),
                );
                cx.notify();
            });
            return;
        };
        let task_key = key.clone();
        let attempt = self.state.read(cx).reauth.attempt(&key);
        let task = cx.spawn(async move |this, cx| {
            let host = key.host.clone();
            let start = engine
                .client()
                .call(
                    methods::START_AGENT_LOGIN,
                    start_params(key.provider, &host),
                )
                .await
                .map_err(|err| err.to_string())
                .and_then(|value| {
                    serde_json::from_value::<AgentLoginStart>(value).map_err(|err| err.to_string())
                });
            // Cancelled while starting, or replaced by a newer attempt.
            let current = this
                .update(cx, |shell, cx| {
                    let reauth = &shell.state.read(cx).reauth;
                    (reauth.starting(&key, attempt), reauth.attempt(&key) == attempt)
                })
                .unwrap_or((false, false));
            if !current.0 {
                // Cancelled with no newer attempt: end the sign-in that just started rather than
                // leave it waiting. A newer attempt attaches to it on the host, so leave it be.
                if current.1
                    && let Ok(start) = &start
                {
                    let _ = engine
                        .client()
                        .call(
                            methods::CANCEL_AGENT_LOGIN,
                            serde_json::json!({ "loginId": start.login_id, "targetDeviceId": host }),
                        )
                        .await;
                }
                return;
            }
            let start = match start {
                Ok(start) if start_supported(key.provider, &start) => start,
                Ok(start) => {
                    // An older or different host: end what it started rather than leave it open.
                    let _ = engine
                        .client()
                        .call(
                            methods::CANCEL_AGENT_LOGIN,
                            serde_json::json!({ "loginId": start.login_id, "targetDeviceId": host }),
                        )
                        .await;
                    Self::set_reauth_phase(
                        &this,
                        &key,
                        RecoveryPhase::Failed(
                            "Update Harness on the chat's computer to reconnect from here.".into(),
                        ),
                        cx,
                    );
                    return;
                }
                Err(err) => {
                    Self::set_reauth_phase(
                        &this,
                        &key,
                        RecoveryPhase::Failed(format!("Sign-in didn't start: {err}")),
                        cx,
                    );
                    return;
                }
            };
            let login_id = start.login_id.clone();
            Self::set_reauth_phase(
                &this,
                &key,
                RecoveryPhase::Waiting {
                    start,
                    message: None,
                },
                cx,
            );
            let params = serde_json::json!({ "loginId": login_id, "targetDeviceId": host });
            loop {
                cx.background_executor().timer(POLL_EVERY).await;
                // Cancelled, or replaced by a newer attempt: stop quietly.
                let current = this
                    .update(cx, |shell, cx| shell.state.read(cx).reauth.login_id(&key))
                    .ok()
                    .flatten();
                if current.as_deref() != Some(login_id.as_str()) {
                    return;
                }
                let poll = engine
                    .client()
                    .call(methods::POLL_AGENT_LOGIN, params.clone())
                    .await
                    .map_err(|err| err.to_string())
                    .and_then(|value| {
                        serde_json::from_value::<AgentLoginPoll>(value)
                            .map_err(|err| err.to_string())
                    });
                let next = match poll {
                    // Only the host's own Done counts: it verified the renewed credentials.
                    Ok(poll) if poll.status == AgentLoginStatus::Done => RecoveryPhase::Reconnected,
                    Ok(poll) if poll.status == AgentLoginStatus::Error => RecoveryPhase::Failed(
                        poll.message.unwrap_or_else(|| "Sign-in failed.".into()),
                    ),
                    Ok(poll) => {
                        let message = poll.message;
                        let _ = this.update(cx, |shell, cx| {
                            shell.state.update(cx, |state, cx| {
                                if let Some(RecoveryPhase::Waiting { start, message: old }) =
                                    state.reauth.phase(&key).cloned()
                                    && old != message
                                {
                                    state
                                        .reauth
                                        .set(&key, RecoveryPhase::Waiting { start, message });
                                    cx.notify();
                                }
                            })
                        });
                        continue;
                    }
                    Err(err) => {
                        RecoveryPhase::Failed(format!("Couldn't check the sign-in: {err}"))
                    }
                };
                Self::set_reauth_phase(&this, &key, next, cx);
                return;
            }
        });
        self.reauth_tasks.insert(task_key, task);
    }

    fn set_reauth_phase(
        this: &gpui::WeakEntity<Self>,
        key: &ReauthKey,
        phase: RecoveryPhase,
        cx: &mut gpui::AsyncApp,
    ) {
        let _ = this.update(cx, |shell, cx| {
            shell.state.update(cx, |state, cx| {
                state.reauth.set(key, phase);
                cx.notify();
            });
        });
    }

    /// Explicit Cancel: ends the approval on the host for everyone waiting on it. While the start is
    /// still in flight its task stays alive, sees it was cancelled, and ends the sign-in it gets
    /// back (`start_reauth`).
    fn cancel_reauth(&mut self, key: &ReauthKey, cx: &mut Context<Self>) {
        if !matches!(
            self.state.read(cx).reauth.phase(key),
            Some(RecoveryPhase::Starting)
        ) {
            self.reauth_tasks.remove(key);
        }
        let login_id = self.state.update(cx, |state, cx| {
            let login_id = state.reauth.login_id(key);
            state.reauth.clear(key);
            cx.notify();
            login_id
        });
        if let (Some(login_id), Some(engine)) = (login_id, self.state.read(cx).engine().cloned()) {
            let params = serde_json::json!({ "loginId": login_id, "targetDeviceId": key.host });
            cx.spawn(async move |_, _| {
                if let Err(error) = engine
                    .client()
                    .call(methods::CANCEL_AGENT_LOGIN, params)
                    .await
                {
                    tracing::debug!(%error, "CancelAgentLogin failed (best-effort)");
                }
            })
            .detach();
        }
    }

    /// Resume conversation: a new turn in the same chat, from its existing session (the engine
    /// resumes the chat's native session when `resume` is unset). The failed prompt and finished
    /// tools are not replayed, the composer's draft and attachments are not read or cleared, and
    /// the chat's own agent, model and options are used, never a default.
    fn resume_after_reauth(
        &mut self,
        chat: harness_proto::Chat,
        row: ReauthRow,
        cx: &mut Context<Self>,
    ) {
        let busy = matches!(
            self.state
                .read(cx)
                .indicator_for(&chat.id, chrono::Utc::now()),
            Indicator::Working | Indicator::AwaitingInput
        );
        // The chat's own agent and model, or nothing: never a default.
        let Some(config) = chat.config.clone().filter(|config| config.model.is_some()) else {
            return;
        };
        if busy
            || !self
                .state
                .update(cx, |state, _| state.reauth.claim_resume(&row))
        {
            return;
        }
        let Some(engine) = self.state.read(cx).engine().cloned() else {
            self.state
                .update(cx, |state, _| state.reauth.release_resume(&row));
            return;
        };
        let message_id = uuid::Uuid::new_v4().to_string();
        let command = harness_doc::SessionCommandPayload::Run {
            request: harness_proto::RunRequest {
                prompt: RESUME_PROMPT.to_string(),
                harness: Some(config.harness),
                model: config.model.clone(),
                reasoning: config.reasoning,
                model_options: config.model_options.clone(),
                cwd: chat.cwd.clone().unwrap_or_else(|| ".".to_string()),
                sandbox: config.sandbox,
                auto_approve: false,
                resume: None,
                attachments: Vec::new(),
                worktree: None,
            },
            message_id: message_id.clone(),
        };
        let echo = harness_doc::SessionMessageEntry {
            id: message_id.clone(),
            role: harness_doc::MessageRole::User,
            parts: vec![harness_doc::MessagePart::Text {
                id: "t0".into(),
                text: RESUME_PROMPT.to_string(),
            }],
            created_at: chrono::Utc::now().timestamp_millis(),
            device_id: "local".into(),
            status: None,
            continuation_of: None,
            duration_ms: None,
        };
        let chat_id = chat.id.clone();
        self.state.update(cx, |state, cx| {
            state.push_echo(&chat_id, echo);
            state.begin_pending_send(&chat_id, &message_id, chrono::Utc::now());
            cx.notify();
        });
        let message_id_for_failure = message_id;
        cx.spawn(async move |this, cx| {
            let message_id = message_id_for_failure;
            let sent = match serde_json::to_value(&command) {
                Ok(command) => engine
                    .client()
                    .call(
                        methods::QUEUE_COMMAND,
                        serde_json::json!({ "chatId": chat_id, "command": command }),
                    )
                    .await
                    .map(drop)
                    .map_err(|err| err.to_string()),
                Err(err) => Err(err.to_string()),
            };
            if let Err(err) = sent {
                let _ = this.update(cx, |shell, cx| {
                    shell.state.update(cx, |state, cx| {
                        state.remove_echo(&chat_id, &message_id);
                        state.end_pending_send(&chat_id, &message_id);
                        state.reauth.release_resume(&row);
                        cx.notify();
                    });
                    shell.sidebar_notice = Some(format!("Couldn't resume the chat: {err}").into());
                    cx.notify();
                });
            }
        })
        .detach();
    }
}
