//! Voice for `graff tui`: the Codex TUI's realtime conversation, with graff
//! doing the work.
//!
//! The TUI owns the microphone and speaker (Codex's voice helper) and only
//! asks its app-server for the realtime session: `thread/realtime/start` with
//! a WebRTC offer, `stop`, `appendSpeech`, `listVoices`. Realtime needs a real
//! Codex app-server and the Codex CLI's sign-in, so this relays those calls to
//! a private `codex app-server` child. Each bridge thread gets a shadow Codex
//! thread there (ephemeral, read-only, every tool off) that only hosts the
//! session; ids are rewritten both ways.
//!
//! When the voice model hands work off, Codex starts a turn on the shadow
//! thread with a `<realtime_delegation>` input. The relay interrupts that turn
//! and starts the same input as a graff turn on the bridge thread instead, so
//! the TUI sees an ordinary delegated turn, graff does the work, and the TUI
//! speaks graff's answer back with `appendSpeech` as it does for Codex.

use std::collections::HashMap;
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::{Arc, Mutex, Weak};
use std::time::Duration;

use harness_adapters::process::{Command, Stdio};
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::{OnceCell, mpsc, oneshot};

use crate::wire::{After, Conn, RpcError};

type Reply = (Result<Value, RpcError>, After);
type Pending = Arc<Mutex<HashMap<i64, oneshot::Sender<Result<Value, Value>>>>>;

/// Shadow threads never act on their own; the realtime session only.
const SHADOW_INSTRUCTIONS: &str = "This thread only hosts a voice session. Work handed off \
from voice is done elsewhere. Never call tools or take any action here.";

/// The relay for one TUI connection, started on its first realtime call.
#[derive(Default)]
pub struct Voice {
    relay: OnceCell<Arc<Relay>>,
}

struct Relay {
    writer: mpsc::UnboundedSender<String>,
    pending: Pending,
    next_id: AtomicI64,
    /// bridge thread id ↔ shadow Codex thread id.
    shadows: Mutex<Shadows>,
    /// Shadow turns already handed to graff (turn/started and the user item
    /// can both reveal one).
    delegated: Mutex<std::collections::HashSet<String>>,
    _child: Mutex<harness_adapters::process::Child>,
}

#[derive(Default)]
struct Shadows {
    by_bridge: HashMap<String, String>,
    by_shadow: HashMap<String, String>,
}

/// `thread/realtime/*` from the TUI.
pub async fn handle(conn: &Arc<Conn>, method: &str, mut params: Value) -> Reply {
    let relay = match conn
        .voice
        .relay
        .get_or_try_init(|| Relay::spawn(Arc::downgrade(conn)))
        .await
    {
        Ok(relay) => relay.clone(),
        Err(message) => return (Err(RpcError::internal(message)), None),
    };
    if let Some(bridge) = params
        .get("threadId")
        .and_then(Value::as_str)
        .map(str::to_owned)
    {
        let shadow = match relay.shadow_for(&bridge).await {
            Ok(shadow) => shadow,
            Err(message) => return (Err(RpcError::internal(message)), None),
        };
        params["threadId"] = json!(shadow);
    }
    match relay.request(method, params).await {
        Ok(result) => (Ok(result), None),
        Err(error) => (Err(rpc_error(&error)), None),
    }
}

/// Codex's error message, for the TUI.
fn rpc_error(error: &Value) -> RpcError {
    let message = error
        .get("message")
        .and_then(Value::as_str)
        .unwrap_or("Codex voice request failed");
    match error.get("code").and_then(Value::as_i64) {
        Some(-32602) => RpcError::invalid_params(message),
        _ => RpcError::internal(message),
    }
}

