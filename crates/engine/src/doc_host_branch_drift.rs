//! Branch drift (#354). A chat's checkout can change branch under it: another
//! draft's branch picker switches the shared folder, or someone runs `git
//! switch` outside Harness. Continuing the earlier conversation there would
//! carry the old branch's assumptions onto the new one, so every fresh
//! dispatch (a send, a queued send, an answer to a dead run's question, crash
//! recovery) compares the checkout with the chat's last accepted context, and
//! on drift holds the turn and asks how to go on.
//!
//! The question is an ordinary input part on an engine-written assistant
//! entry, so every client already renders and answers it. Its request id
//! carries [`REQUEST_PREFIX`], which routes the answer here instead of to an
//! agent. Nothing is checked out, reset or discarded unless the user picks
//! "Switch back", and that is only offered on a clean tree.

use super::*;

pub(super) const REQUEST_PREFIX: &str = "branch-drift-";
const CONTINUE: &str = "Continue on ";
const SWITCH_BACK: &str = "Switch back to ";
const DONT_SEND: &str = "Don't send";
/// While a drift question is open nothing dispatches past it, so it sits
/// among the last few entries: only held sends land after it.
const OPEN_QUESTION_TAIL_PARTS: usize = 64;

/// How a chat's checkout changed since its last turn.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Drift {
    pub from_branch: String,
    pub to_branch: String,
    /// The folder now holds a different checkout (re-cloned, or a worktree
    /// removed and recreated), whatever its branch.
    pub checkout_replaced: bool,
}

/// Only the same directory can drift: a different cwd is a deliberate move
/// (an isolated worktree, a re-homed chat), which resume already treats as a
/// new place. New commits on the same branch are the task progressing.
pub(crate) fn detect(
    previous: &ConversationSourceContext,
    current: &ConversationSourceContext,
) -> Option<Drift> {
    if previous.cwd != current.cwd {
        return None;
    }
    let checkout_replaced = previous.checkout_id != current.checkout_id;
    if !checkout_replaced && previous.branch == current.branch {
        return None;
    }
    Some(Drift {
        from_branch: previous.branch.clone(),
        to_branch: current.branch.clone(),
        checkout_replaced,
    })
}

/// A dispatch waiting on the user's answer. Kept in memory; after a restart
/// the answer rebuilds it from the transcript (see `rebuild_held`).
pub(super) struct HeldDispatch {
    harness: HarnessId,
    request: harness_proto::RunRequest,
    message_id: Option<String>,
}

fn branch_label(branch: &str) -> String {
    if branch == "HEAD" {
        "a detached HEAD".to_string()
    } else {
        format!("`{branch}`")
    }
}

/// The note the agent gets once the user accepts the new branch, so it does
/// not assume its earlier work is checked out.
fn continue_note(drift: &Drift) -> String {
    let (from, to) = (
        branch_label(&drift.from_branch),
        branch_label(&drift.to_branch),
    );
    if drift.checkout_replaced {
        format!(
            "[Harness: this folder now holds a different checkout, on {to}. \
             Earlier turns in this conversation ran in the previous checkout, on {from}.]"
        )
    } else {
        format!(
            "[Harness: the checkout is now on {to}. Earlier turns in this \
             conversation ran on {from}; their changes may not be here.]"
        )
    }
}

fn question(drift: &Drift, can_switch_back: bool) -> UserInputQuestion {
    let (from, to) = (
        branch_label(&drift.from_branch),
        branch_label(&drift.to_branch),
    );
    let situation = if drift.checkout_replaced {
        format!(
            "This chat's folder now holds a different checkout, on {to}. \
             Its earlier turns ran in the previous checkout, on {from}."
        )
    } else {
        format!("This chat was working on {from}, but its checkout is now on {to}.")
    };
    let mut options = vec![format!("{CONTINUE}{}", drift.to_branch)];
    if can_switch_back {
        options.push(format!("{SWITCH_BACK}{}", drift.from_branch));
    }
    options.push(DONT_SEND.to_string());
    UserInputQuestion {
        id: "branch".into(),
        header: "Branch changed".into(),
        question: format!("{situation} How should it continue?"),
        options,
        multi_select: false,
        prefill: None,
        multiline: false,
    }
}

/// The open drift question in this transcript, if any: `(entry id, request id)`.
pub(super) fn open_question(entries: &[SessionMessageEntry]) -> Option<(String, String)> {
    entries.iter().rev().find_map(|entry| {
        entry.parts.iter().find_map(|part| match part {
            MessagePart::Input {
                request_id,
                resolved: false,
                ..
            } if request_id.starts_with(REQUEST_PREFIX) => {
                Some((entry.id.clone(), request_id.clone()))
            }
            _ => None,
        })
    })
}

