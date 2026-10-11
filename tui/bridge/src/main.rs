//! `harness-tui-bridge`: Codex app-server protocol in front, Harness adapters behind.
//!
//! The Codex TUI speaks JSON-RPC over a websocket (`--bridge ws://…` on
//! `harness-tui`). This process answers it from Harness's `Harness` trait, so
//! every agent the GUI can drive (graff, Claude Code, Codex, …) is reachable
//! from the terminal.

mod config;
mod methods;
mod models;
mod tools;
mod turn;
mod voice;
mod wire;

use std::sync::Arc;

use anyhow::Result;
use harness_engine::default_registry;
use tokio::net::TcpListener;
use tracing_subscriber::EnvFilter;

const DEFAULT_LISTEN: &str = "127.0.0.1:4500";

/// Leave the launching terminal's session. The registry snapshots the login
/// shell's PATH with an interactive shell (`-l -i -c`), which claims the
/// foreground process group of a controlling terminal; the TUI sharing that
/// terminal would then fail every read with EIO.
#[cfg(unix)]
fn detach_from_terminal() {
    // SAFETY: `setsid` takes no pointers. It fails with EPERM when we already
    // lead a process group, which only means there is nothing to detach from.
    unsafe {
        libc::setsid();
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    #[cfg(unix)]
    detach_from_terminal();
    tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .with_env_filter(
            EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| EnvFilter::new("harness_tui_bridge=info")),
        )
        .init();

    let listen = std::env::args()
        .nth(1)
        .or_else(|| std::env::var("HARNESS_TUI_LISTEN").ok())
        .unwrap_or_else(|| DEFAULT_LISTEN.to_string());
    let registry = Arc::new(default_registry());
    models::prewarm(registry.clone());
    let listener = TcpListener::bind(&listen).await?;
    tracing::info!(%listen, "harness-tui-bridge listening");

    loop {
        let (stream, peer) = listener.accept().await?;
        let registry = registry.clone();
        tokio::spawn(async move {
            if let Err(err) = wire::serve(stream, registry).await {
                tracing::warn!(%peer, %err, "connection ended");
            }
        });
    }
}
