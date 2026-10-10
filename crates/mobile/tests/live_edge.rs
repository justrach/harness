//! End to end against a running edge in dev auth mode (`edge/`: `npm run dev`, or `wrangler dev --var
//! AUTH_MODE:dev`). A simulated desktop host publishes a device, a project, a session and its chat2 transcript with
//! the desktop's own clients (`harness-sync`); the phone's core must mirror them, write back as a viewer, and render
//! the cached copy with the edge gone.
//!
//! ```sh
//! HARNESS_TEST_EDGE=http://127.0.0.1:27640 cargo test -p harness-mobile --test live_edge -- --ignored
//! ```

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use harness_doc::{
    MessagePart, MessageRole, MessageStatus, OpKind, RegistryDoc, SessionDoc, SessionMessageEntry,
};
use harness_mobile::records::{MessagePartRecord, SessionSnapshot, WorkspaceSnapshot};
use harness_mobile::{CoreConfig, CoreListener, MobileCore, TokenSource};
use harness_sync::chat_client::{ChatDocSink, CheckpointFetcher, RowImportOutcome};
use harness_sync::{ChatClient, RegistryClient, StaticUrl, SyncError};
use serde_json::json;

struct Bearer(String);
impl TokenSource for Bearer {
    fn bearer(&self) -> Option<String> {
        Some(self.0.clone())
    }
}

#[derive(Default)]
struct Seen {
    workspace: Mutex<Option<WorkspaceSnapshot>>,
    session: Mutex<Option<SessionSnapshot>>,
    connectivity: Mutex<Option<harness_mobile::ConnectivitySnapshot>>,
}
impl CoreListener for Seen {
    fn workspace_changed(&self, snapshot: WorkspaceSnapshot) {
        *self.workspace.lock().unwrap() = Some(snapshot);
    }
    fn session_changed(&self, snapshot: SessionSnapshot) {
        *self.session.lock().unwrap() = Some(snapshot);
    }
    fn connectivity_changed(&self, snapshot: harness_mobile::ConnectivitySnapshot) {
        *self.connectivity.lock().unwrap() = Some(snapshot);
    }
}

/// The host's engine, as far as the phone asks it anything.
struct FakeHost;

#[async_trait::async_trait]
impl harness_rpc::RpcService for FakeHost {
    async fn handle(
        &self,
        method: &str,
        params: serde_json::Value,
    ) -> Result<harness_rpc::RpcReply, harness_rpc::RpcError> {
        Ok(match method {
            "ListHarnesses" => harness_rpc::RpcReply::Value(json!([
                {"id": "graff", "name": "Graff"},
                {"id": "codex", "name": "Codex", "installed": false},
                {"id": "mock", "name": "Mock", "enabled": true}
            ])),
            "ListFolders" => harness_rpc::RpcReply::Value(json!({
                "path": params.get("path").and_then(|p| p.as_str()).unwrap_or("/Users/me"),
                "entries": [{"name": "harness", "isDir": true, "isRepo": true}],
                "truncated": false
            })),
            "ListRefs" => harness_rpc::RpcReply::Value(
                json!([{"name": "main", "current": true}, {"name": "dev"}]),
            ),
            "WatchCheckoutChangeRequest" => {
                let cwd = params["cwd"].as_str().unwrap_or_default().to_owned();
                let item = json!({
                    "checkoutId": "", "deviceId": "mac-host", "cwd": cwd, "branch": "dev", "updatedAt": "now",
                    "changeRequest": {"provider": "github", "number": 42, "title": "Port the sync client",
                        "url": "https://example.invalid/pull/42", "state": "open", "baseRef": "main", "headRef": "dev"}
                });
                harness_rpc::RpcReply::Stream(Box::pin(futures::StreamExt::chain(
                    futures::stream::iter(vec![item]),
                    futures::stream::pending(),
                )))
            }
            other => return Err(harness_rpc::RpcError::UnknownMethod(other.into())),
        })
    }
}

