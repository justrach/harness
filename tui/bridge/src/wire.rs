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
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::Message;
use tokio_util::sync::CancellationToken;

/// JSON-RPC error a handler can return.
pub struct RpcError {
    pub code: i64,
    pub message: String,
}

impl RpcError {
    pub fn method_not_found(method: &str) -> Self {
        Self {
            code: -32601,
            message: format!("harness-tui-bridge does not implement `{method}`"),
        }
    }

    pub fn internal(message: impl Into<String>) -> Self {
        Self {
            code: -32603,
            message: message.into(),
        }
    }

    pub fn invalid_params(message: impl Into<String>) -> Self {
        Self {
            code: -32602,
            message: message.into(),
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
}

pub struct Conn {
    out: mpsc::UnboundedSender<Value>,
    pub registry: Arc<HarnessRegistry>,
    pub threads: Mutex<HashMap<String, ThreadState>>,
}

impl Conn {
    pub fn notify(&self, method: &str, params: Value) {
        let _ = self.out.send(json!({ "method": method, "params": params }));
    }

    fn respond(&self, id: Value, result: Result<Value, RpcError>) {
        let message = match result {
            Ok(result) => json!({ "id": id, "result": result }),
            Err(err) => json!({ "id": id, "error": { "code": err.code, "message": err.message } }),
        };
        let _ = self.out.send(message);
    }
}

pub async fn serve(stream: TcpStream, registry: Arc<HarnessRegistry>) -> Result<()> {
    let ws = tokio_tungstenite::accept_async(stream).await?;
    let (mut sink, mut source) = ws.split();
    let (out, mut outgoing) = mpsc::unbounded_channel::<Value>();
    let conn = Arc::new(Conn {
        out,
        registry,
        threads: Mutex::new(HashMap::new()),
    });

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
            // A response to a server request (approvals, elicitation); none are issued yet.
            (None, _) => tracing::debug!("client response ignored"),
        }
    }

    // Stop any turn still running for this connection.
    for thread in conn.threads.lock().expect("threads lock").values() {
        if let Some(token) = &thread.interrupt {
            token.cancel();
        }
    }
    writer.abort();
    Ok(())
}
