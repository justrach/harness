//! M4b integration: `targetDeviceId` routing — engine A forwards device-addressed RPCs
//! to engine B through B's device-room relay (host relay on B, link cache on A), with a
//! minimal in-memory device-room standing in for the edge DO (route client→host with
//! `from` stamped, host→client by `to`).

// tungstenite's `accept_hdr_async` callback signature fixes the Err type as a full
// `Response` — its size is not ours to shrink.
#![allow(clippy::result_large_err)]

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use futures::stream::BoxStream;
use futures::{SinkExt, StreamExt};
use tokio::net::TcpListener;
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::Message as WsMessage;
use tokio_tungstenite::tungstenite::handshake::server::{
    Request as WsRequest, Response as WsResponse,
};

use zeron_doc::SessionCommandPayload;
use zeron_engine::{EngineCore, HarnessRegistry};
use zeron_harness::{Harness, HarnessError, RunControls};
use zeron_proto::{
    AgentEvent, DoneStatus, HarnessId, Model, ReasoningLevel, RunRequest, SandboxLevel,
    SteeringMode,
};
use zeron_rpc::{
    DeviceFrameHeader, LinkCache, LinkCacheConfig, StaticToken, decode_device_frame,
    encode_device_frame, methods,
};

// ---------------------------------------------------------------------------
// Minimal in-memory device room (route-only subset of the DO semantics)
// ---------------------------------------------------------------------------

#[derive(Default)]
struct RelayState {
    host: Option<mpsc::UnboundedSender<Vec<u8>>>,
    clients: HashMap<String, mpsc::UnboundedSender<Vec<u8>>>,
}

async fn fake_device_room() -> (String, tokio::task::JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind relay");
    let url = format!(
        "http://127.0.0.1:{}",
        listener.local_addr().expect("addr").port()
    );
    let state = Arc::new(Mutex::new(RelayState::default()));
    let task = tokio::spawn(async move {
        loop {
            let Ok((stream, _)) = listener.accept().await else {
                break;
            };
            let state = state.clone();
            tokio::spawn(async move {
                let mut uri = String::new();
                let Ok(ws) = tokio_tungstenite::accept_hdr_async(
                    stream,
                    |req: &WsRequest, res: WsResponse| {
                        uri = req.uri().to_string();
                        Ok(res)
                    },
                )
                .await
                else {
                    return;
                };
                let query = uri.split_once('?').map(|(_, q)| q).unwrap_or("");
                let is_host = query.contains("role=host");
                let conn_id = query
                    .split('&')
                    .find_map(|kv| kv.strip_prefix("connId="))
                    .unwrap_or("anon")
                    .to_string();
                let (mut sink, mut ws_stream) = ws.split();
                let (tx, mut rx) = mpsc::unbounded_channel::<Vec<u8>>();
                {
                    let mut st = state.lock().expect("lock");
                    if is_host {
                        st.host = Some(tx);
                    } else {
                        st.clients.insert(conn_id.clone(), tx);
                    }
                }
                let writer = tokio::spawn(async move {
                    while let Some(bytes) = rx.recv().await {
                        if sink.send(WsMessage::Binary(bytes)).await.is_err() {
                            break;
                        }
                    }
                });
                while let Some(Ok(message)) = ws_stream.next().await {
                    let WsMessage::Binary(bytes) = message else {
                        continue;
                    };
                    let Ok((header, payload)) = decode_device_frame(&bytes) else {
                        break;
                    };
                    let st = state.lock().expect("lock");
                    if is_host {
                        let Some(to) = header.to else { continue };
                        if let Some(client) = st.clients.get(&to) {
                            let stripped = DeviceFrameHeader::new(header.s, header.k);
                            let _ = client
                                .send(encode_device_frame(&stripped, &payload).expect("encode"));
                        }
                    } else if let Some(host) = &st.host {
                        let mut routed = DeviceFrameHeader::new(header.s, header.k);
                        routed.from = Some(conn_id.clone());
                        let _ = host.send(encode_device_frame(&routed, &payload).expect("encode"));
                    }
                }
                writer.abort();
            });
        }
    });
    (url, task)
}

// ---------------------------------------------------------------------------
// Engine fixtures
// ---------------------------------------------------------------------------

/// Instant mock harness so a forwarded QueueCommand fully executes on the target.
struct InstantHarness;

