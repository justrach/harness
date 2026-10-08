//! Engine mode: when a Harness engine is running (the desktop app, or
//! `harness headless`), the TUI is one more client of it, like the desktop
//! and phone apps. Threads are Harness chats, turns go through the chat's
//! command queue, and transcripts come from the chat docs, so a chat started
//! in the TUI shows up in the desktop sidebar and on the phone, and the
//! other way round.
//!
//! Without an engine the bridge runs agents in its own process (standalone
//! mode), as before.

use std::sync::Arc;
use std::time::Duration;

use harness_mcp::{Harness, Origin};

/// The engine's default loopback IPC port (`HARNESS_IPC_PORT` overrides it).
const DEFAULT_IPC_PORT: u16 = 27664;
/// How long startup waits for an engine to answer before going standalone.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(3);

pub struct Engine {
    pub client: Harness,
    /// This device's id: chats the TUI creates are hosted here.
    pub device_id: String,
}

fn ipc_port() -> u16 {
    std::env::var("HARNESS_IPC_PORT")
        .ok()
        .and_then(|p| p.trim().parse().ok())
        .unwrap_or(DEFAULT_IPC_PORT)
}

/// The running engine, or `None` (standalone). `HARNESS_TUI_STANDALONE=1`
/// skips the engine even when one is running.
pub async fn connect() -> Option<Arc<Engine>> {
    if std::env::var_os("HARNESS_TUI_STANDALONE").is_some_and(|v| v != "0") {
        tracing::info!("standalone mode (HARNESS_TUI_STANDALONE)");
        return None;
    }
    let port = ipc_port();
    let client = Harness::new(format!("ws://127.0.0.1:{port}"), Origin::default());
    match tokio::time::timeout(CONNECT_TIMEOUT, client.local_device_id()).await {
        Ok(Ok(device_id)) => {
            tracing::info!(port, %device_id, "engine mode: sharing chats with Harness");
            Some(Arc::new(Engine { client, device_id }))
        }
        Ok(Err(error)) => {
            tracing::info!(port, %error, "no Harness engine; standalone mode");
            None
        }
        Err(_) => {
            tracing::info!(port, "Harness engine did not answer; standalone mode");
            None
        }
    }
}