fn open_question_in_tail(handle: &ChatDocHandle) -> Option<(String, String)> {
    let tail = handle
        .doc
        .read_opening_tail(OPEN_QUESTION_TAIL_PARTS)
        .ok()?;
    open_question(&tail)
}

impl DocHost {
    /// Whether this dispatch would continue the chat on a checkout that
    /// drifted since its last turn. A turn already in flight is not
    /// re-checked: what arrives then is steered into the running turn.
    pub(super) fn drift_since_last_turn(
        &self,
        sessions: &SessionsEngine,
        chat_id: &str,
        current: &ConversationSourceContext,
    ) -> Option<Drift> {
        if sessions.turn_in_flight(chat_id) {
            return None;
        }
        let previous = self.workspace()?.chat(chat_id).ok()??.source_context?;
        detect(&previous, current)
    }

    /// The queue must not release anything while a drift question waits.
    pub(super) fn branch_drift_pending(&self, handle: &ChatDocHandle) -> bool {
        lock(&self.inner.branch_drift_holds).contains_key(&handle.chat_id)
            || open_question_in_tail(handle).is_some()
    }

    /// No drift (any more): sends held behind a question that no longer
    /// applies (the branch was switched back outside Harness, say) go out
    /// with this one, and the question closes.
    pub(super) fn release_branch_drift(
        &self,
        chat_id: &str,
        mut request: harness_proto::RunRequest,
        message_id: Option<String>,
    ) -> Result<(harness_proto::RunRequest, Option<String>), EngineError> {
        let handle = self.open(chat_id)?;
        let held = lock(&self.inner.branch_drift_holds).remove(chat_id);
        let open = open_question_in_tail(&handle);
        let held = match (held, &open) {
            (Some(held), _) => held,
            (None, Some((entry_id, _))) => self
                .rebuild_held(
                    chat_id,
                    &handle.doc.read_entries()?,
                    entry_id,
                    message_id.as_deref(),
                )
                .into_iter()
                .collect(),
            (None, None) => return Ok((request, message_id)),
        };
        if let Some((_, request_id)) = open {
            handle.doc.resolve_input(&request_id)?;
            handle.publish_messages();
            self.save_snapshot(&handle);
        }
        let mut message_id = message_id;
        let mut prompts = Vec::new();
        let mut attachments = Vec::new();
        for held in held {
            prompts.push(held.request.prompt);
            attachments.extend(held.request.attachments);
            message_id = message_id.or(held.message_id);
        }
        prompts.push(std::mem::take(&mut request.prompt));
        attachments.append(&mut request.attachments);
        request.prompt = prompts.join("\n\n");
        request.attachments = attachments;
        Ok((request, message_id))
    }

    /// Hold `request` and ask how to continue. The user's message lands in
    /// the transcript now, so it is not lost while the question waits.
    pub(super) async fn hold_for_branch_drift(
        &self,
        chat_id: &str,
        drift: &Drift,
        harness: HarnessId,
        request: harness_proto::RunRequest,
        message_id: Option<String>,
    ) -> Result<(), EngineError> {
        let handle = self.open(chat_id)?;
        if let Some(id) = &message_id {
            handle.write_user_message(id, &request.prompt, now_ms())?;
        }
        let cwd = request.cwd.clone();
        let open = open_question_in_tail(&handle);
        // A question left open across a restart still owns the messages it
        // was asked about.
        let rebuilt = match &open {
            Some((entry_id, _)) if !lock(&self.inner.branch_drift_holds).contains_key(chat_id) => {
                self.rebuild_held(
                    chat_id,
                    &handle.doc.read_entries()?,
                    entry_id,
                    message_id.as_deref(),
                )
            }
            _ => None,
        };
        {
            let mut holds = lock(&self.inner.branch_drift_holds);
            let held = holds.entry(chat_id.to_string()).or_default();
            held.extend(rebuilt);
            held.push(HeldDispatch {
                harness,
                request,
                message_id,
            });
        }
        if open.is_none() {
            let can_switch_back = self.can_switch_back(&cwd, drift).await;
            let request_id = format!("{REQUEST_PREFIX}{}", new_id());
            handle.doc.push_message(&SessionMessageEntry {
                id: new_id(),
                role: MessageRole::Assistant,
                parts: vec![MessagePart::Input {
                    id: request_id.clone(),
                    request_id,
                    questions: vec![question(drift, can_switch_back)],
                    resolved: false,
                }],
                created_at: now_ms(),
                device_id: self.inner.config.device_id.clone(),
                status: Some(MessageStatus::Complete),
                continuation_of: None,
                duration_ms: None,
            })?;
        }
        handle.publish_messages();
        self.save_snapshot(&handle);
        tracing::info!(chat = %chat_id, from = %drift.from_branch, to = %drift.to_branch,
            replaced = drift.checkout_replaced, "dispatch held: checkout drifted");
        Ok(())
    }