#[async_trait]
impl Harness for InstantHarness {
    fn id(&self) -> HarnessId {
        HarnessId::Mock
    }
    fn display_name(&self) -> &str {
        "Instant"
    }
    fn supports_steering(&self) -> bool {
        false
    }
    fn steering_mode(&self) -> SteeringMode {
        SteeringMode::TurnBoundary
    }
    fn reasoning_levels(&self) -> &[ReasoningLevel] {
        &[]
    }
    async fn models(&self) -> Result<Vec<Model>, HarnessError> {
        Ok(vec![])
    }
    async fn run(
        &self,
        _request: RunRequest,
        _controls: RunControls,
    ) -> Result<BoxStream<'static, Result<AgentEvent, HarnessError>>, HarnessError> {
        Ok(futures::stream::iter([
            Ok(AgentEvent::SessionStarted {
                harness: HarnessId::Mock,
                model: "instant-1".into(),
                tools: vec![],
                cwd: "/tmp".into(),
                session_id: "hs-1".into(),
                assistant_message_id: "a-1".into(),
            }),
            Ok(AgentEvent::TextDelta {
                text: "remote reply".into(),
            }),
            Ok(AgentEvent::Done {
                status: DoneStatus::Completed,
                result: None,
                error: None,
                session_id: Some("hs-1".into()),
            }),
        ])
        .boxed())
    }
}

fn registry() -> Arc<HarnessRegistry> {
    let registry = HarnessRegistry::new();
    registry.register(Arc::new(InstantHarness));
    Arc::new(registry)
}

fn assemble(dir: &std::path::Path, device_id: &str) -> EngineCore {
    std::fs::create_dir_all(dir).expect("create data dir");
    std::fs::write(dir.join("device-id"), device_id).expect("write device id");
    EngineCore::assemble(dir, registry(), HarnessId::Mock, None).expect("engine assembles")
}

