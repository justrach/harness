//! The workspace registry mirror, the phone's counterpart of the iOS `WorkspaceStore`: the local `RegistryDoc`
//! (authoritative rows plus pending writes), hydrated from disk before the first dial, kept converged by
//! `harness_sync::RegistryClient` over the socket or plain HTTPS, projected for the screens, and written only with the
//! viewer writes in [`crate::writes`].

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::Duration;

use harness_doc::{REGISTRY_DOC_ID, RegistryDoc};
use harness_sync::{DocsStore, RegistryClient, RegistryEvent, RegistryTransport, RegistryTuning};
use tokio::sync::Notify;
use tokio::task::JoinHandle;

use crate::edge::Edge;
use crate::projection;
use crate::records::{ChatRecord, WorkspaceSnapshot};

/// The iOS client beats every 15 s while joined, and once on every join.
const PRESENCE_INTERVAL: Duration = Duration::from_secs(15);
/// `RegistrySaver`'s debounce: a burst of rows costs one write.
const SAVE_DEBOUNCE: Duration = Duration::from_millis(1500);
/// Projection coalescing: a burst of frames re-projects once.
const EMIT_COALESCE: Duration = Duration::from_millis(30);

pub(crate) fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

pub(crate) fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

type Projected = Box<dyn Fn(&WorkspaceSnapshot) + Send + Sync>;

pub(crate) struct Workspace {
    doc: Arc<Mutex<RegistryDoc>>,
    edge: Edge,
    store: Arc<DocsStore>,
    on_projected: Projected,
    client: Mutex<Option<RegistryClient>>,
    transport: Arc<dyn RegistryTransport>,
    connected: AtomicBool,
    emit: Arc<Notify>,
    save: Arc<Notify>,
    stopped: AtomicBool,
    tasks: Mutex<Vec<JoinHandle<()>>>,
    last: Mutex<Option<WorkspaceSnapshot>>,
}

impl Workspace {
    /// Local-first: the on-device copy is loaded before anything dials, so the screens render at once.
    pub fn new(edge: Edge, store: Arc<DocsStore>, on_projected: Projected) -> Arc<Self> {
        let doc = store
            .load_snapshot(REGISTRY_DOC_ID)
            .ok()
            .flatten()
            .and_then(|bytes| RegistryDoc::from_bytes(&bytes, &edge.device_id).ok())
            .unwrap_or_else(|| RegistryDoc::new(edge.device_id.clone()));
        let transport = edge.registry_transport();
        Arc::new(Self {
            doc: Arc::new(Mutex::new(doc)),
            edge,
            store,
            on_projected,
            client: Mutex::new(None),
            transport,
            connected: AtomicBool::new(false),
            emit: Arc::new(Notify::new()),
            save: Arc::new(Notify::new()),
            stopped: AtomicBool::new(false),
            tasks: Mutex::new(Vec::new()),
            last: Mutex::new(None),
        })
    }

    pub fn snapshot(&self) -> WorkspaceSnapshot {
        let doc = lock(&self.doc);
        let client = lock(&self.client);
        WorkspaceSnapshot {
            devices: projection::devices(&doc),
            spaces: projection::spaces(&doc),
            chats: projection::chats(&doc),
            sessions: projection::sessions(&doc),
            pinned_session_ids: projection::pinned_session_ids(&doc),
            pins_initialized: projection::pins_initialized(&doc),
            desktop_appearance: projection::desktop_appearance(&doc),
            presence: client
                .as_ref()
                .map(RegistryClient::presence)
                .unwrap_or_default()
                .into_iter()
                .collect(),
            connected: self.connected.load(Ordering::Relaxed),
            synced: self.synced_with(client.as_ref()),
        }
    }

    fn synced_with(&self, client: Option<&RegistryClient>) -> bool {
        client.is_some_and(|c| c.stats().synced)
    }

    pub fn synced(&self) -> bool {
        self.synced_with(lock(&self.client).as_ref())
    }

    pub fn chats(&self) -> Vec<ChatRecord> {
        projection::chats(&lock(&self.doc))
    }

    /// Hydrate the screens, then join the registry room (with the HTTPS transport alongside, so the first pull lands
    /// in about one round trip and a network that strips socket upgrades still syncs). The tasks hold the store until
    /// `stop` aborts them.
    pub fn start(self: &Arc<Self>) {
        self.publish();
        let mut tasks = lock(&self.tasks);
        tasks.push(tokio::spawn(self.clone().emitter()));
        tasks.push(tokio::spawn(self.clone().saver()));
        tasks.push(tokio::spawn(self.clone().run()));
    }

