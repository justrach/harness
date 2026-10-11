//! Websocket + JSON-RPC plumbing for one TUI connection.
//!
//! Codex's wire format is JSON-RPC 2.0 without the `"jsonrpc"` member, so
//! messages are handled as `serde_json::Value` and checked against the schema
//! fixtures in `codex-rs/app-server-protocol/schema` rather than typed here.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use anyhow::Result;
use futures::future::BoxFuture;
use futures::{SinkExt, StreamExt};
use harness_engine::HarnessRegistry;
use harness_proto::HarnessId;
use serde_json::{Value, json};
use tokio::net::TcpStream;
use tokio::sync::{mpsc, oneshot};
use tokio_tungstenite::tungstenite::Message;
use tokio_util::sync::CancellationToken;

/// JSON-RPC error a handler can return.
pub struct RpcError {
    pub code: i64,
    pub message: String,
    /// Structured detail the TUI parses (e.g. a `TurnError`).
    pub data: Option<Value>,
}

impl RpcError {
    pub fn method_not_found(method: &str) -> Self {
        Self {
            code: -32601,
            message: format!("harness-tui-bridge does not implement `{method}`"),
            data: None,
        }
    }

    pub fn internal(message: impl Into<String>) -> Self {
        Self {
            code: -32603,
            message: message.into(),
            data: None,
        }
    }

    pub fn invalid_params(message: impl Into<String>) -> Self {
        Self {
            code: -32602,
            message: message.into(),
            data: None,
        }
    }

    /// The active turn cannot take same-turn input; the TUI queues the
    /// message and sends it as the next turn instead.
    pub fn not_steerable(message: impl Into<String>) -> Self {
        let message = message.into();
        Self {
            code: -32602,
            data: Some(json!({
                "message": message,
                "codexErrorInfo": { "activeTurnNotSteerable": { "turnKind": "review" } },
                "additionalDetails": null,
            })),
            message,
        }
    }

}

/// Work that must run only after the response has been written, so a client
/// never sees a notification for a request it has not been answered yet.
pub type After = Option<BoxFuture<'static, ()>>;

pub struct ThreadState {
    pub cwd: String,
    pub harness: HarnessId,
    pub model: Option<String>,
    /// Harness-native session id, learned from the first turn, for resume.
    pub resume: Option<String>,
    /// Cancels the turn currently running on this thread.
    pub interrupt: Option<CancellationToken>,
    /// The Codex turn running on this thread, which `turn/steer` must name.
    pub turn_id: Option<String>,
    /// The running turn's steering mailbox. Closed when the agent's turn
    /// ends, so a parked session finishes instead of waiting for more input.
    pub steer: Option<mpsc::Sender<harness_adapters::SteerMessage>>,
    /// Accepted steers not yet picked up by the agent, as the `userMessage`
    /// items to show when it reports `Steered`, oldest first.
    pub steers: std::collections::VecDeque<Value>,
    /// The running agent reads its steering mailbox. Until it is known (or
    /// for an agent that doesn't), steers are refused as not steerable and
    /// the TUI sends them as the next turn instead.
    pub steerable: bool,
    /// Engine mode: message ids this TUI minted for the chat → the TUI's
    /// `clientUserMessageId`, so its own messages are recognized when the
    /// chat echoes them.
    pub client_ids: HashMap<String, String>,
    /// Engine mode: the TUI asked to interrupt the running turn.
    pub interrupted: bool,
}

impl ThreadState {
    pub fn new(cwd: String, harness: HarnessId, model: Option<String>) -> Self {
        Self {
            cwd,
            harness,
            model,
            resume: None,
            interrupt: None,
            turn_id: None,
            steer: None,
            steers: Default::default(),
            steerable: false,
            client_ids: HashMap::new(),
            interrupted: false,
        }
    }
}

pub struct Conn {
    out: mpsc::UnboundedSender<Value>,
    pub registry: Arc<HarnessRegistry>,
    pub threads: Mutex<HashMap<String, ThreadState>>,
    /// The Harness engine this TUI shares chats with, when one is running.
    /// `None` runs agents in this process (standalone mode).
    pub engine: Option<Arc<crate::engine::Engine>>,
    /// Engine-mode chat mirrors, one per thread the TUI has open.
    pub mirrors: Mutex<HashMap<String, tokio::task::JoinHandle<()>>>,
    /// Server-to-client requests awaiting the TUI's answer.
    pending: Mutex<HashMap<String, oneshot::Sender<Result<Value, Value>>>>,
    next_request: std::sync::atomic::AtomicU64,
}

