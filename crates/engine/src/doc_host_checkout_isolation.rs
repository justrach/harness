//! Recovery for older conversations that share a primary checkout. A fork
//! moves only one chat; it never switches, stashes, or copies the shared tree.

use super::*;

const STATE: &str = "checkout_isolation";
const SHARED_CONSENT: &str = "shared_consent";
const MOVE: &str = "move";

#[derive(serde::Serialize, serde::Deserialize)]
struct CheckoutMove {
    device_id: String,
    from: String,
    to: String,
    branch: String,
    checkout_id: String,
}

fn same_checkout(left: &str, right: &str) -> bool {
    let canonical =
        |path: &str| std::fs::canonicalize(path).unwrap_or_else(|_| Path::new(path).to_path_buf());
    canonical(left) == canonical(right)
}

impl DocHost {
    /// Archived rows count too: reopening one must not silently change another
    /// conversation's branch. Failure to inspect ownership forbids switching.
    pub(super) fn checkout_is_shared(&self, chat_id: &str, cwd: &str) -> bool {
        let Some(workspace) = self.workspace() else {
            return true;
        };
        let Ok(chats) = workspace.read_chats() else {
            return true;
        };
        chats.iter().any(|chat| {
            chat.id != chat_id
                && chat.device_id == self.inner.config.device_id
                && chat
                    .cwd
                    .as_deref()
                    .or_else(|| {
                        chat.source_context
                            .as_ref()
                            .map(|source| source.cwd.as_str())
                    })
                    .is_some_and(|other| same_checkout(other, cwd))
        })
    }

    pub(super) fn unacknowledged_shared_checkout(
        &self,
        chat_id: &str,
        current: &ConversationSourceContext,
    ) -> bool {
        // Existing independent worktrees keep their location and history.
        if crate::workspace_host::linked_worktree_root(Path::new(&current.cwd)).is_some()
            || !self.checkout_is_shared(chat_id, &current.cwd)
        {
            return false;
        }
        let Ok(handle) = self.open(chat_id) else {
            return true;
        };
        let expected = serde_json::to_string(&(
            &self.inner.config.device_id,
            &current.checkout_id,
            &current.branch,
        ))
        .ok();
        let consent = handle.doc.doc().get_map(STATE).get(SHARED_CONSENT);
        !matches!(consent,
            Some(loro::ValueOrContainer::Value(loro::LoroValue::String(value)))
                if Some(value.as_str()) == expected.as_deref())
    }

    pub(super) fn acknowledge_shared_checkout(
        &self,
        handle: &ChatDocHandle,
        current: &ConversationSourceContext,
    ) -> Result<(), EngineError> {
        let consent = serde_json::to_string(&(
            &self.inner.config.device_id,
            &current.checkout_id,
            &current.branch,
        ))
        .map_err(|error| EngineError::Other(error.to_string()))?;
        handle
            .doc
            .doc()
            .get_map(STATE)
            .insert(SHARED_CONSENT, consent)
            .map_err(DocError::from)?;
        handle.doc.doc().commit();
        Ok(())
    }

    fn checkout_move(&self, handle: &ChatDocHandle) -> Result<Option<CheckoutMove>, EngineError> {
        let Some(value) = handle.doc.doc().get_map(STATE).get(MOVE) else {
            return Ok(None);
        };
        let loro::ValueOrContainer::Value(loro::LoroValue::String(json)) = value else {
            return Err(EngineError::Other(
                "invalid independent-checkout receipt".into(),
            ));
        };
        let moved: CheckoutMove = serde_json::from_str(&json).map_err(|error| {
            EngineError::Other(format!("invalid independent-checkout receipt: {error}"))
        })?;
        Ok((moved.device_id == self.inner.config.device_id).then_some(moved))
    }