impl Relay {
    async fn spawn(conn: Weak<Conn>) -> Result<Arc<Self>, String> {
        let exe = harness_adapters::codex::resolve_codex_executable()
            .ok_or("Voice needs the Codex CLI: install it and sign in with `codex login`.")?;
        let mut cmd = Command::new(&exe);
        cmd.arg("app-server");
        harness_adapters::compose_child_path(&mut cmd, &exe);
        // graff-tui points CODEX_HOME at its own config home (Harness model
        // ids, no Codex sign-in). Codex itself needs the user's real home.
        if std::env::var_os("CODEX_HOME").is_some_and(|home| is_tui_default_home(home.as_ref())) {
            cmd.env_remove("CODEX_HOME");
        }
        cmd.stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .kill_on_drop(true);
        let mut child = cmd
            .spawn()
            .map_err(|e| format!("Codex could not start: {e}"))?;
        let (Some(mut stdin), Some(stdout)) = (child.stdin.take(), child.stdout.take()) else {
            return Err("Codex could not start.".into());
        };
        let (writer, mut lines) = mpsc::unbounded_channel::<String>();
        tokio::spawn(async move {
            while let Some(line) = lines.recv().await {
                if stdin.write_all(line.as_bytes()).await.is_err()
                    || stdin.write_all(b"\n").await.is_err()
                    || stdin.flush().await.is_err()
                {
                    break;
                }
            }
        });
        let relay = Arc::new(Self {
            writer,
            pending: Pending::default(),
            next_id: AtomicI64::new(1),
            shadows: Mutex::new(Shadows::default()),
            delegated: Mutex::new(std::collections::HashSet::new()),
            _child: Mutex::new(child),
        });
        let reader = Arc::downgrade(&relay);
        tokio::spawn(async move {
            let mut lines = BufReader::new(stdout).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                let Ok(message) = serde_json::from_str::<Value>(&line) else {
                    continue;
                };
                let Some(relay) = reader.upgrade() else { break };
                relay.inbound(message, &conn).await;
            }
            // Codex exited: fail what is pending and close any live session.
            if let Some(relay) = reader.upgrade() {
                relay.closed(&conn);
            }
        });
        tokio::time::timeout(
            Duration::from_secs(20),
            relay.request(
                "initialize",
                json!({
                    "clientInfo": {"name": "harness-tui-bridge", "title": "Harness", "version": env!("CARGO_PKG_VERSION")},
                    "capabilities": {"experimentalApi": true},
                }),
            ),
        )
        .await
        .map_err(|_| "Codex did not answer.".to_string())?
        .map_err(|e| format!("Codex: {}", rpc_error(&e).message))?;
        relay.notify("initialized", None);
        Ok(relay)
    }

    fn send(&self, message: Value) {
        let _ = self.writer.send(message.to_string());
    }

    fn notify(&self, method: &str, params: Option<Value>) {
        let mut message = json!({"jsonrpc": "2.0", "method": method});
        if let Some(params) = params {
            message["params"] = params;
        }
        self.send(message);
    }

    async fn request(&self, method: &str, params: Value) -> Result<Value, Value> {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let (tx, rx) = oneshot::channel();
        self.pending.lock().expect("pending lock").insert(id, tx);
        self.send(json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params}));
        rx.await
            .unwrap_or_else(|_| Err(json!({"message": "Codex stopped"})))
    }

    /// The shadow Codex thread for a bridge thread, created on first use.
    async fn shadow_for(&self, bridge: &str) -> Result<String, String> {
        if let Some(shadow) = self
            .shadows
            .lock()
            .expect("shadows lock")
            .by_bridge
            .get(bridge)
        {
            return Ok(shadow.clone());
        }
        let started = self
            .request("thread/start", shadow_thread_params())
            .await
            .map_err(|e| format!("Codex: {}", rpc_error(&e).message))?;
        let shadow = started["thread"]["id"]
            .as_str()
            .filter(|id| !id.is_empty())
            .ok_or("Codex started no thread for voice.")?
            .to_owned();
        let mut shadows = self.shadows.lock().expect("shadows lock");
        shadows.by_shadow.insert(shadow.clone(), bridge.to_owned());
        shadows.by_bridge.insert(bridge.to_owned(), shadow.clone());
        Ok(shadow)
    }

    fn bridge_for(&self, shadow: &str) -> Option<String> {
        self.shadows
            .lock()
            .expect("shadows lock")
            .by_shadow
            .get(shadow)
            .cloned()
    }

    async fn inbound(&self, message: Value, conn: &Weak<Conn>) {
        let method = message.get("method").and_then(Value::as_str);
        match (message.get("id"), method) {
            // A response to one of our requests.
            (Some(id), None) => {
                let Some(id) = id.as_i64() else { return };
                if let Some(tx) = self.pending.lock().expect("pending lock").remove(&id) {
                    let _ = tx.send(match message.get("error") {
                        Some(error) => Err(error.clone()),
                        None => Ok(message.get("result").cloned().unwrap_or(Value::Null)),
                    });
                }
            }
            // A server request (approvals): the shadow thread never acts.
            (Some(id), Some(_)) => {
                self.send(json!({"jsonrpc": "2.0", "id": id, "error": {"code": -32601, "message": "not supported on a voice thread"}}));
            }
            (None, Some(method)) => {
                let params = message.get("params").cloned().unwrap_or(Value::Null);
                let Some(conn) = conn.upgrade() else { return };
                self.notification(method, params, &conn).await;
            }
            _ => {}
        }
    }

    async fn notification(&self, method: &str, mut params: Value, conn: &Arc<Conn>) {
        let Some(shadow) = params
            .get("threadId")
            .and_then(Value::as_str)
            .map(str::to_owned)
        else {
            return;
        };
        let Some(bridge) = self.bridge_for(&shadow) else {
            return;
        };
        match route(method, &params) {
            Route::Realtime => {
                params["threadId"] = json!(bridge);
                conn.notify(method, params);
            }
            Route::Delegation { turn_id, input } => {
                if !self
                    .delegated
                    .lock()
                    .expect("delegated lock")
                    .insert(turn_id.clone())
                {
                    return;
                }
                // Codex would do the handed-off work itself: stop that turn and
                // give the same input to graff on the TUI's thread.
                start_graff_turn(conn, &bridge, input);
                self.notify_interrupt(&shadow, &turn_id).await;
            }
            Route::Drop => {}
        }
    }

    async fn notify_interrupt(&self, shadow: &str, turn: &str) {
        let _ = tokio::time::timeout(
            Duration::from_secs(5),
            self.request(
                "turn/interrupt",
                json!({"threadId": shadow, "turnId": turn}),
            ),
        )
        .await;
    }

    fn closed(&self, conn: &Weak<Conn>) {
        for (_, tx) in self.pending.lock().expect("pending lock").drain() {
            let _ = tx.send(Err(json!({"message": "Codex stopped"})));
        }
        let Some(conn) = conn.upgrade() else { return };
        let bridges: Vec<String> = self
            .shadows
            .lock()
            .expect("shadows lock")
            .by_bridge
            .keys()
            .cloned()
            .collect();
        for bridge in bridges {
            conn.notify(
                "thread/realtime/closed",
                json!({"threadId": bridge, "reason": "Codex stopped"}),
            );
        }
    }
}

