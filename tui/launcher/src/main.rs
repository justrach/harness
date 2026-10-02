//! `harness-tui`: Codex's terminal UI, pointed at the Harness bridge.
//!
//! Upstream `codex-tui` only takes a remote endpoint from the full `codex` CLI,
//! which links Codex's whole agent runtime. This binary depends on the TUI
//! crate alone and hands it the bridge address directly.

// The release build computes the layout of Codex's deeply nested app-server futures,
// which overflows the default query depth on Linux; Codex's own binaries raise it too.
#![recursion_limit = "256"]

use std::io::Write;
use std::path::PathBuf;

use clap::Parser;
use codex_arg0::Arg0DispatchPaths;
use codex_arg0::arg0_dispatch_or_else;
use codex_config::LoaderOverrides;
use codex_tui::Cli;
use codex_tui::ExitReason;
use codex_tui::resolve_remote_addr;
use codex_tui::run_main;
use codex_utils_cli::CliConfigOverrides;
use supports_color::Stream;

mod theme;

/// Where `harness-tui-bridge` listens unless told otherwise.
const DEFAULT_BRIDGE: &str = "ws://127.0.0.1:4500";

#[derive(Parser, Debug)]
struct TopCli {
    /// Bridge to connect to: `ws://host:port` or `unix://PATH`.
    #[arg(long, env = "HARNESS_TUI_BRIDGE", default_value = DEFAULT_BRIDGE)]
    bridge: String,

    #[clap(flatten)]
    config_overrides: CliConfigOverrides,

    #[clap(flatten)]
    inner: Cli,
}

fn main() -> anyhow::Result<()> {
    codex_build_info::initialize!();
    arg0_dispatch_or_else(|arg0_paths: Arg0DispatchPaths| async move {
        let top_cli = TopCli::parse();
        let endpoint = resolve_remote_addr(&top_cli.bridge)
            .map_err(|err| anyhow::anyhow!("invalid --bridge address: {err}"))?;
        let mut inner = top_cli.inner;
        inner
            .config_overrides
            .raw_overrides
            .splice(0..0, top_cli.config_overrides.raw_overrides);
        // Codegraff colors for the run; the guard puts the terminal's own back.
        let codex_home = std::env::var_os("CODEX_HOME").map(PathBuf::from);
        let mut theme = theme::apply(codex_home.as_deref());
        let exit_info = run_main(
            inner,
            arg0_paths,
            LoaderOverrides::default(),
            Some(endpoint),
        )
        .await;
        if let Some(theme) = theme.as_mut() {
            theme.restore();
        }
        let exit_info = exit_info?;
        let is_fatal = match &exit_info.exit_reason {
            ExitReason::Fatal(message) => {
                eprintln!("ERROR: {message}");
                true
            }
            ExitReason::UserRequested
            | ExitReason::Archived(_)
            | ExitReason::TurnInterrupted
            | ExitReason::ThreadRemoved => false,
        };

        let color_enabled = supports_color::on(Stream::Stdout).is_some();
        for line in exit_info.format_exit_messages(color_enabled) {
            println!("{line}");
        }
        if is_fatal {
            std::io::stdout().flush()?;
            std::process::exit(1);
        }
        Ok(())
    })
}
