//! Durable TUI history, separate from Codex's own rollouts. The native agent's
//! resume token stays paired with its agent and cwd; transcript replay is UI only.

use std::path::PathBuf;

use harness_proto::HarnessId;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use uuid::Uuid;

use crate::wire::{RpcError, ThreadState};

pub fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or_default()
}

#[derive(Clone, Serialize, Deserialize)]
pub struct History {
    pub name: Option<String>,
    pub created_at: i64,
    pub updated_at: i64,
    pub turns: Vec<Value>,
}

impl Default for History {
    fn default() -> Self {
        Self {
            name: None,
            created_at: now(),
            updated_at: now(),
            turns: Vec::new(),
        }
    }
}

#[derive(Serialize, Deserialize)]
pub struct SavedSession {
    pub id: String,
    pub cwd: String,
    pub harness: HarnessId,
    pub model: Option<String>,
    pub resume: Option<String>,
    pub history: History,
}

impl SavedSession {
    pub fn capture(id: &str, thread: &ThreadState) -> Self {
        Self {
            id: id.into(),
            cwd: thread.cwd.clone(),
            harness: thread.harness,
            model: thread.model.clone(),
            resume: thread.resume.clone(),
            history: thread.history.clone(),
        }
    }

    pub fn into_thread(mut self) -> ThreadState {
        // A previous bridge exiting in mid-turn cannot leave a phantom live turn.
        for turn in &mut self.history.turns {
            if turn["status"] == "inProgress" {
                turn["status"] = "interrupted".into();
                turn["completedAt"] = now().into();
            }
        }
        ThreadState {
            history: self.history,
            cwd: self.cwd,
            harness: self.harness,
            model: self.model,
            resume: self.resume,
            interrupt: None,
            turn_id: None,
            steer: None,
            steers: Default::default(),
            steerable: false,
        }
    }
}

pub struct SessionStore {
    root: Option<PathBuf>,
}

impl SessionStore {
    pub fn new(root: PathBuf) -> Self {
        Self { root: Some(root) }
    }

    #[cfg(test)]
    pub fn memory() -> Self {
        Self { root: None }
    }

    fn path(&self, id: &str) -> Result<PathBuf, RpcError> {
        let id = Uuid::parse_str(id).map_err(|_| RpcError::invalid_params("invalid threadId"))?;
        let root = self
            .root
            .as_ref()
            .ok_or_else(|| RpcError::invalid_params("unknown threadId"))?;
        Ok(root.join(format!("{id}.json")))
    }

    pub fn read(&self, id: &str) -> Result<SavedSession, RpcError> {
        let bytes = std::fs::read(self.path(id)?)
            .map_err(|e| RpcError::invalid_params(format!("cannot load saved session: {e}")))?;
        let session: SavedSession = serde_json::from_slice(&bytes)
            .map_err(|e| RpcError::internal(format!("invalid saved session: {e}")))?;
        if session.id != id {
            return Err(RpcError::invalid_params("saved session id mismatch"));
        }
        Ok(session)
    }

    pub fn list(&self) -> Result<Vec<SavedSession>, RpcError> {
        let Some(root) = &self.root else {
            return Ok(Vec::new());
        };
        let entries = match std::fs::read_dir(root) {
            Ok(entries) => entries,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
            Err(e) => return Err(RpcError::internal(format!("cannot list sessions: {e}"))),
        };
        let mut sessions = Vec::new();
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().and_then(|x| x.to_str()) != Some("json") {
                continue;
            }
            let Some(id) = path.file_stem().and_then(|x| x.to_str()) else {
                continue;
            };
            match self.read(id) {
                Ok(session) if session.resume.is_some() => sessions.push(session),
                Ok(_) => {}
                Err(error) => {
                    tracing::warn!(message = %error.message, "skipping unreadable TUI session")
                }
            }
        }
        Ok(sessions)
    }

    pub fn save(&self, id: &str, thread: &ThreadState) -> Result<(), RpcError> {
        let Some(root) = &self.root else {
            return Ok(());
        };
        let path = self.path(id)?;
        let write = || -> anyhow::Result<()> {
            std::fs::create_dir_all(root)?;
            let tmp = root.join(format!(".{}.tmp", Uuid::new_v4()));
            let result = (|| -> anyhow::Result<()> {
                use std::io::Write;
                let mut options = std::fs::OpenOptions::new();
                options.write(true).create_new(true);
                #[cfg(unix)]
                {
                    use std::os::unix::fs::OpenOptionsExt;
                    options.mode(0o600);
                }
                let mut file = options.open(&tmp)?;
                serde_json::to_writer(&mut file, &SavedSession::capture(id, thread))?;
                file.flush()?;
                file.sync_all()?;
                std::fs::rename(&tmp, path)?;
                Ok(())
            })();
            if result.is_err() {
                let _ = std::fs::remove_file(tmp);
            }
            result
        };
        write().map_err(|e| RpcError::internal(format!("cannot save TUI session: {e}")))
    }
}