impl Conn {
    fn new(
        out: mpsc::UnboundedSender<Value>,
        registry: Arc<HarnessRegistry>,
        engine: Option<Arc<crate::engine::Engine>>,
    ) -> Self {
        Self {
            out,
            registry,
            threads: Mutex::new(HashMap::new()),
            engine,
            mirrors: Mutex::new(HashMap::new()),
            pending: Mutex::new(HashMap::new()),
            next_request: std::sync::atomic::AtomicU64::new(1),
        }
    }

    #[cfg(test)]
    pub fn for_test(registry: Arc<HarnessRegistry>) -> (Arc<Self>, mpsc::UnboundedReceiver<Value>) {
        let (out, rx) = mpsc::unbounded_channel();
        (Arc::new(Self::new(out, registry, None)), rx)
    }

    /// Ask the TUI something (a question for the user) and wait for its
    /// answer. `Err` carries the TUI's JSON-RPC error, or `null` when the
    /// connection closed first.
    pub async fn request(&self, method: &str, params: Value) -> Result<Value, Value> {
        let n = self
            .next_request
            .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let id = format!("harness-bridge-{n}");
        let (tx, rx) = oneshot::channel();
        self.pending
            .lock()
            .expect("pending lock")
            .insert(id.clone(), tx);
        let _ = self
            .out
            .send(json!({ "id": id, "method": method, "params": params }));
        rx.await.unwrap_or(Err(Value::Null))
    }

    fn answer(&self, message: &Value) {
        let Some(id) = message.get("id").and_then(Value::as_str) else {
            return;
        };
        let Some(tx) = self.pending.lock().expect("pending lock").remove(id) else {
            return;
        };
        let reply = match message.get("error") {
            Some(error) => Err(error.clone()),
            None => Ok(message.get("result").cloned().unwrap_or(Value::Null)),
        };
        let _ = tx.send(reply);
    }

    pub fn notify(&self, method: &str, params: Value) {
        let _ = self.out.send(json!({ "method": method, "params": params }));
    }

    fn respond(&self, id: Value, result: Result<Value, RpcError>) {
        let message = match result {
            Ok(result) => json!({ "id": id, "result": result }),
            Err(err) => match err.data {
                Some(data) => {
                    json!({ "id": id, "error": { "code": err.code, "message": err.message, "data": data } })
                }
                None => json!({ "id": id, "error": { "code": err.code, "message": err.message } }),
            },
        };
        let _ = self.out.send(message);
    }
}

pub async fn serve(
    stream: TcpStream,
    registry: Arc<HarnessRegistry>,
    engine: Option<Arc<crate::engine::Engine>>,
) -> Result<()> {
    let ws = tokio_tungstenite::accept_async(stream).await?;
    let (mut sink, mut source) = ws.split();
    let (out, mut outgoing) = mpsc::unbounded_channel::<Value>();
    let conn = Arc::new(Conn::new(out, registry, engine));

    let writer = tokio::spawn(async move {
        while let Some(value) = outgoing.recv().await {
            if sink.send(Message::text(value.to_string())).await.is_err() {
                break;
            }
        }
    });

    while let Some(frame) = source.next().await {
        let text = match frame? {
            Message::Text(text) => text,
            Message::Close(_) => break,
            _ => continue,
        };
        let Ok(message) = serde_json::from_str::<Value>(&text) else {
            tracing::warn!("dropping non-JSON frame");
            continue;
        };
        let method = message.get("method").and_then(Value::as_str).map(str::to_owned);
        match (method, message.get("id").cloned()) {
            (Some(method), Some(id)) => {
                let params = message.get("params").cloned().unwrap_or(Value::Null);
                let conn = conn.clone();
                tokio::spawn(async move {
                    tracing::info!(%method, "request");
                    let (result, after) = crate::methods::handle(&conn, &method, params).await;
                    if let Err(err) = &result {
                        tracing::warn!(%method, code = err.code, message = %err.message, "request failed");
                    }
                    conn.respond(id, result);
                    if let Some(after) = after {
                        after.await;
                    }
                });
            }
            (Some(method), None) => tracing::debug!(%method, "client notification"),
            // The TUI's answer to a request this bridge sent (a question).
            (None, Some(_)) => conn.answer(&message),
            (None, None) => tracing::debug!("frame without method or id ignored"),
        }
    }

    // Stop any turn still running for this connection. Engine-mode turns
    // belong to the chat, not the TUI: they keep running, like a chat left
    // open in the desktop app; only the mirrors stop.
    for thread in conn.threads.lock().expect("threads lock").values() {
        if let Some(token) = &thread.interrupt {
            token.cancel();
        }
    }
    for (_, mirror) in conn.mirrors.lock().expect("mirrors lock").drain() {
        mirror.abort();
    }
    conn.pending.lock().expect("pending lock").clear();
    writer.abort();
    Ok(())
}