    /// Commands queued before a move still contain the old cwd. Retarget them
    /// only while the chat still owns this move's destination, never a later
    /// explicit move. The durable receipt also covers restart/retry.
    pub(super) fn retarget_independent_request(
        &self,
        chat_id: &str,
        request: &mut harness_proto::RunRequest,
    ) -> Result<(), EngineError> {
        let handle = self.open(chat_id)?;
        let Some(moved) = self.checkout_move(&handle)? else {
            return Ok(());
        };
        let target = self
            .workspace()
            .and_then(|ws| ws.chat(chat_id).ok().flatten())
            .and_then(|chat| chat.cwd);
        if target
            .as_deref()
            .is_some_and(|cwd| same_checkout(cwd, &moved.to))
            && same_checkout(&request.cwd, &moved.from)
        {
            request.cwd = moved.to;
            request.worktree = None;
            request.resume = None;
        }
        Ok(())
    }

    /// Persist the allocated destination before rehoming, so a retried answer
    /// reuses it. The base is the conversation's recorded committed snapshot,
    /// not whatever unrelated branch the shared directory currently contains.
    pub(super) async fn independent_checkout(
        &self,
        handle: &ChatDocHandle,
        request: &mut harness_proto::RunRequest,
    ) -> Result<(), EngineError> {
        let workspace = self
            .workspace()
            .ok_or_else(|| EngineError::Other("workspace unavailable".into()))?;
        let chat = workspace
            .chat(&handle.chat_id)?
            .ok_or_else(|| EngineError::Other("chat not found".into()))?;
        let existing = self.checkout_move(handle)?;
        let moved = if let Some(moved) = existing.filter(|moved| {
            same_checkout(&request.cwd, &moved.from) || same_checkout(&request.cwd, &moved.to)
        }) {
            moved
        } else {
            let previous = chat.source_context.ok_or_else(|| {
                EngineError::Other(
                    "Cannot isolate without a recorded checkout; select a base explicitly.".into(),
                )
            })?;
            if !same_checkout(&previous.cwd, &request.cwd) {
                return Err(EngineError::Other(
                    "The chat moved while confirmation was open; please retry.".into(),
                ));
            }
            let base = previous
                .head_sha
                .as_deref()
                .filter(|head| !head.is_empty())
                .or_else(|| (previous.branch != "HEAD").then_some(previous.branch.as_str()))
                .ok_or_else(|| {
                    EngineError::Other("The previous committed checkout is unavailable.".into())
                })?;
            let repos = self
                .inner
                .repos
                .get()
                .ok_or_else(|| EngineError::Other("repositories unavailable".into()))?;
            let task = chat
                .title
                .as_deref()
                .filter(|title| !title.trim().is_empty())
                .unwrap_or(&request.prompt);
            let tree = repos
                .create_worktree_for_task(Path::new(&previous.repo_root), base, task)
                .await?;
            let source = self
                .capture_source_context(&tree.path)
                .await
                .ok_or_else(|| EngineError::Other("Could not verify the new worktree.".into()))?;
            let moved = CheckoutMove {
                device_id: self.inner.config.device_id.clone(),
                from: request.cwd.clone(),
                to: tree.path,
                branch: tree.branch,
                checkout_id: source.checkout_id,
            };
            let json = serde_json::to_string(&moved)
                .map_err(|error| EngineError::Other(error.to_string()))?;
            handle
                .doc
                .doc()
                .get_map(STATE)
                .insert(MOVE, json)
                .map_err(DocError::from)?;
            handle.doc.doc().commit();
            self.save_snapshot(handle);
            moved
        };
        let source = self
            .capture_source_context(&moved.to)
            .await
            .ok_or_else(|| {
                EngineError::Other(
                    "The independent worktree is unavailable; no shared checkout was changed."
                        .into(),
                )
            })?;
        if source.checkout_id != moved.checkout_id {
            return Err(EngineError::Other(
                "The independent worktree was replaced; please choose a checkout explicitly."
                    .into(),
            ));
        }
        workspace.set_chat_cwd(&handle.chat_id, &moved.to)?;
        workspace.set_chat_branch(&handle.chat_id, &moved.branch)?;
        workspace.set_chat_checkout(&handle.chat_id, &moved.checkout_id)?;
        workspace.flush();
        request.cwd = moved.to;
        request.worktree = None;
        request.resume = None;
        Ok(())
    }
}
