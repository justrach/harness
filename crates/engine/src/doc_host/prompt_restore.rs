//! Restoration belongs to accepted prompts, never to opening a document.
//! Receipts are staged before acceptance and replay metadata only. The original
//! registry clock fences retries against a later explicit archive.
use super::*;

const RESTORE_JOB: &str = "prompt-restore";

#[cfg(test)]
mod tests;

#[derive(serde::Serialize, serde::Deserialize)]
pub(super) struct PromptRestore {
    chat_id: String,
    clock: String,
    #[serde(default)]
    accepted: bool,
}

impl DocHost {
    pub(super) fn stage_prompt_restore(
        &self,
        chat_id: &str,
        submission_id: &str,
    ) -> Result<PromptRestore, EngineError> {
        let clock = self.workspace().map_or_else(
            || harness_doc::encode_hlc(now_ms(), 1, &self.inner.config.device_id),
            |workspace| workspace.chat_prompt_clock(chat_id),
        );
        let receipt = PromptRestore {
            chat_id: chat_id.into(),
            clock,
            accepted: false,
        };
        self.inner.store.schedule_sync_job_with_cursor(
            submission_id,
            RESTORE_JOB,
            &serde_json::to_string(&receipt)
                .map_err(|error| EngineError::Other(error.to_string()))?,
        )?;
        Ok(receipt)
    }

    pub(super) fn accept_prompt_restore(&self, submission_id: &str, mut receipt: PromptRestore) {
        receipt.accepted = true;
        let saved = serde_json::to_string(&receipt)
            .map_err(|error| EngineError::Other(error.to_string()))
            .and_then(|data| {
                self.inner
                    .store
                    .schedule_sync_job_with_cursor(submission_id, RESTORE_JOB, &data)
                    .map_err(EngineError::from)
            });
        if let Err(error) = saved {
            // The staged receipt plus the command/queue identity remains the
            // recovery path. Never turn acceptance into a duplicate-send retry.
            tracing::warn!(%error, "prompt restoration acceptance pending; will recover from document");
        }
        self.finish_prompt_restore(submission_id, &receipt);
    }

    pub(super) fn cancel_prompt_restore(&self, submission_id: &str) {
        if let Ok(Some(version)) = self
            .inner
            .store
            .sync_job_version(submission_id, RESTORE_JOB)
        {
            let _ = self
                .inner
                .store
                .complete_sync_job(submission_id, RESTORE_JOB, version);
        }
    }

    /// Never fail an already-accepted send: a caller retry could duplicate it.
    pub(super) fn finish_prompt_restore(&self, submission_id: &str, receipt: &PromptRestore) {
        let Some(workspace) = self.workspace() else {
            return;
        };
        match workspace.restore_chat_on_send(&receipt.chat_id, &receipt.clock) {
            Ok(true) => self.cancel_prompt_restore(submission_id),
            Ok(false) => {} // Metadata will arrive independently of the prompt.
            Err(error) => {
                tracing::warn!(chat = %receipt.chat_id, %error, "prompt restoration pending; will retry")
            }
        }
    }

    pub(super) fn retry_prompt_restores(&self, cursor: &mut String) {
        let Some(workspace) = self.workspace() else {
            return;
        };
        let _restore = lock(&self.inner.prompt_restore);
        let result = (|| -> Result<(), EngineError> {
            let page = self.inner.store.pending_sync_jobs(RESTORE_JOB, cursor, 4)?;
            if page.is_empty() {
                cursor.clear();
            }
            for id in page {
                *cursor = id.clone();
                let Some((_, data)) = self.inner.store.sync_job(&id, RESTORE_JOB)? else {
                    continue;
                };
                let receipt: PromptRestore = serde_json::from_str(&data)
                    .map_err(|error| EngineError::Other(error.to_string()))?;
                // Do not cold-open unknown metadata on every scheduler tick.
                if workspace.chat(&receipt.chat_id)?.is_none() {
                    continue;
                }
                if receipt.accepted {
                    self.finish_prompt_restore(&id, &receipt);
                    continue;
                }
                let handle = self.open(&receipt.chat_id)?;
                // A crash between staging and acceptance must not restore a
                // reference-only chat. Evidence may now be in the transcript
                // if an accepted queued message has already been dispatched.
                let accepted = handle
                    .doc
                    .read_commands()?
                    .iter()
                    .any(|entry| entry.id == id)
                    || handle.doc.read_queue()?.iter().any(|entry| entry.id == id)
                    || handle
                        .doc
                        .read_entries()?
                        .iter()
                        .any(|entry| entry.id == id && entry.role == MessageRole::User);
                if accepted {
                    self.finish_prompt_restore(&id, &receipt);
                }
            }
            Ok(())
        })();
        if let Err(error) = result {
            tracing::warn!(%error, "prompt restoration pass failed; will retry");
        }
    }
}