    async fn run(self: Arc<Self>) {
        let client = match RegistryClient::connect_via_transport(
            self.edge.registry_socket(),
            self.doc.clone(),
            &self.edge.device_id,
            RegistryTuning::default(),
            self.transport.clone(),
        )
        .await
        {
            Ok(client) => client,
            Err(err) => {
                // With a transport the constructor resolves at once, so this is only a shutdown.
                tracing::warn!(error = %err, "registry client did not start");
                return;
            }
        };
        let mut events = client.events();
        if self.stopped.load(Ordering::Relaxed) {
            client.shutdown().await;
            return;
        }
        *lock(&self.client) = Some(client);
        self.emit.notify_one();
        let mut beat = tokio::time::interval(PRESENCE_INTERVAL);
        beat.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            tokio::select! {
                event = events.recv() => match event {
                    Ok(RegistryEvent::Connected) => {
                        self.connected.store(true, Ordering::Relaxed);
                        self.beat();
                        self.after_state();
                    }
                    Ok(RegistryEvent::Disconnected) => {
                        self.connected.store(false, Ordering::Relaxed);
                        self.emit.notify_one();
                    }
                    Ok(RegistryEvent::Applied) => self.after_state(),
                    Ok(RegistryEvent::Presence) => self.emit.notify_one(),
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => self.after_state(),
                    Err(tokio::sync::broadcast::error::RecvError::Closed) => return,
                },
                _ = beat.tick() => {
                    if self.connected.load(Ordering::Relaxed) {
                        self.beat();
                    }
                }
            }
        }
    }

    fn beat(&self) {
        if let Some(client) = lock(&self.client).as_ref() {
            client.set_presence(now_ms());
        }
    }

    /// Rows landed: once the replica has heard the server, drop pins of deleted chats; then republish and persist.
    fn after_state(&self) {
        if self.synced() {
            let wrote = crate::writes::prune_deleted_pins(&mut lock(&self.doc));
            if wrote {
                self.after_local_write();
                return;
            }
        }
        self.emit.notify_one();
        self.save.notify_one();
    }

    /// Re-project, persist, and push. With the socket down the write leaves over HTTPS right away instead of waiting
    /// out the reconnect backoff (`WorkspaceStore.afterLocalWrite`).
    fn after_local_write(&self) {
        self.emit.notify_one();
        self.save.notify_one();
        if let Some(client) = lock(&self.client).as_ref() {
            client.nudge();
        }
        if !self.connected.load(Ordering::Relaxed) {
            let doc = self.doc.clone();
            let transport = self.transport.clone();
            let emit = self.emit.clone();
            let save = self.save.clone();
            tokio::spawn(async move {
                if push_pending_over_http(doc, transport).await {
                    emit.notify_one();
                    save.notify_one();
                }
            });
        }
    }

    /// Apply a viewer write; true when it changed anything.
    pub fn write(&self, apply: impl FnOnce(&mut RegistryDoc, bool) -> bool) -> bool {
        let synced = self.synced();
        let wrote = apply(&mut lock(&self.doc), synced);
        if wrote {
            self.after_local_write();
        }
        wrote
    }

    fn publish(&self) {
        let snapshot = self.snapshot();
        let mut last = lock(&self.last);
        if last.as_ref() == Some(&snapshot) {
            return;
        }
        *last = Some(snapshot.clone());
        drop(last);
        (self.on_projected)(&snapshot);
    }

    async fn emitter(self: Arc<Self>) {
        loop {
            self.emit.notified().await;
            tokio::time::sleep(EMIT_COALESCE).await;
            self.publish();
        }
    }

    async fn saver(self: Arc<Self>) {
        loop {
            self.save.notified().await;
            tokio::time::sleep(SAVE_DEBOUNCE).await;
            self.flush();
        }
    }

    /// Persist now (backgrounding).
    pub fn flush(&self) {
        let bytes = lock(&self.doc).to_bytes();
        match bytes {
            Ok(bytes) => {
                if let Err(err) = self.store.save_snapshot(REGISTRY_DOC_ID, &bytes) {
                    tracing::warn!(error = %err, "registry snapshot not saved");
                }
            }
            Err(err) => tracing::warn!(error = %err, "registry snapshot not encoded"),
        }
    }

    /// Foreground: probe a joined room or redial a dead one now.
    pub fn kick(&self) {
        if let Some(client) = lock(&self.client).as_ref() {
            if self.connected.load(Ordering::Relaxed) {
                client.probe();
            } else {
                client.redial();
            }
        }
    }

    pub async fn stop(&self) {
        self.stopped.store(true, Ordering::Relaxed);
        self.flush();
        for task in lock(&self.tasks).drain(..) {
            task.abort();
        }
        let client = lock(&self.client).take();
        if let Some(client) = client {
            client.shutdown().await;
        }
        self.connected.store(false, Ordering::Relaxed);
    }
}

/// `WorkspaceStore.pushPendingOverHTTP`: flush pending batches over HTTPS while the socket is down. LWW clocks make a
/// replay apply zero ops, and a failure un-marks the batches so the next cycle (HTTPS or socket) retries them.
/// True when an ack retired anything.
async fn push_pending_over_http(
    doc: Arc<Mutex<RegistryDoc>>,
    transport: Arc<dyn RegistryTransport>,
) -> bool {
    let batches = lock(&doc).take_pushable();
    let mut acked = false;
    for batch in batches {
        let body = serde_json::json!({ "batch": batch.batch, "ops": batch.ops }).to_string();
        let ack = match transport.push(body).await {
            Ok(ack) => serde_json::from_str::<serde_json::Value>(&ack)
                .ok()
                .and_then(|v| Some((v["batch"].as_str()?.to_owned(), v["seq"].as_u64()?))),
            Err(err) => {
                tracing::warn!(error = %err, "registry: http push failed; will retry");
                None
            }
        };
        match ack {
            Some((batch, seq)) => {
                lock(&doc).ack_batch(&batch, seq);
                acked = true;
            }
            None => {
                lock(&doc).mark_disconnected();
                break;
            }
        }
    }
    acked
}