    /// Offered only when switching cannot touch anyone's work: the same
    /// checkout, a named branch to return to, and nothing uncommitted.
    async fn can_switch_back(&self, cwd: &str, drift: &Drift) -> bool {
        if drift.checkout_replaced || drift.from_branch == "HEAD" {
            return false;
        }
        let Some(repos) = self.inner.repos.get() else {
            return false;
        };
        repos.is_clean(Path::new(cwd)).await.unwrap_or(false)
    }

    /// Answer (or dismissal, `answers: None`) to a drift question.
    pub(super) async fn answer_branch_drift(
        &self,
        sessions: &SessionsEngine,
        handle: &Arc<ChatDocHandle>,
        request_id: &str,
        answers: Option<&[UserInputAnswer]>,
    ) -> Result<(SessionCommandStatus, Option<String>), EngineError> {
        let chat_id = &handle.chat_id;
        let entries = handle.doc.read_entries()?;
        let Some((entry_id, _)) =
            open_question(&entries).filter(|(_, open)| open.as_str() == request_id)
        else {
            return Ok((
                SessionCommandStatus::Rejected,
                Some("no pending input request".into()),
            ));
        };
        let held = lock(&self.inner.branch_drift_holds).remove(chat_id.as_str());
        let held = match held {
            Some(held) => merge_held(held),
            None => self.rebuild_held(chat_id, &entries, &entry_id, None),
        };
        handle.doc.resolve_input(request_id)?;
        handle.publish_messages();
        self.save_snapshot(handle);
        let choice = answers
            .and_then(|answers| answers.first())
            .and_then(|answer| answer.labels.first())
            .map(String::as_str)
            .unwrap_or(DONT_SEND);
        let Some(mut held) = held else {
            return Ok((
                SessionCommandStatus::Applied,
                Some("nothing was waiting to send".into()),
            ));
        };
        if choice.starts_with(CONTINUE) {
            // Accept the new checkout as this chat's context, then tell the
            // agent what moved under it.
            let previous = self
                .workspace()
                .and_then(|ws| ws.chat(chat_id).ok().flatten())
                .and_then(|chat| chat.source_context);
            if let Some(current) = self.capture_source_context(&held.request.cwd).await {
                if let Some(drift) = previous.as_ref().and_then(|p| detect(p, &current)) {
                    held.request.prompt =
                        format!("{}\n\n{}", continue_note(&drift), held.request.prompt);
                }
                if let Some(ws) = self.workspace()
                    && let Err(err) = ws.set_chat_source_context(chat_id, &current)
                {
                    tracing::warn!(chat = %chat_id, error = %err, "drift acknowledgement stamp failed");
                }
            }
        } else if let Some(branch) = choice.strip_prefix(SWITCH_BACK) {
            if let Err(err) = self.switch_back(&held.request.cwd, branch).await {
                // Dispatching again re-checks, so a failed switch simply asks
                // again; keep git's reason next to the old question.
                let part_id = format!("{request_id}-switch");
                handle
                    .doc
                    .append_error_part(&entry_id, &part_id, &err.to_string())?;
                handle.publish_messages();
            }
        } else if choice != DONT_SEND {
            // Typed text instead of a choice: it is another message for this
            // chat, not a decision. Hold it with the rest and ask again (or,
            // if the checkout is back where it was, send them all).
            let mut typed = held.request.clone();
            typed.prompt = choice.to_string();
            typed.attachments = Vec::new();
            let harness = held.harness;
            lock(&self.inner.branch_drift_holds)
                .entry(chat_id.to_string())
                .or_default()
                .push(held);
            self.dispatch_with_source_context(sessions, chat_id, harness, typed, Some(new_id()))
                .await?;
            return Ok((SessionCommandStatus::Applied, None));
        } else {
            // Not sent. Freeze the queue too, so the next row does not go
            // straight back into the same question; a new send thaws it.
            handle.queue_paused.store(true, Ordering::Release);
            return Ok((
                SessionCommandStatus::Applied,
                Some("not sent: the branch changed".into()),
            ));
        }
        handle.queue_paused.store(false, Ordering::Release);
        self.dispatch_with_source_context(
            sessions,
            chat_id,
            held.harness,
            held.request,
            held.message_id,
        )
        .await?;
        Ok((SessionCommandStatus::Applied, None))
    }

