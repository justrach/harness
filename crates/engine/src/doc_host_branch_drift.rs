//! Branch drift (#354). A chat's checkout can change branch under it: another
//! draft's branch picker switches the shared folder, or someone runs `git
//! switch` outside Harness. Every fresh dispatch (a send, a queued send, an
//! answer to a dead run's question, crash recovery) compares the checkout with
//! the chat's last accepted context. On drift the turn goes ahead, and the
//! agent is told the branch moved so it doesn't assume its earlier work is
//! there. Nothing ever stops to ask, on a shared checkout or any other.
//!
//! Earlier versions asked, and chats they saved can still hold an open
//! question, with messages waiting behind it. Its request id carries
//! [`REQUEST_PREFIX`], which routes the answer here instead of to an agent.
//! Every choice it offered still works, and the next send closes it and takes
//! the waiting messages along. Nothing writes a new one.

use super::*;

pub(super) const REQUEST_PREFIX: &str = "branch-drift-";
const CONTINUE: &str = "Continue on ";
const SWITCH_BACK: &str = "Switch back to ";
const DONT_SEND: &str = "Don't send";
const INDEPENDENT: &str = "Continue independently";
/// Start small, but held user messages can push a question beyond this tail.
const OPEN_QUESTION_TAIL_PARTS: usize = 64;
const HELD_REQUESTS_MAP: &str = "branch_drift_held";

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

/// A shell command that renames a branch: `git branch -m|-M|--move`.
fn is_branch_rename(command: &str) -> bool {
    command.split(['&', ';', '|', '\n']).any(|step| {
        let words: Vec<&str> = step.split_whitespace().collect();
        words
            .iter()
            .position(|word| *word == "git")
            .is_some_and(|git| {
                words[git..]
                    .iter()
                    .position(|word| *word == "branch")
                    .is_some_and(|branch| {
                        words[git + branch..]
                            .iter()
                            .any(|word| matches!(*word, "-m" | "-M" | "--move"))
                    })
            })
    })
}

/// Whether `reflog` (oldest first) since `since` (unix seconds) takes `HEAD`
/// from `from` to `to` through branch renames alone. A checkout, or a rebase
/// that returns to another branch, breaks the chain: a rename followed by a
/// real switch is still a switch.
fn renamed_through(reflog: &[(i64, String)], since: i64, from: &str, to: &str) -> bool {
    let mut branch = from;
    let mut renamed = false;
    for (_, subject) in reflog.iter().filter(|(at, _)| *at >= since) {
        if let Some(rename) = subject.strip_prefix("Branch: renamed refs/heads/") {
            let Some((old, new)) = rename.split_once(" to refs/heads/") else {
                return false;
            };
            if old != branch {
                return false;
            }
            branch = new;
            renamed = true;
        } else if subject.starts_with("checkout:") {
            return false;
        } else if let Some((_, returned)) = subject.split_once("returning to refs/heads/")
            && returned != branch
        {
            return false;
        }
    }
    renamed && branch == to
}