/// The desktop side of a chat2 room, in memory.
struct HostSink(Arc<loro::LoroDoc>);
impl ChatDocSink for HostSink {
    fn apply_row(&self, bytes: &[u8], _cursor: u64) -> RowImportOutcome {
        let _ = self.0.import(bytes);
        RowImportOutcome::Applied
    }
    fn apply_checkpoint(&self, bytes: &[u8], _cursor: u64) -> Result<(), String> {
        self.0.import(bytes).map(|_| ()).map_err(|e| e.to_string())
    }
    fn contains_frontier(&self, frontier: &[u8]) -> bool {
        loro::VersionVector::decode(frontier)
            .map(|vv| !vv.is_empty() && self.0.oplog_vv().includes_vv(&vv))
            .unwrap_or(false)
    }
    fn advance_cursor(&self, _cursor: u64) {}
}

struct NoCheckpoint;
impl CheckpointFetcher for NoCheckpoint {
    fn fetch(&self) -> futures::future::BoxFuture<'static, Result<Vec<u8>, SyncError>> {
        Box::pin(async { Err(SyncError::Protocol("no checkpoint".into())) })
    }
}

async fn eventually<T>(what: &str, mut check: impl FnMut() -> Option<T>) -> T {
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        if let Some(value) = check() {
            return value;
        }
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

fn text_entry(id: &str, role: MessageRole, text: &str) -> SessionMessageEntry {
    SessionMessageEntry {
        id: id.into(),
        role,
        parts: vec![MessagePart::Text {
            id: format!("{id}-t"),
            text: text.into(),
        }],
        created_at: 1_700_000_000_000,
        device_id: "mac-host".into(),
        status: Some(MessageStatus::Complete),
        continuation_of: None,
        duration_ms: None,
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "needs a dev-mode edge in HARNESS_TEST_EDGE"]
async fn the_phone_mirrors_a_host_and_writes_back_as_a_viewer() {
    let edge = std::env::var("HARNESS_TEST_EDGE").expect("HARNESS_TEST_EDGE");
    let ws = edge.replacen("http", "ws", 1);
    let run = uuid::Uuid::new_v4().simple().to_string();
    let org = format!("org{}", &run[..8]);
    let bearer = format!("u1@{org}");
    let chat_id = format!("chat-{}", &run[..8]);

    // ── the host publishes a device, a project, a working session, and a transcript ─────────────────────────────
    let host_doc = Arc::new(Mutex::new(RegistryDoc::new("mac-host")));
    {
        let mut doc = host_doc.lock().unwrap();
        let set = |v: serde_json::Value| serde_json::from_value(v).unwrap();
        doc.write("devices", "mac-host", OpKind::Upsert, set(json!({
            "id": "mac-host", "name": "Studio", "platform": "macos", "version": "0.2.109", "lastSeenAt": 1
        })));
        doc.write("spaces", "space-1", OpKind::Upsert, set(json!({
            "id": "space-1", "deviceId": "mac-host", "path": "/Users/me/harness", "gitDetected": true, "createdAt": 1
        })));
        doc.write("chats", &chat_id, OpKind::Upsert, set(json!({
            "id": chat_id, "deviceId": "mac-host", "spaceId": "space-1", "title": "Port the sync client",
            "archived": false, "cwd": "/Users/me/harness", "branch": "dev", "createdAt": 2, "roomGen": 2,
            "config": {"harness": "graff", "model": "m1", "modelOptions": {}}
        })));
        doc.write(
            "sessions",
            &chat_id,
            OpKind::Upsert,
            set(json!({
                "chatId": chat_id, "deviceId": "mac-host", "status": "working", "updatedAt": 3
            })),
        );
    }
    let host = RegistryClient::connect_via(
        Arc::new(StaticUrl(format!(
            "{ws}/registry/{org}/ws?token={bearer}&device=mac-host"
        ))),
        host_doc.clone(),
        "mac-host",
    )
    .await
    .expect("host joins the registry");
    host.nudge();
    host.set_presence(1_700_000_000_000);
    let _relay = harness_rpc::HostRelay::spawn(
        harness_rpc::HostRelayConfig::new(
            edge.clone(),
            "mac-host",
            Arc::new(harness_rpc::StaticToken(bearer.clone())),
        ),
        Arc::new(FakeHost),
        Arc::new(|_| true),
    );

    let session = SessionDoc::init(&chat_id).unwrap();
    session
        .push_message(&text_entry("m1", MessageRole::User, "Port it"))
        .unwrap();
    session
        .push_message(&text_entry(
            "m2",
            MessageRole::Assistant,
            "Done: the core mirrors the doc.",
        ))
        .unwrap();
    session.doc().commit();
    let host_chat_doc = Arc::new(loro::LoroDoc::new());
    host_chat_doc
        .import(&session.export_snapshot().unwrap())
        .unwrap();
    let chat_client = ChatClient::connect(
        &format!("{ws}/chat2/{chat_id}/ws?token={bearer}&device=mac-host"),
        Arc::new(HostSink(host_chat_doc.clone())),
        Arc::new(NoCheckpoint),
        "mac-host",
        0,
    )
    .await
    .expect("host joins the chat room");
    chat_client.enqueue_update(
        host_chat_doc
            .export(loro::ExportMode::all_updates())
            .unwrap(),
    );

    // ── the phone mirrors it ────────────────────────────────────────────────────────────────────────────────────
    let data = tempfile::tempdir().unwrap();
    let config = CoreConfig {
        edge_url: edge.clone(),
        org_id: org.clone(),
        user_id: "u1".into(),
        device_id: "android-test".into(),
        data_dir: data.path().to_string_lossy().into_owned(),
    };
    let seen = Arc::new(Seen::default());
    let core = tokio::task::block_in_place(|| {
        MobileCore::new(
            config.clone(),
            Arc::new(Bearer(bearer.clone())),
            seen.clone(),
        )
        .unwrap()
    });
    core.start();
    let workspace = eventually("the workspace", || {
        seen.workspace
            .lock()
            .unwrap()
            .clone()
            .filter(|w| w.chats.iter().any(|c| c.id == chat_id) && w.synced)
    })
    .await;
    assert_eq!(workspace.devices[0].name, "Studio");
    assert_eq!(workspace.spaces[0].path, "/Users/me/harness");
    let chat = workspace.chats.iter().find(|c| c.id == chat_id).unwrap();
    assert_eq!(chat.title.as_deref(), Some("Port the sync client"));
    assert_eq!(chat.config.as_ref().unwrap().model.as_deref(), Some("m1"));
    assert_eq!(workspace.sessions[0].chat_id, chat_id);

    let first = tokio::task::block_in_place(|| core.open_session(chat_id.clone()));
    assert!(!first.waiting_for_migration);
    let transcript = eventually("the transcript", || {
        seen.session
            .lock()
            .unwrap()
            .clone()
            .filter(|s| s.entries.len() == 2)
    })
    .await;
    let MessagePartRecord::Text { text, .. } = &transcript.entries[1].parts[0] else {
        panic!("a text part")
    };
    assert_eq!(text, "Done: the core mirrors the doc.");

    // A reply streams in on the host: the phone sees the new entry.
    {
        let streaming = SessionDoc::from_doc(host_chat_doc.as_ref().clone());
        let before = streaming.doc().oplog_vv();
        streaming
            .push_message(&text_entry("m3", MessageRole::Assistant, "One more thing."))
            .unwrap();
        streaming.doc().commit();
        chat_client.enqueue_update(
            streaming
                .doc()
                .export(loro::ExportMode::updates(&before))
                .unwrap(),
        );
    }
    eventually("the live entry", || {
        seen.session
            .lock()
            .unwrap()
            .clone()
            .filter(|s| s.entries.len() == 3)
    })
    .await;

    // ── the host is online, the relay answers, and the PR badge resolves ───────────────────────────────────────
    eventually("the host to read online", || {
        let w = seen.workspace.lock().unwrap().clone()?;
        (w.host_statuses.get("mac-host") == Some(&harness_mobile::presence::HostStatus::Online))
            .then_some(())
    })
    .await;
    let folders = core
        .list_folders("mac-host".into(), None)
        .await
        .expect("folders over the relay");
    assert_eq!(folders.entries[0].name, "harness");
    let agents = core
        .list_harnesses("mac-host".into())
        .await
        .expect("agents over the relay");
    assert_eq!(
        agents.iter().map(|a| a.id.as_str()).collect::<Vec<_>>(),
        ["graff"]
    );
    let refs = core
        .list_refs("mac-host".into(), "/Users/me/harness".into())
        .await
        .unwrap();
    assert!(refs[0].current);
    let unknown = core
        .switch_ref("mac-host".into(), "/x".into(), "dev".into())
        .await
        .unwrap_err();
    assert!(
        unknown.to_string().starts_with("unknown method"),
        "{unknown}"
    );
    eventually("the PR badge", || {
        let w = seen.workspace.lock().unwrap().clone()?;
        (w.change_requests.get(&chat_id)?.number == 42).then_some(())
    })
    .await;
    let connectivity = seen
        .connectivity
        .lock()
        .unwrap()
        .clone()
        .expect("a connectivity snapshot");
    assert_eq!(
        connectivity.state,
        harness_mobile::ConnectivityState::Connected
    );

    // ── the phone writes back as a viewer; the host's replica converges ─────────────────────────────────────────
    assert!(core.rename(chat_id.clone(), "Renamed on the phone".into()));
    assert!(core.set_pinned(chat_id.clone(), true));
    eventually("the host to see the rename", || {
        let doc = host_doc.lock().unwrap();
        let row = doc.overlay_row("chats", &chat_id)?;
        (row.fields.get("title")? == "Renamed on the phone").then_some(())
    })
    .await;
    eventually("the pin to round-trip", || {
        seen.workspace
            .lock()
            .unwrap()
            .clone()
            .filter(|w| w.pinned_session_ids == vec![chat_id.clone()])
    })
    .await;

    // ── the phone sends: the command and the queue row reach the host's copy, and the outbox empties ────────────
    let message_id = core.send_run(chat_id.clone(), "Next step".into(), vec![]);
    let row_id = core
        .enqueue_message(chat_id.clone(), "After that".into(), vec![], true)
        .unwrap();
    eventually("the host to receive the run and the queued row", || {
        let host = SessionDoc::from_doc(host_chat_doc.as_ref().clone());
        let run = host.read_commands().ok()?.into_iter().any(|c| {
            matches!(&c.payload, harness_doc::SessionCommandPayload::Run { message_id: id, request }
                if id == &message_id && request.prompt == "Next step" && request.model.as_deref() == Some("m1"))
        });
        let queued = host.read_queue().ok()?.iter().any(|row| row.id == row_id);
        (run && queued).then_some(())
    })
    .await;
    let store = harness_sync::DocsStore::open(data.path()).unwrap();
    eventually("the room to acknowledge the phone's edits", || {
        (!store.has_pending_chat_updates(&chat_id).unwrap()).then_some(())
    })
    .await;
    drop(store);

    // ── local-first: with the edge unreachable, the cached copy renders at once ─────────────────────────────────
    tokio::task::block_in_place(|| core.stop());
    tokio::task::block_in_place(|| drop(core));
    let offline = CoreConfig {
        edge_url: "http://127.0.0.1:9".into(),
        ..config
    };
    let seen_offline = Arc::new(Seen::default());
    let cached = tokio::task::block_in_place(|| {
        MobileCore::new(
            offline,
            Arc::new(Bearer(bearer.clone())),
            seen_offline.clone(),
        )
        .unwrap()
    });
    let snapshot = cached.workspace();
    let chat = snapshot
        .chats
        .iter()
        .find(|c| c.id == chat_id)
        .expect("cached chat");
    assert_eq!(chat.title.as_deref(), Some("Renamed on the phone"));
    assert!(!snapshot.connected);
    let session = tokio::task::block_in_place(|| cached.open_session(chat_id.clone()));
    assert_eq!(
        session.entries.len(),
        3,
        "the transcript renders from disk with the edge gone"
    );
    tokio::task::block_in_place(|| {
        cached.stop();
        drop(cached);
    });
    host.shutdown().await;
}
