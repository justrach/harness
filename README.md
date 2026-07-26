# comet-native

A native rewrite of [comet](https://github.com/wingleeio/comet) — a multi-device controller for
coding agents (Claude Code / Codex) — in Rust with a [gpui](https://gpui.rs) UI.

Each device runs an **engine** that executes agents and syncs state as **Loro CRDT docs** through
**Cloudflare Durable Objects** (per-chat session rooms + per-device relay rooms). The gpui app is
a thin viewport over its local engine; a UI on one device can drive an agent on another through
the device-room relay. One binary: headed by default, `comet headless` for VPS/remote devices.
A second binary, `comet-tui`, is a [ratatui](https://ratatui.rs) viewport over the same RPC —
it never embeds an engine, so closing the terminal detaches instead of stopping work. Run it with
no arguments and it attaches to whatever is already there: a running desktop app (which serves its
embedded engine on the IPC port), a headless daemon, or one it starts itself.

```
gpui UI  ─┐
          ├ in-proc/localhost RPC ─ engine A ══ DeviceRoom DO relay ══ engine B
comet-tui ┘         │              (edge Worker: auth, rooms, R2)       │
                    └── Loro sync ── SessionRoom DO (per chat) ─────────┘
```

No Orbit, no Postgres, no Electron, no WebRTC — see [ARCHITECTURE.md](ARCHITECTURE.md).

## Status

M0–M6 landed: local + multi-device chat (doc-queued commands, host execution, CRDT sync
proven live by the e2e smoke), WorkOS or dev auth, terminals, diff pane, repos/worktrees,
agent accounts, Claude + Codex harnesses, Linux packaging. Honest per-feature ledger:
[docs/PARITY.md](docs/PARITY.md); milestone detail: [ARCHITECTURE.md §8](ARCHITECTURE.md).

## Layout

```
crates/
  proto/     wire types (AgentEvent, ToolCall, entities, AuthState)
  doc/       session/workspace doc schemas, mirror layer, command ledger
  sync/      loro room client + local snapshot store
  harness/   Claude Code (stream-json) / Codex (app-server) adapters + mock
  engine/    the headless backend (sessions, doc host, auth, terminals,
             repos/diffs, uploads, agent accounts, device-room host)
  rpc/       UiRpc/ControlRpc transports + device-room virtual sockets
             (examples: e2e_driver, rpc_probe)
  ui/        the gpui app
  tui/       the ratatui app (detachable; no gpui dependency)
apps/comet/  the binary (headed by default; `comet headless`)
apps/tui/    the `comet-tui` binary
edge/        TypeScript Cloudflare Worker + Durable Objects
dist/        packaging assets (.desktop, icon, macOS Info.plist template)
scripts/     e2e-smoke.sh, tui-smoke.py, tui-screenshots.py, package-linux.sh
docs/        PARITY.md + research notes
```

## Build & test

```bash
cargo build --workspace       # Linux: needs the gpui deps (see docs/research/gpui.md)
cargo test  --workspace
cargo clippy --workspace --all-targets && cargo fmt --all --check
cd edge && npm install && npm run dev   # wrangler dev on :27640 (dev auth: bearer = user@org)
```

**macOS**: `xcode-select --install` (gpui needs the Metal toolchain; full Xcode 15+ if the
shader compile complains) + rustup, then `cargo run -p comet`. Heads-up: this workspace has
only ever been compiled on Linux — the `#[cfg(target_os = "macos")]` paths (Keychain access
in agent accounts) parse but have never been type-checked against the Apple SDK, so the
first macOS build may surface errors there; they're isolated to `crates/engine/src/
agent_accounts.rs` and safe to stub if needed. Window chrome (traffic-light inset,
vibrancy) is untested on real macOS — see dist/README.md for bundling.

## Install (headless, Linux)

```bash
curl -fsSL https://comet.zeron.sh/install.sh | sh
```

Installs the self-contained binary to `~/.comet-native/app`, links `comet` into
`~/.local/bin`, and sets up a systemd user service. The terminal viewport ships
in that same binary as `comet tui` (see below). Production endpoints
(`https://edge.comet.zeron.sh` + WorkOS auth) are baked in — no configuration
needed. Sign in with `comet login` (paste-code flow), then
`systemctl --user start comet-native`.

## Auth & daemon CLI

Authentication is decoupled from the long-running engine: `comet login` runs the
paste-code sign-in + workspace onboarding, persists `~/.comet-native/session.json`
(0600), and exits. A service-managed `comet headless` loads that session — off a
TTY it exits with "run `comet login` first" instead of waiting on a prompt.

```bash
comet login       # sign in, persist the session, exit
comet logout      # remove the saved session
comet status      # auth + engine liveness; exits nonzero when sign-in is needed

comet daemon install    # install + enable + start (launchd on macOS, systemd --user on Linux)
comet daemon start|stop|restart|status|uninstall
```

`comet daemon install` captures the current `COMET_*` env (and `PATH`, for the
harness CLIs) into the unit, and manages the same `comet-native.service` the
installer creates on Linux. While an engine is running it owns the session
(refresh tokens rotate), so `login`/`logout` refuse until it is stopped.

## Run (from source)

```bash
# Headed (connects to a running daemon on COMET_IPC_PORT, else embeds the engine):
cargo run -p comet

# Headless engine — zero config: production edge + WorkOS sign-in by default:
cargo run -p comet -- headless

# Headless against a local wrangler dev edge (dev-mode auth):
COMET_EDGE_URL=http://localhost:27640 \
COMET_EDGE_TOKEN=alice@org1 \
COMET_ORG_ID=org1 \
cargo run -p comet -- headless
```

## Terminal UI

A ratatui terminal viewport, shipped as a subcommand of the same binary:

```bash
comet tui        # attaches to whatever engine is running, or starts one

# From source — a standalone dev binary with no gpui dependency, so it builds in
# seconds. Same run path as `comet tui`:
cargo run --bin comet-tui
```

(From source, `-p comet-tui` selects the *library* in `crates/tui` and fails with
"a bin target must be available"; the dev binary's package is `comet-tui-bin`. The
shipped command is `comet tui`.)

`comet tui` never embeds an engine — it needs a `comet` engine to attach to or to
spawn, which is exactly why it lives in the `comet` binary: the engine is always
right there. It probes `COMET_IPC_PORT` and attaches to whatever answers — a
`comet headless` daemon, or a running desktop app, which serves its embedded engine
on that port for exactly this reason. Nothing needs to be launched in a particular
order. If nothing is listening it starts `comet headless` in its own session
(`setsid`, stdio to `~/.comet-native/daemon.log`) and attaches to that. So quitting
is **detaching** — agents keep running, docs keep syncing, and the DeviceRoom stays
joined. Closing the terminal (SIGHUP) does the same thing, because the engine has no
controlling terminal to lose. Reattach by running it again; it prints how, on the way out.

```
q, Ctrl-C  detach          Tab  cycle panes       Ctrl-B  sidebar
Enter      open / send     i    prompt            Alt-Enter  newline
j/k, g/G   move / scroll   n    new session       Ctrl-X  interrupt
e / A      archive / show archived                ?  all bindings
```

Information architecture is comet-native's, read from the desktop shell
(`render_chat_sidebar`, `shell/spaces.rs`, `shell/tabs.rs`) rather than from the
original Electron app: the sidebar has **two sections** — Spaces, then a *flat
global* attention-ordered Sessions list — and the selected space's own sessions
are the **tab strip** above the transcript, which is also the header. The visual
language follows herdr: no boxes, one vertical divider, one rule, section label
left with its affordance right, and a lot of air. Colors are comet's exact oklch
(indigo reserved for focus, pink for running, emerald for finished-but-unseen);
the derivations both viewports share live in `comet_proto::view`.

Flags: `--port`, `--data-dir`, `--comet-bin`, `--no-spawn` (attach only — for a
service-managed engine), `--no-mouse` (keeps drag-to-select), `--fps N` (redraw
ceiling, default 60), `--probe` (report whether an engine is up, exit nonzero if
not). Honors `NO_COLOR`. Logs go to `{data_dir}/tui.log`, never to the screen.

End-to-end check (spawns a throwaway daemon on a scratch data dir, drives the real
binary through a pty, and verifies the engine survives the viewport exiting):

```bash
cargo build -p comet -p comet-tui-bin && python3 scripts/tui-smoke.py
```

Setting `COMET_EDGE_TOKEN` (the dev-mode bearer, `user@org`) — or
`COMET_WORKOS_CLIENT_ID=""` — switches auth to dev mode; `COMET_EDGE_URL`
overrides the baked production edge. Other knobs: `COMET_HARNESS`
(`claude-code` default | `codex` | `mock`) picks the default harness for chats
without a config row; `COMET_WORKOS_CLIENT_ID` overrides the baked client id;
`COMET_CALLBACK_PORT` moves the headed sign-in loopback (default 27641);
`COMET_DEVICE_NAME` overrides the registry hostname.

## Two-device e2e smoke

```bash
scripts/e2e-smoke.sh
```

Starts (or reuses) the edge under `wrangler dev`, boots two headless engines as the same
user on different devices, then drives both IPCs (`crates/rpc/examples/e2e_driver.rs`):
create a chat hosted on device A → queue a run **from device B through the doc command
queue** → the durable nudge wakes A → A executes via the mock harness → the transcript
and session status sync A → edge → B. Prints `PASS`/`FAIL` per step, exits nonzero on
failure, cleans up its processes and temp dirs.

## Packaging

```bash
scripts/package-linux.sh      # tar.gz with binary + .desktop + icon (release, thin LTO, stripped)
```

macOS: config + documented steps only for now — see [dist/README.md](dist/README.md).