/// A literal fresh-branch checkout and its start point. Anything unsupported
/// counts as drift, so the agent gets told; a mention inside `echo`, a command
/// in another directory, or a forced branch reset is not ownership evidence.
fn branch_creation(command: &str) -> Option<(&str, &str)> {
    // Split simple shell lists without treating quoted commit messages (or
    // quoted mentions of Git commands) as executable steps. Expansion, pipes,
    // background jobs and other shell programs remain deliberately unsupported.
    let mut steps = Vec::new();
    let mut quote = None;
    let mut start = 0;
    let mut chain = 0;
    let mut chars = command.char_indices().peekable();
    while let Some((at, ch)) = chars.next() {
        match quote {
            Some('\'') => {
                if ch == '\'' {
                    quote = None;
                }
            }
            Some('"') => match ch {
                '"' => quote = None,
                '$' | '`' | '\\' => return None,
                _ => {}
            },
            _ => match ch {
                '\'' | '"' => quote = Some(ch),
                '|' | '$' | '`' | '\\' | '(' | ')' | '<' | '>' | '#' => return None,
                '&' => {
                    if chars.next().map(|(_, ch)| ch) != Some('&') {
                        return None;
                    }
                    steps.push((&command[start..at], chain));
                    start = at + 2;
                }
                ';' | '\n' => {
                    steps.push((&command[start..at], chain));
                    start = at + 1;
                    chain += 1;
                }
                _ => {}
            },
        }
    }
    if quote.is_some() {
        return None;
    }
    steps.push((&command[start..], chain));
    let steps: Vec<(Vec<&str>, usize)> = steps
        .iter()
        .map(|(step, chain)| (step.split_whitespace().collect::<Vec<_>>(), *chain))
        .filter(|(words, _)| !words.is_empty())
        .collect();
    if steps.iter().any(|(words, _)| {
        let word = words[0];
        word.contains(['\'', '"', '='])
            || matches!(
                word,
                "cd" | "pushd"
                    | "popd"
                    | "export"
                    | "source"
                    | "."
                    | "eval"
                    | "exit"
                    | "return"
                    | "exec"
                    | "trap"
                    | "set"
                    | "unset"
                    | "alias"
                    | "unalias"
                    | "command"
                    | "builtin"
                    | "if"
                    | "then"
                    | "else"
                    | "elif"
                    | "fi"
                    | "for"
                    | "while"
                    | "until"
                    | "do"
                    | "done"
                    | "case"
                    | "esac"
                    | "select"
                    | "break"
                    | "continue"
                    | "function"
                    | "readonly"
                    | "declare"
                    | "typeset"
                    | "local"
                    | "time"
                    | "!"
                    | "coproc"
                    | "hash"
                    | "read"
                    | "getopts"
                    | "newgrp"
                    | "fc"
                    | "{"
                    | "}"
            )
            || word.starts_with("GIT_")
    }) {
        return None;
    }
    // Only the final nonempty && chain determines a successful shell result.
    // In `false && git switch -c task; true`, the tool succeeds without ever
    // running Git. A later external creation must not inherit that authority.
    let last_chain = steps.last()?.1;
    steps
        .iter()
        .filter(|(_, chain)| *chain == last_chain)
        .find_map(|(words, _)| {
            let ["git", operation, args @ ..] = words.as_slice() else {
                return None;
            };
            let quiet = args
                .iter()
                .take_while(|arg| matches!(**arg, "-q" | "--quiet"))
                .count();
            let [option, branch, rest @ ..] = &args[quiet..] else {
                return None;
            };
            let creates = matches!(
                (*operation, *option),
                ("switch", "-c" | "--create") | ("checkout", "-b")
            );
            if !creates || rest.len() > 1 {
                return None;
            }
            let start = rest.first().copied().unwrap_or("HEAD");
            let literal_ref = |word: &str| {
                !word.is_empty()
                    && !word.starts_with('-')
                    && word
                        .chars()
                        .all(|ch| ch.is_ascii_alphanumeric() || "./_-~^@{}".contains(ch))
            };
            (literal_ref(branch) && literal_ref(start)).then_some((*branch, start))
        })
}

/// Exactly one checkout, from the accepted branch to the fresh branch.
/// Other switches (even away and back), renames, and rebases onto another
/// branch are not covered by an earlier branch-creation command.
fn created_through(reflog: &[(i64, String)], since: i64, from: &str, to: &str) -> bool {
    let expected = format!("checkout: moving from {from} to {to}");
    let mut created = false;
    for (_, subject) in reflog.iter().filter(|(at, _)| *at >= since) {
        if subject.starts_with("checkout:") {
            if created || subject != &expected {
                return false;
            }
            created = true;
        } else if subject.starts_with("Branch: renamed ") {
            return false;
        } else if let Some((_, returned)) = subject.split_once("returning to refs/heads/")
            && returned != if created { to } else { from }
        {
            return false;
        }
    }
    created
}

