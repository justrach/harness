//! A stand-in desktop host for trying the phone against a dev-mode edge: it publishes a computer, a project and two
//! sessions to the registry, writes a transcript into one session's chat2 room, then streams a reply into it word by
//! word so the phone shows a live session. It also answers the phone's requests over its device room (folders, agents,
//! models, branches, and a pull request for the first session's branch), and beats presence so it reads online.
//!
//! ```sh
//! (cd edge && npm run dev)                                   # AUTH_MODE=dev edge on :27640
//! cargo run -p harness-mobile --example dev_host -- http://127.0.0.1:27640 u1 org1
//! adb shell am start -n harness.codegraff.android/.MainActivity \
//!     --es edge http://10.0.2.2:27640 --es user u1 --es org org1
//! ```

use std::sync::{Arc, Mutex};
use std::time::Duration;

use harness_doc::{
    MessagePart, MessageRole, MessageStatus, OpKind, RegistryDoc, SessionDoc, SessionMessageEntry,
};
use harness_sync::chat_client::{ChatDocSink, CheckpointFetcher, RowImportOutcome};
use harness_sync::{ChatClient, RegistryClient, StaticUrl, SyncError};
use serde_json::json;

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

/// The engine as far as the phone asks it anything.
struct DevEngine;

#[async_trait::async_trait]
impl harness_rpc::RpcService for DevEngine {
    async fn handle(&self, method: &str, params: serde_json::Value) -> Result<harness_rpc::RpcReply, harness_rpc::RpcError> {
        use harness_rpc::RpcReply::{Stream, Value};
        Ok(match method {
            "ListHarnesses" => Value(json!([
                {"id": "graff", "name": "Graff"}, {"id": "claude-code", "name": "Claude Code"}, {"id": "codex", "name": "Codex"}
            ])),
            "ListModels" => Value(json!([
                {"id": "dev-model", "label": "Dev Model", "reasoningLevels": ["low", "medium", "high"]},
                {"id": "dev-model-mini", "label": "Dev Model Mini", "reasoningLevels": []}
            ])),
            "ListFolders" => {
                let path = params.get("path").and_then(|p| p.as_str()).unwrap_or("/Users/dev").to_owned();
                Value(json!({"path": path, "truncated": false, "entries": [
                    {"name": "harness", "isDir": true, "isRepo": true},
                    {"name": "notes", "isDir": true, "isRepo": false}
                ]}))
            }
            "ListRefs" => Value(json!([{"name": "main", "current": true}, {"name": "feature/android"}])),
            "WatchCheckoutChangeRequest" => {
                let cwd = params["cwd"].as_str().unwrap_or_default().to_owned();
                let item = json!({"checkoutId": "", "deviceId": "dev-host", "cwd": cwd, "branch": "main", "updatedAt": "now",
                    "changeRequest": {"provider": "github", "number": 230, "title": "Android: live sync",
                        "url": "https://example.invalid/pull/230", "state": "open", "baseRef": "main", "headRef": "main"}});
                Stream(Box::pin(futures::StreamExt::chain(futures::stream::iter(vec![item]), futures::stream::pending())))
            }
            other => return Err(harness_rpc::RpcError::UnknownMethod(other.into())),
        })
    }
}

struct NoCheckpoint;
impl CheckpointFetcher for NoCheckpoint {
    fn fetch(&self) -> futures::future::BoxFuture<'static, Result<Vec<u8>, SyncError>> {
        Box::pin(async { Err(SyncError::Protocol("no checkpoint".into())) })
    }
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64
}

fn entry(id: &str, role: MessageRole, text: &str, status: MessageStatus) -> SessionMessageEntry {
    SessionMessageEntry {
        id: id.into(),
        role,
        parts: vec![MessagePart::Text {
            id: format!("{id}-t"),
            text: text.into(),
        }],
        created_at: now_ms(),
        device_id: "dev-host".into(),
        status: Some(status),
        continuation_of: None,
        duration_ms: None,
    }
}