async fn git(cwd: &std::path::Path, args: &[&str]) {
    let output = tokio::process::Command::new("git")
        .args(args)
        .current_dir(cwd)
        .env("GIT_AUTHOR_NAME", "test")
        .env("GIT_AUTHOR_EMAIL", "test@test")
        .env("GIT_COMMITTER_NAME", "test")
        .env("GIT_COMMITTER_EMAIL", "test@test")
        .output()
        .await
        .expect("git spawns");
    assert!(
        output.status.success(),
        "git {args:?} failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn target_device_id_routes_over_the_relay() {
    let (relay_url, _relay) = fake_device_room().await;
    let dirs = tempfile::tempdir().expect("tempdir");

    // Engine B hosts its device room on the fake relay.
    let core_b = assemble(&dirs.path().join("b"), "device-b");
    let _host = core_b.start_host_relay(&relay_url);

    // Engine A dials peers through the same relay.
    let core_a = assemble(&dirs.path().join("a"), "device-a");
    let mut link_config =
        LinkCacheConfig::new(relay_url.clone(), Arc::new(StaticToken("test-user".into())));
    link_config.probe_timeout = Duration::from_secs(5);
    core_a.set_links(LinkCache::new(link_config));

    // Seed a transcript on B only — proves reads come from B, not A's (empty) doc.
    let handle_b = core_b.doc_host.open("chat-remote").expect("open chat on B");
    handle_b
        .write_user_message("m-b-1", "hello from B", 1_000)
        .expect("write user message");

    let client = zeron_rpc::memory_client(core_a.rpc_service());

    // Our own id in targetDeviceId: handled locally, no forward.
    let local = client
        .call(
            methods::LIST_HARNESSES,
            serde_json::json!({ "targetDeviceId": "device-a" }),
        )
        .await
        .expect("local list");
    assert!(local.is_array());

    // Unary forward: ListHarnesses answered by B through the relay. (The host relay
    // dials with backoff; retry until its session is up.)
    let deadline = tokio::time::Instant::now() + Duration::from_secs(15);
    let remote = loop {
        match client
            .call(
                methods::LIST_HARNESSES,
                serde_json::json!({ "targetDeviceId": "device-b" }),
            )
            .await
        {
            Ok(value) => break value,
            Err(err) => {
                assert!(
                    tokio::time::Instant::now() < deadline,
                    "relay never came up: {err}"
                );
                tokio::time::sleep(Duration::from_millis(200)).await;
            }
        }
    };
    assert!(remote.is_array());

    // The add-space picker's exact call: browse a folder ON B from A's IPC
    // surface (ListFolders + targetDeviceId, relay-forwarded).
    let browse_dir = dirs.path().join("b-folders");
    std::fs::create_dir_all(browse_dir.join("project-x")).expect("browse fixture");
    let listing = client
        .call(
            methods::LIST_FOLDERS,
            serde_json::json!({
                "path": browse_dir.to_string_lossy(),
                "targetDeviceId": "device-b",
            }),
        )
        .await
        .expect("remote ListFolders");
    let names: Vec<&str> = listing["entries"]
        .as_array()
        .expect("entries array")
        .iter()
        .filter_map(|e| e["name"].as_str())
        .collect();
    assert!(
        names.contains(&"project-x"),
        "remote folder listing must come from B's filesystem: {names:?}"
    );

    // Streaming proxy: WatchDocMessages against B's doc from A's IPC surface.
    let mut stream = client
        .subscribe(
            methods::WATCH_DOC_MESSAGES,
            serde_json::json!({ "chatId": "chat-remote", "targetDeviceId": "device-b" }),
        )
        .await
        .expect("remote subscribe");
    // The watch emits its current value first ([] if B's publish pass hasn't run yet),
    // then re-emits on every doc change — read until B's entry arrives.
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    loop {
        let item = tokio::time::timeout_at(deadline, stream.recv())
            .await
            .expect("remote transcript before timeout")
            .expect("stream alive");
        if item.to_string().contains("hello from B") {
            break;
        }
    }

    // Unary forward with side effects: QueueCommand lands (and executes) on B.
    let command = serde_json::to_value(SessionCommandPayload::Run {
        request: RunRequest {
            prompt: "run remotely".into(),
            harness: None,
            model: None,
            reasoning: None,
            model_options: serde_json::Map::new(),
            cwd: "/tmp".into(),
            sandbox: SandboxLevel::WorkspaceWrite,
            auto_approve: true,
            attachments: Vec::new(),
            worktree: None,
            resume: None,
        },
        message_id: "m-a-1".into(),
    })
    .expect("serialize command");
    let queued = client
        .call(
            methods::QUEUE_COMMAND,
            serde_json::json!({
                "chatId": "chat-remote",
                "targetDeviceId": "device-b",
                "command": command,
            }),
        )
        .await
        .expect("queue on B");
    let command_id = queued["commandId"]
        .as_str()
        .expect("command id")
        .to_string();
    let commands = handle_b.doc().read_commands().expect("read B commands");
    assert!(
        commands.iter().any(|c| c.id == command_id),
        "command must live in B's doc"
    );

    // Project Actions are also device-routed and persist only in B's private
    // profile store. A versioned project file only contributes import offers.
    let project_root = dirs.path().join("project-on-b");
    std::fs::create_dir_all(&project_root).expect("project root on B");
    git(&project_root, &["init", "-b", "main"]).await;
    std::fs::write(project_root.join("README.md"), "host B\n").expect("seed repo on B");
    std::fs::write(
        project_root.join("zeron.json"),
        r#"{"actions":[{"name":"Lint","command":"pnpm lint","icon":"lint"}]}"#,
    )
    .expect("project file");
    git(&project_root, &["add", "."]).await;
    git(&project_root, &["commit", "-m", "seed"]).await;
    core_b
        .workspace
        .create_space(
            "space-actions",
            "device-b",
            &project_root.to_string_lossy(),
            None,
            true,
        )
        .expect("space row on B");
    let listed = client
        .call(
            methods::LIST_PROJECT_ACTIONS,
            serde_json::json!({
                "spaceId": "space-actions",
                "targetDeviceId": "device-b",
            }),
        )
        .await
        .expect("list remote Actions");
    assert_eq!(listed["actions"].as_array().unwrap().len(), 0);
    assert_eq!(listed["importableActions"].as_array().unwrap().len(), 1);

    let saved = client
        .call(
            methods::UPSERT_PROJECT_ACTION,
            serde_json::json!({
                "spaceId": "space-actions",
                "targetDeviceId": "device-b",
                "action": {
                    "name": "Lint",
                    "command": "printf 'remote-action\\n' > action-marker; if [ -n \"$ZERON_WORKTREE_PATH\" ]; then printf 'ROOT=%s\\nWT=%s\\nCWD=%s\\n' \"$ZERON_PROJECT_ROOT\" \"$ZERON_WORKTREE_PATH\" \"$PWD\" > setup-marker; fi; printf 'remote-action\\n'",
                    "icon": "lint",
                    "runOnWorktreeCreate": true,
                },
            }),
        )
        .await
        .expect("save remote Action");
    let action_id = saved["actions"][0]["id"]
        .as_str()
        .expect("normalized action id")
        .to_string();
    assert!(saved["importableActions"].as_array().unwrap().is_empty());
    assert_eq!(
        core_b
            .project_actions
            .actions("space-actions", &project_root)
            .expect("B store")
            .len(),
        1
    );
    assert!(
        core_a
            .project_actions
            .actions("space-actions", &project_root)
            .expect("A store")
            .is_empty(),
        "the forwarding engine must not persist the command"
    );

    core_b
        .workspace
        .create_chat("chat-actions", Some("space-actions"), None, None, None)
        .expect("Action chat on B");
    let run = client
        .call(
            methods::RUN_PROJECT_ACTION,
            serde_json::json!({
                "spaceId": "space-actions",
                "chatId": "chat-actions",
                "actionId": action_id,
                "cols": 80,
                "rows": 24,
                "targetDeviceId": "device-b",
            }),
        )
        .await
        .expect("run remote Action");
    let action_terminal = run["terminal"]["id"]
        .as_str()
        .expect("Action terminal id")
        .to_string();
    let mut action_stream = client
        .subscribe(
            methods::SUBSCRIBE_TERMINAL,
            serde_json::json!({
                "terminalId": action_terminal,
                "targetDeviceId": "device-b",
            }),
        )
        .await
        .expect("subscribe remote Action");
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    loop {
        let item = tokio::time::timeout_at(deadline, action_stream.recv())
            .await
            .expect("remote Action output before timeout")
            .expect("Action stream alive");
        if item["type"] == "data" {
            let output = BASE64
                .decode(item["data"].as_str().expect("Action data"))
                .expect("Action base64");
            if String::from_utf8_lossy(&output).contains("remote-action")
                && project_root.join("action-marker").exists()
            {
                break;
            }
        }
    }
    assert_eq!(
        std::fs::read_to_string(project_root.join("action-marker")).expect("marker on B"),
        "remote-action\n"
    );
    assert!(
        !dirs.path().join("a").join("action-marker").exists(),
        "remote execution must not fall back to A's filesystem"
    );
    client
        .call(
            methods::CLOSE_TERMINAL,
            serde_json::json!({
                "terminalId": action_terminal,
                "targetDeviceId": "device-b",
            }),
        )
        .await
        .expect("close remote Action terminal");

    // New worktree setup runs entirely on B and returns an already-open PTY.
    // Subscribe after a delay to prove the early output is recovered by replay.
    let setup_outcome = client
        .call(
            methods::CREATE_WORKTREE,
            serde_json::json!({
                "repoPath": project_root,
                "branch": "main",
                "spaceId": "space-actions",
                "targetDeviceId": "device-b",
            }),
        )
        .await
        .expect("create remote worktree with setup");
    assert!(setup_outcome.get("setupError").is_none());
    let setup_terminal = setup_outcome["setupAction"]["terminal"]["id"]
        .as_str()
        .expect("remote setup terminal")
        .to_string();
    let setup_worktree = std::path::PathBuf::from(
        setup_outcome["path"]
            .as_str()
            .expect("remote setup worktree"),
    );
    tokio::time::sleep(Duration::from_millis(250)).await;
    let mut setup_stream = client
        .subscribe(
            methods::SUBSCRIBE_TERMINAL,
            serde_json::json!({
                "terminalId": setup_terminal,
                "targetDeviceId": "device-b",
            }),
        )
        .await
        .expect("subscribe remote setup replay");
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    loop {
        let item = tokio::time::timeout_at(deadline, setup_stream.recv())
            .await
            .expect("remote setup replay before timeout")
            .expect("setup stream alive");
        if item["type"] == "data" {
            let output = BASE64
                .decode(item["data"].as_str().expect("setup data"))
                .expect("setup base64");
            if String::from_utf8_lossy(&output).contains("remote-action")
                && setup_worktree.join("setup-marker").exists()
            {
                break;
            }
        }
    }
    let canonical_project = std::fs::canonicalize(&project_root).expect("canonical B project");
    let canonical_worktree = std::fs::canonicalize(&setup_worktree).expect("canonical B worktree");
    let setup_marker =
        std::fs::read_to_string(setup_worktree.join("setup-marker")).expect("setup marker on B");
    assert!(setup_marker.contains(&format!("ROOT={}", canonical_project.display())));
    assert!(setup_marker.contains(&format!("WT={}", canonical_worktree.display())));
    assert!(setup_marker.contains(&format!("CWD={}", canonical_worktree.display())));
    assert!(!dirs.path().join("a").join("setup-marker").exists());
    client
        .call(
            methods::CLOSE_TERMINAL,
            serde_json::json!({
                "terminalId": setup_terminal,
                "targetDeviceId": "device-b",
            }),
        )
        .await
        .expect("close remote setup terminal");
    client
        .call(
            methods::DELETE_WORKTREE,
            serde_json::json!({
                "repoPath": project_root,
                "worktreePath": setup_worktree,
                "targetDeviceId": "device-b",
            }),
        )
        .await
        .expect("delete remote setup worktree");

    let deleted = client
        .call(
            methods::DELETE_PROJECT_ACTION,
            serde_json::json!({
                "spaceId": "space-actions",
                "actionId": action_id,
                "targetDeviceId": "device-b",
            }),
        )
        .await
        .expect("delete remote Action");
    assert!(deleted["actions"].as_array().unwrap().is_empty());

    let moved_root = dirs.path().join("project-moved-on-b");
    std::fs::create_dir_all(&moved_root).expect("moved project root");
    let mut moved_space = core_b
        .workspace
        .space("space-actions")
        .expect("read space")
        .expect("space exists");
    moved_space.path = moved_root.to_string_lossy().to_string();
    core_b
        .workspace
        .import_space_row(&moved_space)
        .expect("replace space root");
    let changed_root = client
        .call(
            methods::LIST_PROJECT_ACTIONS,
            serde_json::json!({
                "spaceId": "space-actions",
                "targetDeviceId": "device-b",
            }),
        )
        .await
        .expect_err("changed project root rejected by B");
    assert!(
        changed_root
            .to_string()
            .contains("identity no longer matches")
    );

    let missing = client
        .call(
            methods::LIST_PROJECT_ACTIONS,
            serde_json::json!({
                "spaceId": "missing",
                "targetDeviceId": "device-b",
            }),
        )
        .await
        .expect_err("missing space rejected by B");
    assert!(missing.to_string().contains("Project space not found"));
    core_b
        .workspace
        .create_space(
            "space-wrong-owner",
            "device-a",
            &project_root.to_string_lossy(),
            None,
            true,
        )
        .expect("foreign-owned row on B");
    let wrong_owner = client
        .call(
            methods::LIST_PROJECT_ACTIONS,
            serde_json::json!({
                "spaceId": "space-wrong-owner",
                "targetDeviceId": "device-b",
            }),
        )
        .await
        .expect_err("foreign-owned space rejected by B");
    assert!(
        wrong_owner
            .to_string()
            .contains("belongs to another device")
    );

    core_a.shutdown().await;
    core_b.shutdown().await;
}

/// M5: terminals are device-addressable — OpenTerminal/WriteTerminal forward as
/// unary calls and SubscribeTerminal proxies its stream through the relay.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn terminal_stream_proxies_over_the_relay() {
    use base64::Engine as _;
    use base64::engine::general_purpose::STANDARD as BASE64;

    let (relay_url, _relay) = fake_device_room().await;
    let dirs = tempfile::tempdir().expect("tempdir");
    let cwd = dirs.path().join("work");
    std::fs::create_dir_all(&cwd).expect("cwd");

    // Engine B hosts its device room; its chat row (via its space) pins the
    // terminal cwd.
    let core_b = assemble(&dirs.path().join("b"), "device-b");
    core_b
        .workspace
        .create_space(
            "space-term",
            "device-b",
            &cwd.to_string_lossy(),
            None,
            false,
        )
        .expect("space row on B");
    core_b
        .workspace
        .create_chat("chat-term", Some("space-term"), None, None, None)
        .expect("chat row on B");
    let _host = core_b.start_host_relay(&relay_url);

    let core_a = assemble(&dirs.path().join("a"), "device-a");
    let mut link_config =
        LinkCacheConfig::new(relay_url.clone(), Arc::new(StaticToken("test-user".into())));
    link_config.probe_timeout = Duration::from_secs(5);
    core_a.set_links(LinkCache::new(link_config));
    let client = zeron_rpc::memory_client(core_a.rpc_service());

    // OpenTerminal forwards to B once the relay session is up.
    let deadline = tokio::time::Instant::now() + Duration::from_secs(15);
    let session = loop {
        match client
            .call(
                methods::OPEN_TERMINAL,
                serde_json::json!({
                    "chatId": "chat-term",
                    "cols": 80,
                    "rows": 24,
                    "targetDeviceId": "device-b",
                }),
            )
            .await
        {
            Ok(session) => break session,
            Err(err) => {
                assert!(
                    tokio::time::Instant::now() < deadline,
                    "relay never came up: {err}"
                );
                tokio::time::sleep(Duration::from_millis(200)).await;
            }
        }
    };
    let terminal_id = session["id"].as_str().expect("terminal id").to_string();
    assert_eq!(
        session["cwd"].as_str(),
        Some(&*cwd.to_string_lossy()),
        "cwd from B's chat row"
    );

    // SubscribeTerminal: the stream is proxied item-by-item through the relay.
    let mut stream = client
        .subscribe(
            methods::SUBSCRIBE_TERMINAL,
            serde_json::json!({ "terminalId": terminal_id, "targetDeviceId": "device-b" }),
        )
        .await
        .expect("remote subscribe");
    client
        .call(
            methods::WRITE_TERMINAL,
            serde_json::json!({
                "terminalId": terminal_id,
                "data": BASE64.encode("echo r3lay-$((20+2))\n"),
                "targetDeviceId": "device-b",
            }),
        )
        .await
        .expect("remote write");
    let deadline = tokio::time::Instant::now() + Duration::from_secs(15);
    let mut transcript = Vec::new();
    loop {
        let item = tokio::time::timeout_at(deadline, stream.recv())
            .await
            .expect("proxied terminal output before timeout")
            .expect("stream alive");
        if item["type"] == "data" {
            let bytes = BASE64
                .decode(item["data"].as_str().expect("data"))
                .expect("valid base64");
            transcript.extend(bytes);
        }
        if String::from_utf8_lossy(&transcript).contains("r3lay-22") {
            break;
        }
    }

    client
        .call(
            methods::CLOSE_TERMINAL,
            serde_json::json!({ "terminalId": terminal_id, "targetDeviceId": "device-b" }),
        )
        .await
        .expect("remote close");

    core_a.shutdown().await;
    core_b.shutdown().await;
}

