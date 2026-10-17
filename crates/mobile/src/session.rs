//! One chat's session doc, the phone's counterpart of the iOS `SessionStore` read path: the Loro doc hydrated from
//! disk before anything dials, joined to its chat2 room by `harness_sync::ChatClient` (socket plus HTTPS) once the
//! registry says the chat is on room generation 2, persisted with its room cursor in one transaction, and decoded
//! for the screens the way iOS decodes it.

use std::sync::atomic::{AtomicBool, AtomicI64, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use harness_doc::SessionDoc;
use harness_sync::chat_client::{ChatDocSink, RowImportOutcome};
use harness_sync::{ChatClient, ChatEvent, DocsStore};
use loro::{LoroDoc, ToJson};
use tokio::sync::Notify;
use tokio::task::JoinHandle;

use crate::decode;
use crate::edge::Edge;
use crate::records::SessionSnapshot;
use crate::workspace::lock;

/// docs/chat2-sync.md M1: chat2 docs are lineage epoch 2.
const CHAT2_DOC_EPOCH: u32 = 2;
/// Coalesced snapshot writes, as the desktop's chat persister does.
const SAVE_INTERVAL: Duration = Duration::from_secs(1);
/// A burst of streamed tokens re-decodes once per frame-ish while the chat is on screen…
const PROJECT_ATTACHED: Duration = Duration::from_millis(33);
/// …and at most once a second while it is not (`SessionStore.project`).
const PROJECT_DETACHED: Duration = Duration::from_secs(1);
/// Remote imports carry this origin (the iOS store imports with "remote").
const REMOTE_ORIGIN: &str = "remote";

/// Where remote bytes land: imports into the doc, tracks the contiguous applied cursor, and persists the snapshot
/// with that cursor (sampled before export, so disk may lag but never skips a row).
pub(crate) struct MobileSink {
    chat_id: String,
    doc: Arc<LoroDoc>,
    store: Arc<DocsStore>,
    cursor: AtomicU64,
    verified: bool,
    generation: AtomicU64,
    saved: AtomicU64,
    urgent: AtomicBool,
    save: Arc<Notify>,
    write: Mutex<()>,
}

impl MobileSink {
    fn dirty(&self, immediate: bool) {
        self.generation.fetch_add(1, Ordering::AcqRel);
        if immediate {
            self.urgent.store(true, Ordering::Release);
        }
        self.save.notify_one();
    }

    fn applied(&self, cursor: u64, immediate: bool) {
        self.cursor.fetch_max(cursor, Ordering::AcqRel);
        self.dirty(immediate);
    }

    /// Write the snapshot and its cursor in one transaction, if anything changed since the last write.
    pub fn flush(&self) {
        let _write = lock(&self.write);
        let generation = self.generation.load(Ordering::Acquire);
        if generation == self.saved.load(Ordering::Acquire) {
            return;
        }
        // Never read the cursor after exporting: a concurrent import could label an older snapshot with a newer
        // cursor.
        let cursor = self.cursor.load(Ordering::Acquire);
        let result = self
            .doc
            .export(loro::ExportMode::Snapshot)
            .map_err(|e| e.to_string())
            .and_then(|bytes| {
                self.store
                    .save_verified_snapshot_with_cursor(
                        &self.chat_id,
                        &bytes,
                        cursor,
                        CHAT2_DOC_EPOCH,
                    )
                    .map_err(|e| e.to_string())
            });
        match result {
            Ok(()) => self.saved.store(generation, Ordering::Release),
            Err(error) => {
                tracing::warn!(chat = %self.chat_id, %error, "chat snapshot failed; retrying")
            }
        }
    }

    fn import(&self, bytes: &[u8], cursor: u64) -> RowImportOutcome {
        match self.doc.import_with(bytes, REMOTE_ORIGIN) {
            Ok(status) if status.pending.is_some() => {
                // Contiguous room seqs do not prove causal history is present, and a snapshot omits parked ops:
                // the cursor must not move past them.
                tracing::warn!(chat = %self.chat_id, cursor, "chat2: row parked on missing deps; requesting repair");
                return RowImportOutcome::PendingDependencies;
            }
            Ok(_) => {}
            Err(err) => {
                // Malformed remote bytes cost the row, never the doc; the cursor still advances (replaying a poison
                // row forever is the wedge chat2 exists to end).
                tracing::warn!(chat = %self.chat_id, error = %err, "chat2: row import failed; skipping row");
            }
        }
        self.applied(cursor, false);
        RowImportOutcome::Applied
    }
}

impl ChatDocSink for MobileSink {
    fn cursor_is_verified(&self) -> bool {
        self.verified
    }

    // The outbox: the phone's own edits (commands, queue rows) stay on disk until the room acknowledges them, so a
    // send made offline or just before the app is killed still reaches the host.

    fn pending_updates(&self) -> Result<Vec<(String, Vec<u8>)>, String> {
        self.store
            .pending_chat_updates(&self.chat_id)
            .map_err(|e| e.to_string())
    }

    fn persist_update(&self, batch_id: &str, bytes: &[u8]) -> Result<(), String> {
        self.store
            .enqueue_chat_update(&self.chat_id, batch_id, bytes)
            .map_err(|e| e.to_string())
    }

    fn acknowledge_update(&self, batch_id: &str) -> Result<(), String> {
        self.store
            .acknowledge_chat_update(&self.chat_id, batch_id)
            .map_err(|e| e.to_string())
    }

    fn reject_update(&self, batch_id: &str) -> Result<(), String> {
        self.store
            .reject_chat_update(&self.chat_id, batch_id)
            .map_err(|e| e.to_string())
    }

    fn reset_cursor(&self, cursor: u64) {
        if self.cursor.swap(cursor, Ordering::AcqRel) != cursor {
            self.dirty(true);
        }
    }

    fn apply_row(&self, bytes: &[u8], cursor: u64) -> RowImportOutcome {
        self.import(bytes, cursor)
    }

    fn apply_checkpoint(&self, bytes: &[u8], cursor: u64) -> Result<(), String> {
        let status = self
            .doc
            .import_with(bytes, REMOTE_ORIGIN)
            .map_err(|e| format!("checkpoint import: {e}"))?;
        if status.pending.is_some() {
            return Err("checkpoint is missing causal dependencies".into());
        }
        self.applied(cursor, true);
        Ok(())
    }

    fn contains_frontier(&self, frontier: &[u8]) -> bool {
        // No shortcut for an empty or unreadable frontier: a present checkpoint with unreadable provenance is
        // fetched (a full-state merge is always safe; skipping history is not).
        let Ok(vv) = loro::VersionVector::decode(frontier) else {
            return false;
        };
        if vv.is_empty() {
            return false;
        }
        self.doc.oplog_vv().includes_vv(&vv)
    }

    fn advance_cursor(&self, cursor: u64) {
        self.applied(cursor, true);
    }
}

type Emit = Arc<dyn Fn(SessionSnapshot) + Send + Sync>;

pub(crate) struct Session {
    pub chat_id: String,
    doc: Arc<LoroDoc>,
    sink: Arc<MobileSink>,
    edge: Edge,
    emit: Emit,
    client: Mutex<Option<ChatClient>>,
    room_gen: AtomicI64,
    dialing: AtomicBool,
    connected: AtomicBool,
    attached: AtomicBool,
    stopped: AtomicBool,
    project: Arc<Notify>,
    tasks: Mutex<Vec<JoinHandle<()>>>,
    subscription: Mutex<Option<loro::Subscription>>,
    last: Mutex<Option<SessionSnapshot>>,
    /// One local edit at a time, so each batch holds exactly that edit's ops.
    local: Mutex<()>,
}

impl Session {
    /// Hydrate from disk (the last synced snapshot renders at once, even with the host offline). No dial yet.
    pub fn open(chat_id: &str, edge: Edge, store: Arc<DocsStore>, emit: Emit) -> Arc<Self> {
        let doc = Arc::new(LoroDoc::new());
        let mut cursor = 0;
        let verified = store.snapshot_cursor_verified(chat_id).unwrap_or(false);
        if let Ok(Some((bytes, saved_cursor, epoch))) = store.load_snapshot_with_cursor(chat_id) {
            // Only the chat2 lineage is ever imported: an older doc is unrelated history and would duplicate
            // every message.
            if epoch >= CHAT2_DOC_EPOCH && doc.import(&bytes).is_ok() {
                cursor = saved_cursor;
            }
        }
        let save = Arc::new(Notify::new());
        let sink = Arc::new(MobileSink {
            chat_id: chat_id.to_owned(),
            doc: doc.clone(),
            store,
            cursor: AtomicU64::new(cursor),
            verified,
            generation: AtomicU64::new(0),
            saved: AtomicU64::new(0),
            urgent: AtomicBool::new(false),
            save: save.clone(),
            write: Mutex::new(()),
        });
        let session = Arc::new(Self {
            chat_id: chat_id.to_owned(),
            doc,
            sink,
            edge,
            emit,
            client: Mutex::new(None),
            room_gen: AtomicI64::new(1),
            dialing: AtomicBool::new(false),
            connected: AtomicBool::new(false),
            attached: AtomicBool::new(false),
            stopped: AtomicBool::new(false),
            project: Arc::new(Notify::new()),
            tasks: Mutex::new(Vec::new()),
            subscription: Mutex::new(None),
            last: Mutex::new(None),
            local: Mutex::new(()),
        });
        // Every change to the doc, remote or local, re-decodes the transcript.
        let project = session.project.clone();
        let subscription = session
            .doc
            .subscribe_root(Arc::new(move |_| project.notify_one()));
        *lock(&session.subscription) = Some(subscription);
        let mut tasks = lock(&session.tasks);
        tasks.push(tokio::spawn(session.clone().projector()));
        tasks.push(tokio::spawn(Self::saver(session.sink.clone(), save)));
        drop(tasks);
        session.publish();
        session
    }

    pub fn snapshot(&self) -> SessionSnapshot {
        let messages = self
            .doc
            .get_list("messages")
            .get_deep_value()
            .to_json_value();
        let queue = self
            .doc
            .get_movable_list("queue")
            .get_deep_value()
            .to_json_value();
        SessionSnapshot {
            chat_id: self.chat_id.clone(),
            entries: decode::entries(&messages),
            queue: decode::queue(&queue),
            connected: self.connected.load(Ordering::Relaxed),
            retry_at_ms: None,
            waiting_for_migration: self.room_gen.load(Ordering::Relaxed) < 2,
            room_active: self.dialing.load(Ordering::Relaxed),
        }
    }

    fn publish(&self) {
        let snapshot = self.snapshot();
        let mut last = lock(&self.last);
        if last.as_ref() == Some(&snapshot) {
            return;
        }
        *last = Some(snapshot.clone());
        drop(last);
        (self.emit)(snapshot);
    }

    async fn projector(self: Arc<Self>) {
        loop {
            self.project.notified().await;
            let wait = if self.attached.load(Ordering::Relaxed) {
                PROJECT_ATTACHED
            } else {
                PROJECT_DETACHED
            };
            tokio::time::sleep(wait).await;
            let this = self.clone();
            // The decode walks the whole transcript; keep it off the networking workers.
            let _ = tokio::task::spawn_blocking(move || this.publish()).await;
        }
    }

    async fn saver(sink: Arc<MobileSink>, save: Arc<Notify>) {
        loop {
            save.notified().await;
            if !sink.urgent.swap(false, Ordering::AcqRel) {
                tokio::select! {
                    _ = tokio::time::sleep(SAVE_INTERVAL) => {}
                    _ = async {
                        // An urgent write (checkpoint, ack, cursor repair) cuts the interval short.
                        loop {
                            save.notified().await;
                            if sink.urgent.swap(false, Ordering::AcqRel) { break; }
                        }
                    } => {}
                }
            }
            let job = sink.clone();
            let _ = tokio::task::spawn_blocking(move || job.flush()).await;
            if sink.saved.load(Ordering::Acquire) != sink.generation.load(Ordering::Acquire) {
                // A failed write, or a change during export: try again on the next interval.
                save.notify_one();
            }
        }
    }

    /// The registry's room generation for this chat. The phone joins only chat2 (generation 2); a legacy chat waits
    /// for the host to migrate it, and the generation only ever moves up.
    pub fn update_room_gen(self: &Arc<Self>, room_gen: Option<i64>) {
        let room_gen = room_gen.unwrap_or(1);
        let previous = self.room_gen.fetch_max(room_gen, Ordering::AcqRel);
        if previous < 2 && room_gen >= 2 {
            self.project.notify_one();
        }
        self.connect_if_ready();
    }

    fn connect_if_ready(self: &Arc<Self>) {
        if self.stopped.load(Ordering::Relaxed) || self.room_gen.load(Ordering::Relaxed) < 2 {
            return;
        }
        if self.dialing.swap(true, Ordering::AcqRel) {
            return;
        }
        self.project.notify_one();
        let task = tokio::spawn(self.clone().run());
        lock(&self.tasks).push(task);
    }

    async fn run(self: Arc<Self>) {
        let cursor = self.sink.cursor.load(Ordering::Acquire);
        let client = ChatClient::connect_via_transport(
            self.edge.chat_socket(&self.chat_id),
            self.sink.clone(),
            self.edge.checkpoint_fetcher(&self.chat_id),
            &self.edge.device_id,
            cursor,
            self.edge.chat_transport(&self.chat_id),
        )
        .await;
        let client = match client {
            Ok(client) => client,
            Err(err) => {
                tracing::warn!(chat = %self.chat_id, error = %err, "chat2 client did not start");
                self.dialing.store(false, Ordering::Release);
                return;
            }
        };
        let mut events = client.events();
        if self.stopped.load(Ordering::Relaxed) {
            return;
        }
        // The client loaded the outbox when it started; an edit made while it was connecting is journaled but was
        // not in that read. Batch ids dedupe the rest.
        match self.sink.pending_updates() {
            Ok(pending) => {
                for (batch_id, bytes) in pending {
                    client.enqueue_persisted_batch(batch_id, bytes, true);
                }
            }
            Err(error) => tracing::warn!(chat = %self.chat_id, %error, "chat2: outbox read failed"),
        }
        *lock(&self.client) = Some(client);
        loop {
            match events.recv().await {
                Ok(ChatEvent::CaughtUp { .. }) => {
                    self.connected.store(true, Ordering::Relaxed);
                    self.project.notify_one();
                }
                Ok(ChatEvent::Disconnected) => {
                    self.connected.store(false, Ordering::Relaxed);
                    self.project.notify_one();
                }
                Ok(_) | Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {}
                Err(tokio::sync::broadcast::error::RecvError::Closed) => return,
            }
        }
    }

    /// The room has dialed (a room that never dialed is not "degraded").
    pub fn room_active(&self) -> bool {
        self.dialing.load(Ordering::Relaxed)
    }

    pub fn is_connected(&self) -> bool {
        self.connected.load(Ordering::Relaxed)
    }

    /// The screen is showing this chat: decode at frame rate, and dial now.
    pub fn attach(self: &Arc<Self>) {
        self.attached.store(true, Ordering::Relaxed);
        self.connect_if_ready();
        self.project.notify_one();
    }

    pub fn detach(&self) {
        self.attached.store(false, Ordering::Relaxed);
    }

    pub fn is_attached(&self) -> bool {
        self.attached.load(Ordering::Relaxed)
    }

    /// A reply is streaming into this chat: evicting it would drop the live tail.
    pub fn is_streaming(&self) -> bool {
        lock(&self.last).as_ref().is_some_and(|snapshot| {
            snapshot.entries.last().is_some_and(|entry| {
                entry.status == Some(crate::records::MessageStatusRecord::Streaming)
            })
        })
    }

    /// Foreground: probe a joined room, or wake a parked one so it redials on fresh backoff.
    pub fn kick(self: &Arc<Self>) {
        self.connect_if_ready();
        if let Some(client) = lock(&self.client).as_ref() {
            if self.connected.load(Ordering::Relaxed) {
                client.probe();
            } else {
                // Same rule as the registry: wake a parked backoff, never kill a dial in flight.
                harness_sync::wake::notify_online();
            }
        }
    }

    pub fn flush(&self) {
        self.sink.flush();
    }

    /// A local edit (a command or a queue change): committed, written to the outbox before anything is sent, saved
    /// with the snapshot, and pushed now if the room is joined (otherwise when it next joins).
    pub fn write<T>(&self, edit: impl FnOnce(&SessionDoc) -> T) -> T {
        let _local = lock(&self.local);
        let before = self.doc.oplog_vv();
        let doc = SessionDoc::from_doc((*self.doc).clone());
        let out = edit(&doc);
        self.doc.commit();
        if self.doc.oplog_vv() == before {
            return out;
        }
        let bytes = match self.doc.export(loro::ExportMode::updates(&before)) {
            Ok(bytes) => bytes,
            Err(error) => {
                tracing::error!(chat = %self.chat_id, %error, "chat2: local edit export failed");
                return out;
            }
        };
        let batch_id = uuid::Uuid::new_v4().to_string();
        let durable = match self.sink.persist_update(&batch_id, &bytes) {
            Ok(()) => true,
            Err(error) => {
                tracing::error!(chat = %self.chat_id, %error, "chat2: outbox write failed");
                false
            }
        };
        self.sink.dirty(true);
        if let Some(client) = lock(&self.client).as_ref() {
            client.enqueue_persisted_batch(batch_id, bytes, durable);
        }
        out
    }

    /// The id of the transcript's last entry: what a command was based on.
    pub fn last_entry_id(&self) -> Option<String> {
        let messages = self.doc.get_list("messages");
        let last = messages.len().checked_sub(1)?;
        match messages.get(last)? {
            loro::ValueOrContainer::Container(loro::Container::Map(map)) => match map.get("id")? {
                loro::ValueOrContainer::Value(loro::LoroValue::String(id)) => Some(id.to_string()),
                _ => None,
            },
            _ => None,
        }
    }

    /// Edits the room has not acknowledged yet.
    pub fn has_unsent_writes(&self) -> bool {
        self.sink
            .store
            .has_pending_chat_updates(&self.chat_id)
            .unwrap_or(true)
    }

    pub async fn stop(&self) {
        if self.stopped.swap(true, Ordering::AcqRel) {
            return;
        }
        lock(&self.subscription).take();
        for task in lock(&self.tasks).drain(..) {
            task.abort();
        }
        let sink = self.sink.clone();
        let _ = tokio::task::spawn_blocking(move || sink.flush()).await;
        let client = lock(&self.client).take();
        drop(client);
        self.connected.store(false, Ordering::Relaxed);
    }
}
