//! harness-mobile — the Android app's native core.
//!
//! The phone is a viewer device: agents run on desktop hosts, and the phone mirrors the workspace registry and the
//! chat2 session docs and appends commands for a host to drain. The protocol lives in `harness-doc` and
//! `harness-sync`; this crate exposes the viewer side of it to Kotlin with UniFFI, so the Android app does not carry
//! its own copy of the registry merge rules or the chat2 client.
//!
//! The iOS app keeps its Swift sync code (`apps/ios/Harness/Sync`), which is the behavioral reference: the
//! projections, viewer writes and transcript decoding here are ports of it. Rules both phones must agree on are
//! pinned in `apps/parity`.

uniffi::setup_scaffolding!();

mod decode;
mod edge;
mod logging;
mod projection;
pub mod records;
mod session;
mod workspace;
mod writes;

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

pub use edge::TokenSource;
pub use logging::{LogSink, install_log_sink};
use records::{SessionSnapshot, WorkspaceSnapshot};
use session::Session;
use workspace::{Workspace, lock, now_ms};
pub use writes::NewChatConfig;

/// The version of the native core, which is the workspace version it was built from.
#[uniffi::export]
pub fn core_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

/// A registry hybrid logical clock, `{ms:013}-{counter:06}-{device}` (crates/doc `encode_hlc`).
#[uniffi::export]
pub fn encode_hlc(ms: i64, counter: u32, device: String) -> String {
    harness_doc::encode_hlc(ms, counter, &device)
}

/// Where and as whom to sync.
#[derive(Debug, Clone, uniffi::Record)]
pub struct CoreConfig {
    /// `https://edge.codegraff.com`, or a dev edge.
    pub edge_url: String,
    pub org_id: String,
    pub user_id: String,
    /// This phone's id, stamped on its writes and presence.
    pub device_id: String,
    /// A directory private to this signed-in identity; the docs are kept here.
    pub data_dir: String,
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum CoreError {
    #[error("the local store could not be opened: {reason}")]
    Store { reason: String },
    #[error("not valid input: {reason}")]
    Invalid { reason: String },
}

fn invalid(err: serde_json::Error) -> CoreError {
    CoreError::Invalid {
        reason: err.to_string(),
    }
}

/// A session doc's transcript and queue, decoded.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct DecodedSession {
    pub entries: Vec<records::MessageEntryRecord>,
    pub queue: Vec<records::QueuedMessageRecord>,
}

/// The registry projection over rows given as JSON (`RegistryRow`s, as the edge sends them). For the shared parity
/// vectors (apps/parity), which the iOS app runs through its own `WorkspaceStore`.
#[uniffi::export]
pub fn project_registry_rows(rows_json: String) -> Result<WorkspaceSnapshot, CoreError> {
    let rows: Vec<harness_doc::RegistryRow> = serde_json::from_str(&rows_json).map_err(invalid)?;
    let mut doc = harness_doc::RegistryDoc::new("parity");
    doc.apply_state(1, true, 0, rows);
    Ok(WorkspaceSnapshot {
        devices: projection::devices(&doc),
        spaces: projection::spaces(&doc),
        chats: projection::chats(&doc),
        sessions: projection::sessions(&doc),
        pinned_session_ids: projection::pinned_session_ids(&doc),
        pins_initialized: projection::pins_initialized(&doc),
        desktop_appearance: projection::desktop_appearance(&doc),
        presence: HashMap::new(),
        connected: false,
        synced: true,
    })
}

/// Transcript decoding over a doc's `messages` and `queue` lists given as JSON. For the shared parity vectors.
#[uniffi::export]
pub fn decode_session_doc(
    messages_json: String,
    queue_json: String,
) -> Result<DecodedSession, CoreError> {
    let messages: serde_json::Value = serde_json::from_str(&messages_json).map_err(invalid)?;
    let queue: serde_json::Value = serde_json::from_str(&queue_json).map_err(invalid)?;
    Ok(DecodedSession {
        entries: decode::entries(&messages),
        queue: decode::queue(&queue),
    })
}

/// Receives every projection. Called from the core's own threads.
#[uniffi::export(with_foreign)]
pub trait CoreListener: Send + Sync {
    fn workspace_changed(&self, snapshot: WorkspaceSnapshot);
    fn session_changed(&self, snapshot: SessionSnapshot);
}

/// `AppModel.warmStoreCap` on iOS: sessions kept warm (hydrated and joined) without a view.
const WARM_SESSION_CAP: usize = 12;

struct Sessions {
    open: HashMap<String, Arc<Session>>,
    /// Least recently used first.
    order: Vec<String>,
}