#[tokio::main]
async fn main() {
    let mut args = std::env::args().skip(1);
    let edge = args
        .next()
        .unwrap_or_else(|| "http://127.0.0.1:27640".into());
    let user = args.next().unwrap_or_else(|| "u1".into());
    let org = args.next().unwrap_or_else(|| "org1".into());
    let ws = edge.replacen("http", "ws", 1);
    let bearer = format!("{user}@{org}");
    let set = |v: serde_json::Value| serde_json::from_value(v).unwrap();
    let now = now_ms();
    // Each run writes its own messages, so running it again appends a turn rather than repeating ids.
    let run = format!("{now:x}");

    let registry = Arc::new(Mutex::new(RegistryDoc::new("dev-host")));
    {
        let mut doc = registry.lock().unwrap();
        doc.write("devices", "dev-host", OpKind::Upsert, set(json!({
            "id": "dev-host", "name": "Dev Studio", "platform": "macos", "version": "0.2.109", "lastSeenAt": now
        })));
        doc.write("spaces", "dev-space", OpKind::Upsert, set(json!({
            "id": "dev-space", "deviceId": "dev-host", "path": "/Users/dev/harness", "gitDetected": true, "createdAt": now
        })));
        for (id, title, at) in [
            ("dev-chat-1", "Port the sync client", now),
            ("dev-chat-2", "Tidy the README", now - 3_600_000),
        ] {
            doc.write("chats", id, OpKind::Upsert, set(json!({
                "id": id, "deviceId": "dev-host", "spaceId": "dev-space", "title": title, "archived": false,
                "cwd": "/Users/dev/harness", "branch": "main", "createdAt": at, "roomGen": 2,
                "lastMessageAt": at, "lastMessagePreview": "Started from the dev host",
                "config": {"harness": "graff", "model": "dev-model", "modelOptions": {}}
            })));
        }
        doc.write("sessions", "dev-chat-1", OpKind::Upsert, set(json!({
            "chatId": "dev-chat-1", "deviceId": "dev-host", "status": "working", "startedAt": now, "updatedAt": now
        })));
    }
    let client = RegistryClient::connect_via(
        Arc::new(StaticUrl(format!(
            "{ws}/registry/{org}/ws?token={bearer}&device=dev-host"
        ))),
        registry.clone(),
        "dev-host",
    )
    .await
    .expect("registry join");
    client.nudge();
    client.set_presence(now_ms());
    let _relay = harness_rpc::HostRelay::spawn(
        harness_rpc::HostRelayConfig::new(edge.clone(), "dev-host", Arc::new(harness_rpc::StaticToken(bearer.clone()))),
        Arc::new(DevEngine),
        Arc::new(|_| true),
    );
    println!("registry: published a computer, a project and two sessions; relay: serving");

    let session = SessionDoc::init("dev-chat-1").unwrap();
    session
        .push_message(&entry(
            &format!("u-{run}"),
            MessageRole::User,
            "Port the sync client to Android.",
            MessageStatus::Complete,
        ))
        .unwrap();
    session
        .push_message(&entry(
            &format!("a-{run}"),
            MessageRole::Assistant,
            "Reading `apps/ios/Harness/Sync` first.",
            MessageStatus::Complete,
        ))
        .unwrap();
    session.doc().commit();
    let doc = Arc::new(loro::LoroDoc::new());
    doc.import(&session.export_snapshot().unwrap()).unwrap();
    let chat = ChatClient::connect(
        &format!("{ws}/chat2/dev-chat-1/ws?token={bearer}&device=dev-host"),
        Arc::new(HostSink(doc.clone())),
        Arc::new(NoCheckpoint),
        "dev-host",
        0,
    )
    .await
    .expect("chat join");
    chat.enqueue_update(doc.export(loro::ExportMode::all_updates()).unwrap());
    println!("chat2: wrote the transcript; streaming a reply");

    // Stream a reply: one text part grown a word at a time, then settled.
    let live = SessionDoc::from_doc(loro::LoroDoc::new());
    live.doc()
        .import(&doc.export(loro::ExportMode::Snapshot).unwrap())
        .unwrap();
    let words = "The core mirrors the registry and the session doc, and the phone renders them as they stream in."
        .split(' ')
        .collect::<Vec<_>>();
    let mut shown = String::new();
    for (ix, word) in words.iter().enumerate() {
        let before = live.doc().oplog_vv();
        if !shown.is_empty() {
            shown.push(' ');
        }
        shown.push_str(word);
        let status = if ix + 1 == words.len() {
            MessageStatus::Complete
        } else {
            MessageStatus::Streaming
        };
        // Rewriting the entry each tick keeps the example short; the desktop appends to a LoroText instead.
        let messages = live.doc().get_list("messages");
        if ix > 0 {
            messages.delete(messages.len() - 1, 1).unwrap();
        }
        live.push_message(&entry(
            &format!("r-{run}"),
            MessageRole::Assistant,
            &shown,
            status,
        ))
        .unwrap();
        live.doc().commit();
        chat.enqueue_update(
            live.doc()
                .export(loro::ExportMode::updates(&before))
                .unwrap(),
        );
        tokio::time::sleep(Duration::from_millis(250)).await;
        if ix % 20 == 0 {
            client.set_presence(now_ms());
        }
    }
    {
        let mut doc = registry.lock().unwrap();
        doc.write("sessions", "dev-chat-1", OpKind::Upsert, set(json!({
            "chatId": "dev-chat-1", "deviceId": "dev-host", "status": "idle", "updatedAt": now_ms()
        })));
    }
    client.nudge();
    // Keep beating so the phone shows the computer online while you look around.
    println!("done streaming; beating presence until interrupted");
    loop {
        tokio::time::sleep(Duration::from_secs(15)).await;
        client.set_presence(now_ms());
    }
}