/// What to do with a shadow-thread notification.
#[derive(Debug, PartialEq)]
enum Route {
    /// The realtime session's own events: the TUI's.
    Realtime,
    /// Codex started a turn for work handed off from voice.
    Delegation { turn_id: String, input: Value },
    /// The shadow thread's own bookkeeping and output: never shown.
    Drop,
}

fn route(method: &str, params: &Value) -> Route {
    if method.starts_with("thread/realtime/") {
        return Route::Realtime;
    }
    if method == "turn/started" {
        let turn = &params["turn"];
        let input = turn
            .get("items")
            .and_then(Value::as_array)
            .and_then(|items| items.iter().find(|i| i["type"] == "userMessage"))
            .and_then(|item| item.get("content").cloned());
        if let (Some(turn_id), Some(input)) = (turn["id"].as_str(), input)
            && is_delegation(&input)
        {
            return Route::Delegation {
                turn_id: turn_id.to_owned(),
                input,
            };
        }
    }
    // Codex announces the turn before its input: the user message item names
    // the turn it opens.
    if method == "item/started"
        && params["item"]["type"] == "userMessage"
        && let (Some(turn_id), Some(input)) =
            (params["turnId"].as_str(), params["item"].get("content"))
        && is_delegation(input)
    {
        return Route::Delegation {
            turn_id: turn_id.to_owned(),
            input: input.clone(),
        };
    }
    Route::Drop
}

