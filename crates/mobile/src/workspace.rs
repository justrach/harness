//! The workspace registry mirror, the phone's counterpart of the iOS `WorkspaceStore`: the local `RegistryDoc`
//! (authoritative rows plus pending writes), hydrated from disk before the first dial, kept converged by
//! `harness_sync::RegistryClient` over the socket or plain HTTPS, projected for the screens, and written only with the
//! viewer writes in [`crate::writes`].

use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::Duration;

use harness_doc::{REGISTRY_DOC_ID, RegistryDoc};
use harness_sync::{DocsStore, RegistryClient, RegistryEvent, RegistryTransport, RegistryTuning};
use tokio::sync::Notify;
use tokio::task::JoinHandle;

use crate::change_requests::{self, CheckoutStatus, WatchKey};
use crate::edge::Edge;
use crate::presence::{
    PeerLivenessRecord, PresenceInput, presence_liveness, presence_next_change, presence_status,
};
use crate::projection;
use crate::records::{ChatRecord, WorkspaceSnapshot};
use crate::relay::Relay;

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
    /// Device id to (the beat's own stamp, when this session received it). Freshness is timed from receipt.
    beats: Mutex<HashMap<String, (i64, i64)>>,
    /// When the registry room (re)joined: the dial gate's warm-up clock restarts on every rejoin.
    joined_at: Mutex<Option<i64>>,
    /// The next instant a device's status can change by the clock alone (one wake-up, never a ticking timer).
    status_wake: Mutex<Option<i64>>,
    /// False while the app is in the background: no status wake-ups are scheduled.
    active: AtomicBool,
    /// Requests to other devices; set once the core has built it (it needs this store's dial gate).
    relay: std::sync::OnceLock<Arc<Relay>>,
    me: std::sync::OnceLock<std::sync::Weak<Workspace>>,
    /// Pull-request watches: the latest resolution per checkout, the running watches, and devices too old for them.
    change_requests: Mutex<HashMap<WatchKey, CheckoutStatus>>,
    watches: Mutex<HashMap<WatchKey, JoinHandle<()>>>,
    unsupported: Mutex<HashSet<String>>,
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
            beats: Mutex::new(HashMap::new()),
            joined_at: Mutex::new(None),
            status_wake: Mutex::new(None),
            active: AtomicBool::new(true),
            relay: std::sync::OnceLock::new(),
            me: std::sync::OnceLock::new(),
            change_requests: Mutex::new(HashMap::new()),
            watches: Mutex::new(HashMap::new()),
            unsupported: Mutex::new(HashSet::new()),
        })
    }

    fn presence_input(
        &self,
        device_id: &str,
        now: i64,
        row_last_seen: Option<i64>,
    ) -> PresenceInput {
        PresenceInput {
            now,
            received: lock(&self.beats)
                .get(device_id)
                .map(|(_, received)| *received),
            connected: self.connected.load(Ordering::Relaxed),
            joined_at: *lock(&self.joined_at),
            row_last_seen,
        }
    }

    /// The dial gate for the device relay (`WorkspaceStore.peerLiveness`).
    pub fn liveness(&self, device_id: &str) -> PeerLivenessRecord {
        let row = projection::devices(&lock(&self.doc))
            .into_iter()
            .find(|d| d.id == device_id)
            .and_then(|d| d.last_seen_at);
        presence_liveness(self.presence_input(device_id, now_ms(), row))
    }

    /// Record beats the client has heard: a beat whose stamp changed was received now.
    fn note_beats(&self) {
        let heard = lock(&self.client)
            .as_ref()
            .map(RegistryClient::presence)
            .unwrap_or_default();
        let now = now_ms();
        let mut fresh = Vec::new();
        {
            let mut beats = lock(&self.beats);
            for (device, at) in heard {
                if beats.get(&device).is_none_or(|(seen, _)| *seen != at) {
                    beats.insert(device.clone(), (at, now));
                    fresh.push(device);
                }
            }
        }
        // A beat is the evidence a device is back: a relay dial it was cooling down from may go now.
        if let Some(relay) = self.relay.get() {
            for device in fresh {
                relay.peer_alive(&device);
            }
        }
    }

    pub fn set_relay(&self, relay: Arc<Relay>) {
        let _ = self.relay.set(relay);
    }

    // ── pull-request badges ─────────────────────────────────────────────────────────────────────────────────────

    fn reconcile_watches(&self, chats: &[ChatRecord], spaces: &[crate::records::SpaceRecord]) {
        let (Some(relay), Some(me)) = (self.relay.get(), self.me.get()) else {
            return;
        };
        let targets = change_requests::desired_targets(chats, spaces, &lock(&self.unsupported));
        let mut watches = lock(&self.watches);
        watches.retain(|key, task| {
            let keep = targets.contains(key);
            if !keep {
                task.abort();
            }
            keep
        });
        lock(&self.change_requests).retain(|key, _| targets.contains(key));
        for key in targets {
            if watches.contains_key(&key) {
                continue;
            }
            let task = tokio::spawn(Self::watch(me.clone(), relay.clone(), key.clone()));
            watches.insert(key, task);
        }
    }

    /// One checkout's watch: snapshots while the stream lives, retried with backoff (the last snapshot stands
    /// through transport gaps). A host that does not know the method is too old for badges: stop asking it.
    async fn watch(me: std::sync::Weak<Self>, relay: Arc<Relay>, key: WatchKey) {
        let mut retry = Duration::from_millis(500);
        loop {
            match relay
                .stream(
                    &key.device_id,
                    "WatchCheckoutChangeRequest",
                    serde_json::json!({ "cwd": key.cwd }),
                )
                .await
            {
                Ok(mut subscription) => {
                    while let Some(item) = subscription.recv().await {
                        let Ok(status) = serde_json::from_value::<CheckoutStatus>(item) else {
                            continue;
                        };
                        // Never show a misrouted frame under another host or path.
                        if status.device_id != key.device_id || status.cwd != key.cwd {
                            continue;
                        }
                        let Some(this) = me.upgrade() else { return };
                        lock(&this.change_requests).insert(key.clone(), status);
                        this.emit.notify_one();
                        retry = Duration::from_millis(500);
                    }
                }
                Err(err) if err.is_unknown_method() => {
                    let Some(this) = me.upgrade() else { return };
                    lock(&this.unsupported).insert(key.device_id.clone());
                    lock(&this.change_requests).retain(|k, _| k.device_id != key.device_id);
                    this.emit.notify_one();
                    return;
                }
                Err(_) => {}
            }
            tokio::time::sleep(retry).await;
            retry = (retry * 2).min(Duration::from_secs(5));
        }
    }

    /// Reconnect or foreground: every watch starts over, and devices marked too old are asked again.
    fn restart_watches(&self) {
        for (_, task) in lock(&self.watches).drain() {
            task.abort();
        }
        lock(&self.unsupported).clear();
        self.emit.notify_one();
    }

    pub fn snapshot(&self) -> WorkspaceSnapshot {
        let doc = lock(&self.doc);
        let client = lock(&self.client);
        let devices = projection::devices(&doc);
        let now = now_ms();
        let mut ids: Vec<String> = devices.iter().map(|d| d.id.clone()).collect();
        ids.extend(lock(&self.beats).keys().cloned());
        ids.sort();
        ids.dedup();
        let mut host_statuses = HashMap::new();
        let mut wake: Option<i64> = None;
        for id in ids {
            let row = devices
                .iter()
                .find(|d| d.id == id)
                .and_then(|d| d.last_seen_at);
            let input = self.presence_input(&id, now, row);
            host_statuses.insert(id, presence_status(input));
            if let Some(at) = presence_next_change(input) {
                wake = Some(wake.map_or(at, |w| w.min(at)));
            }
        }
        *lock(&self.status_wake) = wake;
        let chats = projection::chats(&doc);
        let spaces = projection::spaces(&doc);
        let badges = lock(&self.change_requests);
        let change_requests = chats
            .iter()
            .filter_map(|chat| {
                Some((
                    chat.id.clone(),
                    change_requests::resolve(chat, &spaces, &badges)?,
                ))
            })
            .collect();
        drop(badges);
        WorkspaceSnapshot {
            change_requests,
            host_statuses,
            retry_at_ms: client
                .as_ref()
                .map(|c| c.reconnect_state().retry_at_ms)
                .filter(|&at| at > 0 && !self.connected.load(Ordering::Relaxed)),
            devices,
            spaces,
            chats,
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

    pub fn is_connected(&self) -> bool {
        self.connected.load(Ordering::Relaxed)
    }

    /// The registry's next redial while it is down.
    pub fn retry_at(&self) -> Option<i64> {
        if self.is_connected() {
            return None;
        }
        lock(&self.client)
            .as_ref()
            .map(|c| c.reconnect_state().retry_at_ms)
            .filter(|&at| at > 0)
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
        let _ = self.me.set(Arc::downgrade(self));
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
                        let reconnected = !self.connected.swap(true, Ordering::Relaxed);
                        if reconnected {
                            self.restart_watches();
                        }
                        *lock(&self.joined_at) = Some(now_ms());
                        self.note_beats();
                        self.beat();
                        self.after_state();
                    }
                    Ok(RegistryEvent::Disconnected) => {
                        self.connected.store(false, Ordering::Relaxed);
                        *lock(&self.joined_at) = None;
                        self.emit.notify_one();
                    }
                    Ok(RegistryEvent::Applied) => {
                        self.note_beats();
                        self.after_state();
                    }
                    Ok(RegistryEvent::Presence) => {
                        self.note_beats();
                        self.emit.notify_one();
                    }
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
        self.reconcile_watches(&snapshot.chats, &snapshot.spaces);
        let mut last = lock(&self.last);
        if last.as_ref() == Some(&snapshot) {
            return;
        }
        *last = Some(snapshot.clone());
        drop(last);
        (self.on_projected)(&snapshot);
    }

    /// Publishes on demand, and once more at the next instant a device's status can change by the clock alone (a
    /// beat aging out), while the app is in front.
    async fn emitter(self: Arc<Self>) {
        loop {
            let wake = (*lock(&self.status_wake)).filter(|_| self.active.load(Ordering::Relaxed));
            match wake {
                Some(at) => {
                    let delay = Duration::from_millis((at - now_ms() + 250).max(500) as u64);
                    tokio::select! {
                        _ = self.emit.notified() => tokio::time::sleep(EMIT_COALESCE).await,
                        _ = tokio::time::sleep(delay) => {}
                    }
                }
                None => {
                    self.emit.notified().await;
                    tokio::time::sleep(EMIT_COALESCE).await;
                }
            }
            self.publish();
        }
    }

    /// Foreground and background: no status wake-ups in the background; on return, catch up on what aged out.
    pub fn set_active(&self, active: bool) {
        self.active.store(active, Ordering::Relaxed);
        self.emit.notify_one();
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

    /// Foreground: probe a joined room, or wake a parked one so it redials on fresh backoff, and start the badge
    /// watches over.
    pub fn kick(&self) {
        self.restart_watches();
        if let Some(client) = lock(&self.client).as_ref() {
            if self.connected.load(Ordering::Relaxed) {
                // Post-suspend sockets are half-open more often than not: a deadline-checked probe finds out.
                client.probe();
            } else {
                // A dial may be mid-handshake (the launch dial, on the busiest link): never kill it. A client parked
                // in its backoff wakes on the online event and redials on fresh backoff.
                harness_sync::wake::notify_online();
            }
        }
    }

    pub async fn stop(&self) {
        self.stopped.store(true, Ordering::Relaxed);
        self.flush();
        for task in lock(&self.tasks).drain(..) {
            task.abort();
        }
        for (_, task) in lock(&self.watches).drain() {
            task.abort();
        }
        if let Some(relay) = self.relay.get() {
            relay.disconnect_all();
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