    async fn switch_back(&self, cwd: &str, branch: &str) -> Result<(), EngineError> {
        let repos = self
            .inner
            .repos
            .get()
            .ok_or_else(|| EngineError::Other("repositories unavailable".into()))?;
        let path = Path::new(cwd);
        // Re-check at answer time: the tree may have changed since we asked.
        if !repos.is_clean(path).await? {
            return Err(EngineError::Other(format!(
                "Didn't switch to {branch}: the checkout has uncommitted changes."
            )));
        }
        repos.switch_ref(path, branch).await.map(|_| ())
    }

    /// After a restart the held dispatch is gone from memory. Rebuild it from
    /// the chat row and the user messages the question holds: those since
    /// the last turn before it, including any sent while it waited, except
    /// `exclude` (the send being handled now, already written). `None` when
    /// it holds none (crash recovery re-runs on its own).
    fn rebuild_held(
        &self,
        chat_id: &str,
        entries: &[SessionMessageEntry],
        question_entry_id: &str,
        exclude: Option<&str>,
    ) -> Option<HeldDispatch> {
        let question = entries.iter().position(|e| e.id == question_entry_id)?;
        let start = entries[..question]
            .iter()
            .rposition(|e| e.role == MessageRole::Assistant)
            .map_or(0, |i| i + 1);
        let held: Vec<&SessionMessageEntry> = entries[start..]
            .iter()
            .filter(|e| e.role == MessageRole::User && Some(e.id.as_str()) != exclude)
            .collect();
        if held.is_empty() {
            return None;
        }
        let message_id = held.last().map(|e| e.id.clone());
        let prompt = held
            .iter()
            .flat_map(|e| e.parts.iter())
            .filter_map(|part| match part {
                MessagePart::Text { text, .. } => Some(text.as_str()),
                _ => None,
            })
            .collect::<Vec<_>>()
            .join("\n\n");
        let request = self.request_from_chat_row(chat_id, &prompt)?;
        Some(HeldDispatch {
            harness: self.harness_for_request(chat_id, &request),
            request,
            message_id,
        })
    }
}

/// Sends that arrived while the question waited go out as one turn, under
/// the last message's id (each is already in the transcript).
fn merge_held(mut held: Vec<HeldDispatch>) -> Option<HeldDispatch> {
    let mut last = held.pop()?;
    if held.is_empty() {
        return Some(last);
    }
    let mut prompts: Vec<String> = held.iter().map(|h| h.request.prompt.clone()).collect();
    prompts.push(std::mem::take(&mut last.request.prompt));
    last.request.prompt = prompts.join("\n\n");
    let mut attachments: Vec<String> = held
        .into_iter()
        .flat_map(|h| h.request.attachments)
        .collect();
    attachments.append(&mut last.request.attachments);
    last.request.attachments = attachments;
    Some(last)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn context(cwd: &str, checkout: &str, branch: &str, head: &str) -> ConversationSourceContext {
        ConversationSourceContext {
            checkout_id: checkout.into(),
            repo_root: cwd.into(),
            cwd: cwd.into(),
            branch: branch.into(),
            head_sha: Some(head.into()),
            observed_at: chrono::Utc::now(),
        }
    }

    #[test]
    fn only_a_changed_branch_or_checkout_in_the_same_folder_drifts() {
        let alpha = context("/repo", "c1", "alpha", "a1");
        assert_eq!(detect(&alpha, &alpha), None);
        assert_eq!(
            detect(&alpha, &context("/repo", "c1", "alpha", "a2")),
            None,
            "a new commit on the same branch is progress"
        );
        assert_eq!(
            detect(&alpha, &context("/elsewhere", "c2", "beta", "b1")),
            None,
            "another folder is a deliberate move"
        );
        assert_eq!(
            detect(&alpha, &context("/repo", "c1", "beta", "b1")),
            Some(Drift {
                from_branch: "alpha".into(),
                to_branch: "beta".into(),
                checkout_replaced: false,
            })
        );
        assert_eq!(
            detect(&alpha, &context("/repo", "c2", "alpha", "a1")),
            Some(Drift {
                from_branch: "alpha".into(),
                to_branch: "alpha".into(),
                checkout_replaced: true,
            })
        );
    }

    #[test]
    fn switch_back_is_offered_only_when_allowed() {
        let drift = Drift {
            from_branch: "alpha".into(),
            to_branch: "beta".into(),
            checkout_replaced: false,
        };
        assert_eq!(
            question(&drift, true).options,
            ["Continue on beta", "Switch back to alpha", "Don't send"]
        );
        assert_eq!(
            question(&drift, false).options,
            ["Continue on beta", "Don't send"]
        );
    }
}