/// A dispatch waiting on the user's answer. Also stored in the chat document
/// under the question id, preserving attachments and configuration on restart.
#[derive(serde::Serialize, serde::Deserialize)]
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

/// The note the agent gets on a new branch, so it does not assume its earlier
/// work is checked out.
/// The continued prompt, told that the branch moved. A prompt that starts
/// with a command (`/compact`) goes as typed: agents only run a command at
/// the very start of a message, and after the command the note would become
/// its arguments.
fn with_continue_note(drift: &Drift, prompt: &str) -> String {
    if harness_proto::invocation::leading_command(prompt).is_some() {
        return prompt.to_string();
    }
    format!("{}\n\n{prompt}", continue_note(drift))
}

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
    let mut limit = OPEN_QUESTION_TAIL_PARTS;
    loop {
        let tail = handle.doc.read_opening_tail(limit).ok()?;
        if let Some(question) = open_question(&tail) {
            return Some(question);
        }
        // Only user messages can follow an open drift question. Stop at an
        // assistant entry, or the beginning of the transcript; otherwise grow
        // the window so arbitrarily many held sends cannot hide the question.
        if tail
            .iter()
            .any(|entry| entry.role == MessageRole::Assistant)
            || tail
                .iter()
                .map(|entry| entry.parts.len().max(1))
                .sum::<usize>()
                < limit
        {
            return None;
        }
        limit = limit.checked_mul(2)?;
    }
}

impl DocHost {
    fn load_branch_drift_held(
        &self,
        handle: &ChatDocHandle,
        request_id: &str,
    ) -> Result<Option<Vec<HeldDispatch>>, EngineError> {
        let Some(value) = handle.doc.doc().get_map(HELD_REQUESTS_MAP).get(request_id) else {
            return Ok(None); // Compatibility with questions written before this metadata existed.
        };
        let loro::ValueOrContainer::Value(loro::LoroValue::String(json)) = value else {
            return Err(EngineError::Other(
                "invalid held branch-drift requests".into(),
            ));
        };
        let mut held: Vec<HeldDispatch> = serde_json::from_str(&json).map_err(|error| {
            EngineError::Other(format!("invalid held branch-drift requests: {error}"))
        })?;
        for dispatch in &mut held {
            // Persisted paths are not authority to read outside this host's
            // uploads jail, including when the document arrived from a peer.
            self.resolve_request_attachments(&mut dispatch.request);
        }
        Ok(Some(held))
    }

    fn clear_branch_drift_held(
        &self,
        handle: &ChatDocHandle,
        request_id: &str,
    ) -> Result<(), EngineError> {
        handle
            .doc
            .doc()
            .get_map(HELD_REQUESTS_MAP)
            .delete(request_id)
            .map_err(DocError::from)?;
        handle.doc.doc().commit();
        Ok(())
    }

    /// Whether this dispatch would continue the chat on a checkout that
    /// drifted since its last turn. A turn already in flight is not
    /// re-checked: what arrives then is steered into the running turn.
    pub(super) async fn drift_since_last_turn(
        &self,
        sessions: &SessionsEngine,
        chat_id: &str,
        current: &ConversationSourceContext,
    ) -> Option<Drift> {
        if sessions.turn_in_flight(chat_id) {
            return None;
        }
        let previous = self.workspace()?.chat(chat_id).ok()??.source_context?;
        let drift = detect(&previous, current)?;
        if !drift.checkout_replaced
            && self
                .own_turn_changed_branch(chat_id, &previous, &drift)
                .await
        {
            tracing::info!(
                chat = %chat_id,
                from = %drift.from_branch,
                to = %drift.to_branch,
                "branch changed by the chat's own turn; continuing without asking"
            );
            return None;
        }
        Some(drift)
    }