/// The sync engine for one signed-in identity: the workspace registry and the session docs the screens open.
#[derive(uniffi::Object)]
pub struct MobileCore {
    runtime: tokio::runtime::Runtime,
    edge: edge::Edge,
    store: Arc<harness_sync::DocsStore>,
    listener: Arc<dyn CoreListener>,
    workspace: Arc<Workspace>,
    sessions: Arc<Mutex<Sessions>>,
}

#[uniffi::export]
impl MobileCore {
    /// Open the local store and load the cached workspace. Nothing dials until `start`.
    #[uniffi::constructor]
    pub fn new(
        config: CoreConfig,
        tokens: Arc<dyn TokenSource>,
        listener: Arc<dyn CoreListener>,
    ) -> Result<Arc<Self>, CoreError> {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("harness-sync")
            .enable_all()
            .build()
            .map_err(|e| CoreError::Store {
                reason: e.to_string(),
            })?;
        let store = Arc::new(
            harness_sync::DocsStore::open(&config.data_dir).map_err(|e| CoreError::Store {
                reason: e.to_string(),
            })?,
        );
        let edge = edge::Edge::new(&config.edge_url, &config.org_id, &config.device_id, tokens);
        let sessions = Arc::new(Mutex::new(Sessions {
            open: HashMap::new(),
            order: Vec::new(),
        }));
        let workspace = {
            let _guard = runtime.enter();
            let listener = listener.clone();
            let sessions = sessions.clone();
            Workspace::new(
                edge.clone(),
                store.clone(),
                Box::new(move |snapshot: &WorkspaceSnapshot| {
                    // The registry names each chat's room generation; a flip to chat2 lets its open session dial.
                    let open: Vec<Arc<Session>> = lock(&sessions).open.values().cloned().collect();
                    for session in open {
                        if let Some(chat) = snapshot
                            .chats
                            .iter()
                            .find(|chat| chat.id == session.chat_id)
                        {
                            session.update_room_gen(chat.room_gen);
                        }
                    }
                    listener.workspace_changed(snapshot.clone());
                }),
            )
        };
        Ok(Arc::new(Self {
            runtime,
            edge,
            store,
            listener,
            workspace,
            sessions,
        }))
    }

    /// Publish the cached workspace, then join the registry room.
    pub fn start(&self) {
        let _guard = self.runtime.enter();
        self.workspace.start();
    }

    pub fn workspace(&self) -> WorkspaceSnapshot {
        self.workspace.snapshot()
    }

    /// A session screen opened: hydrate the chat from disk, dial its room, and decode it at frame rate. Returns what
    /// the doc holds now; later changes arrive through the listener.
    pub fn open_session(&self, chat_id: String) -> SessionSnapshot {
        let _guard = self.runtime.enter();
        let session = self.session(&chat_id);
        session.attach();
        session.snapshot()
    }

    /// The session screen went away. The chat stays warm (live, cheaper to reopen) until it is among the coldest.
    pub fn close_session(&self, chat_id: String) {
        if let Some(session) = lock(&self.sessions).open.get(&chat_id) {
            session.detach();
        }
        self.evict_cold();
    }

    // ── registry writes (viewer discipline) ─────────────────────────────────────────────────────────────────────

    pub fn set_archived(&self, chat_id: String, archived: bool) -> bool {
        let _guard = self.runtime.enter();
        self.workspace
            .write(|doc, _| writes::set_archived(doc, &chat_id, archived))
    }

    pub fn rename(&self, chat_id: String, title: String) -> bool {
        let _guard = self.runtime.enter();
        self.workspace
            .write(|doc, _| writes::rename(doc, &chat_id, &title))
    }

    pub fn set_pinned(&self, chat_id: String, pinned: bool) -> bool {
        let _guard = self.runtime.enter();
        self.workspace
            .write(|doc, synced| writes::set_pinned(doc, &chat_id, pinned, synced))
    }

    pub fn mark_seen(&self, chat_id: String) -> bool {
        let _guard = self.runtime.enter();
        self.workspace
            .write(|doc, _| writes::mark_seen(doc, &chat_id, now_ms()))
    }

    pub fn set_chat_config(&self, chat_id: String, config: NewChatConfig) -> bool {
        let _guard = self.runtime.enter();
        self.workspace
            .write(|doc, _| writes::set_chat_config(doc, &chat_id, &config))
    }

    pub fn set_chat_checkout(&self, chat_id: String, cwd: String, branch: String) -> bool {
        let _guard = self.runtime.enter();
        self.workspace
            .write(|doc, _| writes::set_chat_checkout(doc, &chat_id, &cwd, &branch))
    }