fn is_delegation(input: &Value) -> bool {
    input.as_array().is_some_and(|parts| {
        parts.iter().any(|part| {
            part["text"]
                .as_str()
                .is_some_and(|t| t.trim_start().starts_with("<realtime_delegation>"))
        })
    })
}

/// The handed-off input as a graff turn on the TUI's thread; a steer when a
/// turn is already running there.
fn start_graff_turn(conn: &Arc<Conn>, bridge: &str, input: Value) {
    let params = json!({"threadId": bridge, "input": input});
    // The turn's own run announces it to the TUI (turn/started, user item).
    let (result, after) = crate::turn::start(conn, params.clone());
    match result {
        Ok(_) => {
            if let Some(after) = after {
                tokio::spawn(after);
            }
        }
        Err(_) => {
            let (_, after) = crate::turn::steer(conn, params);
            if let Some(after) = after {
                tokio::spawn(after);
            }
        }
    }
}

/// The config home `graff-tui` defaults CODEX_HOME to (not a Codex home).
fn is_tui_default_home(home: &std::path::Path) -> bool {
    std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" })
        .map(std::path::PathBuf::from)
        .is_some_and(|base| base.join(".harness/tui/codex-home") == home)
}

/// A thread that can host a realtime session and nothing else.
fn shadow_thread_params() -> Value {
    json!({
        "cwd": std::env::temp_dir().to_string_lossy(),
        "ephemeral": true,
        "approvalPolicy": "never",
        "sandbox": "read-only",
        "baseInstructions": SHADOW_INSTRUCTIONS,
        "developerInstructions": SHADOW_INSTRUCTIONS,
        "config": {
            "project_doc_max_bytes": 0,
            "web_search": "disabled",
            "features.shell_tool": false,
            "features.apply_patch_freeform": false,
            "features.multi_agent": false,
            "features.multi_agent_v2": false,
            "features.apps": false,
            "agents.enabled": false,
            "features.browser_use": false,
            "features.computer_use": false,
            "features.js_repl": false,
            "features.image_generation": false,
            "features.memories": false
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn realtime_events_pass_and_delegations_are_rerouted() {
        assert_eq!(
            route(
                "thread/realtime/transcript/delta",
                &json!({"threadId": "s"})
            ),
            Route::Realtime
        );
        let delegation = json!([{"type": "text", "text": "<realtime_delegation>fix the build</realtime_delegation>"}]);
        assert_eq!(
            route(
                "turn/started",
                &json!({"threadId": "s", "turn": {"id": "t1", "items": [{"type": "userMessage", "content": delegation}]}})
            ),
            Route::Delegation {
                turn_id: "t1".into(),
                input: delegation.clone()
            }
        );
        assert_eq!(
            route(
                "item/started",
                &json!({"threadId": "s", "turnId": "t3", "item": {"type": "userMessage", "content": delegation}})
            ),
            Route::Delegation {
                turn_id: "t3".into(),
                input: delegation.clone()
            }
        );
        // A turn that isn't a handoff, and the shadow's own items, stay hidden.
        assert_eq!(
            route(
                "turn/started",
                &json!({"threadId": "s", "turn": {"id": "t2", "items": [{"type": "userMessage", "content": [{"type": "text", "text": "hi"}]}]}})
            ),
            Route::Drop
        );
        assert_eq!(
            route("item/agentMessage/delta", &json!({"threadId": "s"})),
            Route::Drop
        );
    }

    /// The whole relay against an offline Codex: realtime calls and events
    /// travel with the ids rewritten, and a handoff becomes a graff turn on the
    /// TUI's thread while the Codex turn is interrupted.
    #[cfg(unix)]
    #[tokio::test]
    async fn the_relay_rewrites_ids_and_hands_delegations_to_graff() {
        let dir = std::env::temp_dir().join(format!("voice-relay-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let log = dir.join("codex.jsonl");
        let fake = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("tests/fixtures/fake-codex-voice.py");
        // SAFETY: the only test in this binary that reads these variables.
        unsafe {
            std::env::set_var("CODEX_EXECUTABLE", &fake);
            std::env::set_var("FAKE_VOICE_LOG", &log);
        }
        let (conn, mut rx) = Conn::for_test(Arc::new(harness_engine::HarnessRegistry::new()));
        conn.threads.lock().unwrap().insert(
            "t1".into(),
            crate::wire::ThreadState {
                cwd: "/tmp".into(),
                harness: harness_proto::HarnessId::Graff,
                model: None,
                resume: None,
                interrupt: None,
                turn_id: None,
                steer: None,
                steers: Default::default(),
                steerable: false,
            },
        );

        let (voices, _) = handle(&conn, "thread/realtime/listVoices", json!({})).await;
        assert_eq!(voices.ok().unwrap()["voices"]["v1"][0], "cedar");
        let (started, _) = handle(
            &conn,
            "thread/realtime/start",
            json!({"threadId": "t1", "transport": {"type": "webrtc", "sdp": "offer"}}),
        )
        .await;
        assert!(started.is_ok(), "{:?}", started.err().map(|e| e.message));

        // What the TUI sees, until graff's delegated turn shows its input.
        let mut seen = Vec::new();
        tokio::time::timeout(Duration::from_secs(10), async {
            while let Some(message) = rx.recv().await {
                let done = message["method"] == "item/started"
                    && message["params"]["item"]["type"] == "userMessage";
                seen.push(message);
                if done {
                    break;
                }
            }
        })
        .await
        .expect("delegated turn");
        let methods: Vec<&str> = seen.iter().filter_map(|m| m["method"].as_str()).collect();
        assert!(
            methods.starts_with(&[
                "thread/realtime/started",
                "thread/realtime/sdp",
                "thread/realtime/transcript/delta",
            ]),
            "{methods:?}"
        );
        assert!(
            seen.iter().all(|m| m["params"]["threadId"] == "t1"),
            "{seen:?}"
        );
        // Codex's own turn output never reaches the TUI.
        assert!(!methods.contains(&"item/agentMessage/delta"), "{methods:?}");
        let user = seen.last().unwrap();
        assert_eq!(
            user["params"]["item"]["content"][0]["text"],
            "<realtime_delegation>run the tests</realtime_delegation>"
        );

        let (stopped, _) = handle(&conn, "thread/realtime/stop", json!({"threadId": "t1"})).await;
        assert!(stopped.is_ok());
        let requests: Vec<Value> = std::fs::read_to_string(&log)
            .unwrap()
            .lines()
            .map(|l| serde_json::from_str(l).unwrap())
            .collect();
        let find = |m: &str| requests.iter().find(|r| r["method"] == m).cloned();
        let shadow = find("thread/start").unwrap();
        assert_eq!(shadow["params"]["ephemeral"], true);
        assert_eq!(shadow["params"]["sandbox"], "read-only");
        assert_eq!(
            find("thread/realtime/start").unwrap()["params"]["threadId"],
            "shadow-1"
        );
        assert_eq!(
            find("thread/realtime/stop").unwrap()["params"]["threadId"],
            "shadow-1"
        );
        let interrupt = find("turn/interrupt").expect("the Codex turn is interrupted");
        assert_eq!(
            interrupt["params"],
            json!({"threadId": "shadow-1", "turnId": "shadow-turn"})
        );
        assert_eq!(
            requests
                .iter()
                .filter(|r| r["method"] == "turn/interrupt")
                .count(),
            1,
            "one handoff, one graff turn"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_shadow_thread_cannot_act() {
        let p = shadow_thread_params();
        assert_eq!(p["ephemeral"], true);
        assert_eq!(p["sandbox"], "read-only");
        assert_eq!(p["config"]["features.shell_tool"], false);
        assert_eq!(p["config"]["project_doc_max_bytes"], 0);
    }
}