    /// Reconcile a proven rename (#453) or fresh-branch checkout (#732)
    /// performed by this chat, which needs no note: the agent did it. Tool-call
    /// ownership and Git continuity must agree; a successful shell command
    /// alone never covers arbitrary drift.
    async fn own_turn_changed_branch(
        &self,
        chat_id: &str,
        previous: &ConversationSourceContext,
        drift: &Drift,
    ) -> bool {
        let since_ms = previous.observed_at.timestamp_millis();
        let Ok(entries) = self
            .open(chat_id)
            .and_then(|handle| Ok(handle.doc.read_entries()?))
        else {
            return false;
        };
        let mut ran_rename = false;
        let mut creation_start = None;
        for command in entries
            .iter()
            .filter(|entry| entry.role == MessageRole::Assistant && entry.created_at >= since_ms)
            .flat_map(|entry| &entry.parts)
            .filter_map(|part| match part {
                MessagePart::Tool {
                    call: harness_proto::ToolCall::Exec { command },
                    resolved: true,
                    is_error: false,
                    ..
                } => Some(command.as_str()),
                _ => None,
            })
        {
            ran_rename |= is_branch_rename(command);
            if let Some((branch, start)) = branch_creation(command)
                && branch == drift.to_branch
            {
                creation_start = Some(start);
            }
        }
        if !ran_rename && creation_start.is_none() {
            return false;
        }
        let Some(repos) = self.inner.repos.get() else {
            return false;
        };
        let Ok(reflog) = repos.head_reflog(Path::new(&previous.cwd)).await else {
            return false;
        };
        let since = previous.observed_at.timestamp();
        if ran_rename && renamed_through(&reflog, since, &drift.from_branch, &drift.to_branch) {
            return true;
        }
        let Some(start) = creation_start else {
            return false;
        };
        created_through(&reflog, since, &drift.from_branch, &drift.to_branch)
            && repos
                .branch_created_since(Path::new(&previous.cwd), &drift.to_branch, start, since)
                .await
                .unwrap_or(false)
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
        let held = match (&open, held) {
            (_, Some(held)) => Some(held),
            (Some((_, request_id)), None) => self.load_branch_drift_held(&handle, request_id)?,
            (None, None) => None,
        };
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
            self.clear_branch_drift_held(&handle, &request_id)?;
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

    /// Tell the agent the branch moved. The note is for the agent alone, so the
    /// person's message goes in the transcript first, as they sent it (a
    /// message that's already there keeps its id). Returns that message's id.
    pub(super) fn note_branch_change(
        &self,
        chat_id: &str,
        drift: &Drift,
        request: &mut harness_proto::RunRequest,
        message_id: Option<String>,
    ) -> Result<String, EngineError> {
        let id = message_id.unwrap_or_else(new_id);
        self.open(chat_id)?
            .write_user_message(&id, &request.prompt, now_ms())?;
        request.prompt = with_continue_note(drift, &request.prompt);
        tracing::info!(chat = %chat_id, from = %drift.from_branch, to = %drift.to_branch,
            replaced = drift.checkout_replaced, "continuing on a changed checkout");
        Ok(id)
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
            Some(held) => Some(held),
            None => self.load_branch_drift_held(handle, request_id)?,
        };
        let held = match held {
            Some(held) => merge_held(held),
            None => self.rebuild_held(chat_id, &entries, &entry_id, None),
        };
        let choice = answers
            .and_then(|answers| answers.first())
            .and_then(|answer| answer.labels.first())
            .map(String::as_str)
            .unwrap_or(DONT_SEND);
        // Typed text instead of a choice ("go on", or the next instruction)
        // answers "How should it continue?" by continuing: on the branch the
        // question showed, with the text sent after the held messages.
        // Holding it and asking again looped for as long as the user typed.
        let typed = !(choice.starts_with(CONTINUE)
            || choice.starts_with(SWITCH_BACK)
            || choice == INDEPENDENT
            || choice == DONT_SEND);
        let held = if typed {
            let message_id = new_id();
            handle.write_user_message(&message_id, choice, now_ms())?;
            match held {
                Some(mut held) => {
                    held.request.prompt = format!("{}\n\n{choice}", held.request.prompt);
                    held.message_id = Some(message_id);
                    Some(held)
                }
                None => self
                    .request_from_chat_row(chat_id, choice)
                    .map(|request| HeldDispatch {
                        harness: self.harness_for_request(chat_id, &request),
                        request,
                        message_id: Some(message_id),
                    }),
            }
        } else {
            held
        };
        let Some(mut held) = held else {
            handle.doc.resolve_input(request_id)?;
            self.clear_branch_drift_held(handle, request_id)?;
            handle.publish_messages();
            self.save_snapshot(handle);
            return Ok((
                SessionCommandStatus::Applied,
                Some("nothing was waiting to send".into()),
            ));
        };
        let displayed_choice =
            entries
                .iter()
                .find(|entry| entry.id == entry_id)
                .and_then(|entry| {
                    entry.parts.iter().find_map(|part| match part {
                        MessagePart::Input {
                            request_id: id,
                            questions,
                            ..
                        } if id == request_id => questions
                            .first()?
                            .options
                            .iter()
                            .find(|option| option.starts_with(CONTINUE)),
                        _ => None,
                    })
                });
        let choice = if typed {
            displayed_choice.map_or(choice, String::as_str)
        } else {
            choice
        };
        let independent = choice == INDEPENDENT;
        if independent || choice.starts_with(SWITCH_BACK) {
            let offered = entries.iter().find(|entry| entry.id == entry_id)
                .is_some_and(|entry| entry.parts.iter().any(|part| matches!(part,
                    MessagePart::Input { request_id: id, questions, .. }
                        if id == request_id && questions.iter().any(|q| q.options.iter().any(|option| option == choice)))));
            if !offered
                || sessions.turn_in_flight(chat_id)
                || (choice.starts_with(SWITCH_BACK)
                    && self.checkout_is_shared(chat_id, &held.request.cwd))
            {
                lock(&self.inner.branch_drift_holds).insert(chat_id.to_string(), vec![held]);
                return Ok((
                    SessionCommandStatus::Rejected,
                    Some("That checkout action is no longer safe; please retry.".into()),
                ));
            }
        }
        if independent {
            if let Err(error) = self.independent_checkout(handle, &mut held.request).await {
                lock(&self.inner.branch_drift_holds).insert(chat_id.to_string(), vec![held]);
                return Ok((SessionCommandStatus::Rejected, Some(error.to_string())));
            }
            let json = serde_json::to_string(&vec![&held])
                .map_err(|error| EngineError::Other(error.to_string()))?;
            handle
                .doc
                .doc()
                .get_map(HELD_REQUESTS_MAP)
                .insert(request_id, json)
                .map_err(DocError::from)?;
            handle.doc.doc().commit();
            self.save_snapshot(handle);
        }
        let continue_context = if let Some(accepted_branch) = choice.strip_prefix(CONTINUE) {
            let Some(current) = self.capture_source_context(&held.request.cwd).await else {
                // No fresh observation means no consent. Leave the question
                // and its durable request intact so the user can retry.
                lock(&self.inner.branch_drift_holds).insert(chat_id.to_string(), vec![held]);
                return Ok((
                    SessionCommandStatus::Rejected,
                    Some("could not verify the checkout; please retry".into()),
                ));
            };
            if displayed_choice.map(String::as_str) != Some(choice)
                || current.branch != accepted_branch
            {
                // Consent applies only to the displayed branch, never to a
                // newer observation. Dispatch without advancing context, which
                // tells the agent about the branch it's really on.
                handle.doc.resolve_input(request_id)?;
                self.clear_branch_drift_held(handle, request_id)?;
                self.dispatch_with_source_context(
                    sessions,
                    chat_id,
                    held.harness,
                    held.request,
                    held.message_id,
                )
                .await?;
                return Ok((
                    SessionCommandStatus::Applied,
                    Some("the branch changed again".into()),
                ));
            }
            Some(current)
        } else {
            None
        };
        handle.doc.resolve_input(request_id)?;
        self.clear_branch_drift_held(handle, request_id)?;
        handle.publish_messages();
        self.save_snapshot(handle);
        if let Some(current) = continue_context {
            // Accept only the observation that matched the displayed choice.
            let previous = self
                .workspace()
                .and_then(|ws| ws.chat(chat_id).ok().flatten())
                .and_then(|chat| chat.source_context);
            if let Some(drift) = previous.as_ref().and_then(|p| detect(p, &current)) {
                held.request.prompt = with_continue_note(&drift, &held.request.prompt);
            }
            if let Some(ws) = self.workspace()
                && let Err(err) = ws.set_chat_source_context(chat_id, &current)
            {
                tracing::warn!(chat = %chat_id, error = %err, "drift acknowledgement stamp failed");
            }
        } else if independent {
            // The request and durable row now point at the independent tree.
        } else if let Some(branch) = choice.strip_prefix(SWITCH_BACK) {
            if let Err(err) = self.switch_back(chat_id, &held.request.cwd, branch).await {
                // Dispatching again re-checks, so a failed switch simply asks
                // again; keep git's reason next to the old question.
                let part_id = format!("{request_id}-switch");
                handle
                    .doc
                    .append_error_part(&entry_id, &part_id, &err.to_string())?;
                handle.publish_messages();
            }
        } else if choice == DONT_SEND {
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

    async fn switch_back(&self, chat_id: &str, cwd: &str, branch: &str) -> Result<(), EngineError> {
        if self.checkout_is_shared(chat_id, cwd) {
            return Err(EngineError::Other(
                "Didn't switch: another chat uses this checkout.".into(),
            ));
        }
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

    /// Compatibility fallback for older questions without durable request
    /// metadata. Rebuild from the chat row and held user messages: those since
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
    fn only_rename_commands_count_as_renames() {
        assert!(is_branch_rename("git branch -m feature/renamed"));
        assert!(is_branch_rename(
            "cd repo && git branch -M old new && git push"
        ));
        assert!(is_branch_rename("git -C /repo branch --move new"));
        assert!(!is_branch_rename("git branch -d old"));
        assert!(!is_branch_rename("git switch -c new"));
        assert!(!is_branch_rename("git commit -m branch"));
        assert!(!is_branch_rename("echo branch -m"));
    }

    #[test]
    fn a_rename_chain_is_continuity_and_a_switch_is_not() {
        let log = |subjects: &[&str]| -> Vec<(i64, String)> {
            subjects
                .iter()
                .map(|subject| (100, subject.to_string()))
                .collect()
        };
        let renamed = log(&[
            "commit: work",
            "Branch: renamed refs/heads/alpha to refs/heads/beta",
            "commit: more",
        ]);
        assert!(renamed_through(&renamed, 100, "alpha", "beta"));
        let chained = log(&[
            "Branch: renamed refs/heads/alpha to refs/heads/beta",
            "Branch: renamed refs/heads/beta to refs/heads/gamma",
        ]);
        assert!(renamed_through(&chained, 100, "alpha", "gamma"));
        assert!(
            !renamed_through(&renamed, 101, "alpha", "beta"),
            "a rename before the chat's last turn is not this turn's"
        );
        assert!(
            !renamed_through(&log(&["commit: work"]), 100, "alpha", "beta"),
            "a switch to another branch at the same commit is not a rename"
        );
        assert!(!renamed_through(
            &log(&[
                "Branch: renamed refs/heads/alpha to refs/heads/beta",
                "checkout: moving from beta to other",
                "checkout: moving from other to beta",
            ]),
            100,
            "alpha",
            "beta"
        ));
        assert!(!renamed_through(
            &log(&["Branch: renamed refs/heads/zeta to refs/heads/beta"]),
            100,
            "alpha",
            "beta"
        ));
        assert!(!renamed_through(
            &log(&[
                "Branch: renamed refs/heads/alpha to refs/heads/beta",
                "rebase (finish): returning to refs/heads/other",
            ]),
            100,
            "alpha",
            "other"
        ));
    }

    #[test]
    fn only_literal_fresh_branch_commands_prove_creation() {
        for command in [
            "git switch -c feature/example",
            "git switch -q --create feature/example",
            "git checkout -b feature/example",
        ] {
            assert_eq!(branch_creation(command), Some(("feature/example", "HEAD")));
        }
        assert_eq!(
            branch_creation(
                "git fetch upstream && git switch -c feature/example upstream/main && git status"
            ),
            Some(("feature/example", "upstream/main"))
        );
        assert_eq!(
            branch_creation("git checkout -q -b feature/example HEAD~1"),
            Some(("feature/example", "HEAD~1"))
        );
        assert_eq!(
            branch_creation("git switch -c feature/example && git commit -m 'task; work'"),
            Some(("feature/example", "HEAD"))
        );
        for command in [
            "git switch feature/example",
            "git switch -C feature/example",
            "git checkout -B feature/example",
            "git branch feature/example",
            "echo git switch -c feature/example",
            "echo 'git switch -c feature/example'",
            "echo 'example; git switch -c feature/example'",
            "echo \"example && git switch -c feature/example\"",
            "GIT_DIR=elsewhere; git switch -c feature/example",
            "\"cd\" elsewhere && git switch -c feature/example",
            "cd elsewhere && git switch -c feature/example",
            "git -C elsewhere switch -c feature/example",
            "GIT_DIR=elsewhere git switch -c feature/example",
            "git switch -c $branch",
            "git switch -c feature/example || true",
            "git switch -c feature/example & wait",
        ] {
            assert_eq!(branch_creation(command), None, "{command}");
        }
    }

    #[test]
    fn branch_creation_requires_a_success_determining_chain() {
        for command in [
            "git fetch upstream; git switch -c feature/example && git status",
            "git status\ngit switch -c feature/example;\n",
            "git switch -c feature/example && git commit -m \"safe; quoted && text\"",
        ] {
            assert_eq!(
                branch_creation(command),
                Some(("feature/example", "HEAD")),
                "{command}"
            );
        }
        for command in [
            "false && git switch -c feature/example; true",
            "git switch -c feature/example; git status",
            "git switch -c feature/example\ntrue",
            "if false; then\ngit switch -c feature/example\nfi",
            "exit 0; git switch -c feature/example",
            "e''xit 0; git switch -c feature/example",
            "{ exit 0; }; git switch -c feature/example",
            "PATH=elsewhere; git switch -c feature/example",
            "NAME=value exit 0; git switch -c feature/example",
            "function git { true; }; git switch -c feature/example",
            "exec true; git switch -c feature/example",
            "time exit 0; git switch -c feature/example",
            "! exit 0; git switch -c feature/example",
            "hash -p /usr/bin/true git; git switch -c feature/example",
            "trap 'exit 0' EXIT; false && git switch -c feature/example",
            "git switch -c feature/example && echo 'unterminated",
            "git switch -c feature/example && echo \"$variable\"",
            "git switch -c feature/example && echo `true`",
        ] {
            assert_eq!(branch_creation(command), None, "{command}");
        }
    }

    #[test]
    fn only_one_matching_creation_checkout_is_continuity() {
        let checkout = "checkout: moving from alpha to beta";
        let log = |subjects: &[&str]| -> Vec<(i64, String)> {
            subjects
                .iter()
                .map(|subject| (100, subject.to_string()))
                .collect()
        };
        assert!(created_through(
            &log(&["commit: before", checkout, "commit: after"]),
            100,
            "alpha",
            "beta"
        ));
        for subjects in [
            vec![],
            vec![checkout, "checkout: moving from beta to other"],
            vec![checkout, "checkout: moving from beta to alpha", checkout],
            vec!["checkout: moving from other to beta"],
            vec![
                "Branch: renamed refs/heads/alpha to refs/heads/other",
                checkout,
            ],
            vec![checkout, "rebase (finish): returning to refs/heads/other"],
        ] {
            assert!(
                !created_through(&log(&subjects), 100, "alpha", "beta"),
                "{subjects:?}"
            );
        }
        assert!(!created_through(&log(&[checkout]), 101, "alpha", "beta"));
    }
}