    /// Mint a session on a computer, in a project (`space_id`) or not. The host picks it up from the registry.
    pub fn create_chat(
        &self,
        device_id: String,
        space_id: Option<String>,
        cwd: String,
        config: NewChatConfig,
        branch: Option<String>,
    ) -> String {
        let _guard = self.runtime.enter();
        let chat_id = uuid::Uuid::new_v4().to_string().to_lowercase();
        self.workspace.write(|doc, _| {
            writes::create_chat(
                doc,
                &chat_id,
                &device_id,
                space_id.as_deref(),
                &cwd,
                &config,
                branch.as_deref(),
                now_ms(),
            );
            true
        });
        chat_id
    }

    /// Add a project folder on a computer; an existing (device, path) pair returns its id.
    pub fn create_space(&self, device_id: String, path: String, git_detected: bool) -> String {
        let _guard = self.runtime.enter();
        let fresh = uuid::Uuid::new_v4().to_string().to_lowercase();
        let mut id = fresh.clone();
        self.workspace.write(|doc, _| {
            id = writes::create_space(doc, &fresh, &device_id, &path, git_detected, now_ms());
            id == fresh
        });
        id
    }

    pub fn delete_chat(&self, chat_id: String) {
        let _guard = self.runtime.enter();
        self.workspace.write(|doc, _| {
            writes::delete_chat(doc, &chat_id);
            true
        });
    }

    pub fn delete_space(&self, space_id: String) {
        let _guard = self.runtime.enter();
        self.workspace.write(|doc, _| {
            writes::delete_space(doc, &space_id);
            true
        });
    }

    // ── lifecycle ───────────────────────────────────────────────────────────────────────────────────────────────

    /// The app came to the front: revive the registry room, and the open rooms after it.
    pub fn foregrounded(&self) {
        let _guard = self.runtime.enter();
        self.workspace.kick();
        let open: Vec<Arc<Session>> = lock(&self.sessions).open.values().cloned().collect();
        for session in open {
            session.kick();
        }
    }

    /// Persist everything now (the app is going to the background).
    pub fn flush(&self) {
        let _guard = self.runtime.enter();
        self.workspace.flush();
        let open: Vec<Arc<Session>> = lock(&self.sessions).open.values().cloned().collect();
        for session in open {
            session.flush();
        }
    }

    /// Leave every room and persist. The core cannot be started again.
    pub fn stop(&self) {
        let sessions: Vec<Arc<Session>> = {
            let mut s = lock(&self.sessions);
            s.order.clear();
            s.open.drain().map(|(_, session)| session).collect()
        };
        let workspace = self.workspace.clone();
        self.runtime.block_on(async move {
            for session in sessions {
                session.stop().await;
            }
            workspace.stop().await;
        });
    }
}

impl MobileCore {
    fn session(&self, chat_id: &str) -> Arc<Session> {
        let mut sessions = lock(&self.sessions);
        sessions.order.retain(|id| id != chat_id);
        sessions.order.push(chat_id.to_owned());
        if let Some(existing) = sessions.open.get(chat_id) {
            return existing.clone();
        }
        let listener = self.listener.clone();
        let session = Session::open(
            chat_id,
            self.edge.clone(),
            self.store.clone(),
            Arc::new(move |snapshot| listener.session_changed(snapshot)),
        );
        let room_gen = self
            .workspace
            .chats()
            .into_iter()
            .find(|chat| chat.id == chat_id)
            .and_then(|chat| chat.room_gen);
        session.update_room_gen(room_gen);
        sessions.open.insert(chat_id.to_owned(), session.clone());
        session
    }

    /// Keep at most [`WARM_SESSION_CAP`] sessions, stopping the least recently used ones that are not on screen and
    /// not streaming.
    fn evict_cold(&self) {
        let evicted: Vec<Arc<Session>> = {
            let mut sessions = lock(&self.sessions);
            let mut evicted = Vec::new();
            let mut index = 0;
            while sessions.open.len() > WARM_SESSION_CAP && index < sessions.order.len() {
                let id = sessions.order[index].clone();
                let protected = sessions
                    .open
                    .get(&id)
                    .is_some_and(|session| session.is_attached() || session.is_streaming());
                if protected {
                    index += 1;
                    continue;
                }
                sessions.order.remove(index);
                if let Some(session) = sessions.open.remove(&id) {
                    evicted.push(session);
                }
            }
            evicted
        };
        for session in evicted {
            self.runtime.spawn(async move { session.stop().await });
        }
    }
}