#[tokio::test]
async fn remote_target_without_links_fails_clearly() {
    let dirs = tempfile::tempdir().expect("tempdir");
    let core = assemble(&dirs.path().join("solo"), "device-solo");
    let client = zeron_rpc::memory_client(core.rpc_service());
    for (method, params) in [
        (
            methods::LIST_PROJECT_ACTIONS,
            serde_json::json!({
                "spaceId": "remote-space",
                "targetDeviceId": "device-elsewhere",
            }),
        ),
        (
            methods::UPSERT_PROJECT_ACTION,
            serde_json::json!({
                "spaceId": "remote-space",
                "action": { "name": "Build", "command": "make", "icon": "build" },
                "targetDeviceId": "device-elsewhere",
            }),
        ),
        (
            methods::RUN_PROJECT_ACTION,
            serde_json::json!({
                "spaceId": "remote-space",
                "chatId": "remote-chat",
                "actionId": "build",
                "cols": 80,
                "rows": 24,
                "targetDeviceId": "device-elsewhere",
            }),
        ),
    ] {
        let err = client
            .call(method, params)
            .await
            .expect_err("offline Action forward must fail");
        assert!(
            err.to_string().contains("remote routing unavailable"),
            "{method}: {err}"
        );
    }
    let mut offline_stream = client
        .subscribe(
            methods::SUBSCRIBE_TERMINAL,
            serde_json::json!({
                "terminalId": "remote-terminal",
                "targetDeviceId": "device-elsewhere",
            }),
        )
        .await
        .expect("stream request is accepted before the server reports routing failure");
    assert!(
        tokio::time::timeout(Duration::from_secs(1), offline_stream.recv())
            .await
            .expect("offline stream closes promptly")
            .is_none(),
        "offline subscribe must not produce local terminal output"
    );
    core.shutdown().await;
}
