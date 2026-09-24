# Harness architecture

Harness is a native desktop workspace for coding agents. The Rust binary in `apps/harness` starts a GPUI interface and a local engine; `harness headless` runs the engine without a window. The SwiftUI companion in `apps/ios/Harness` displays synced workspaces and can send commands to a trusted desktop host.

## Local process

- `crates/ui` renders the desktop shell, conversation, file browser, terminal, settings, and agent controls.
- `crates/engine` owns local workspaces, session records, worktrees, queues, and device control.
- `crates/harness` contains provider adapters. Each adapter uses the provider's local CLI and credentials.
- `crates/proto` defines shared messages and models. `crates/mcp` exposes selected session tools to agents.
- `crates/sync` handles optional account sync, registry state, session logs, and the device relay.
- `crates/update` reads the release manifest and applies supported app or managed CLI updates.

The GUI and engine communicate through local IPC when they run separately. Local mode requires no account or cloud service. The current profile is chosen at engine start; stop and restart the daemon after `harness login` or `harness logout` to change between local and synced profiles.

## Sync service

The TypeScript Worker at `edge/` implements the Harness sync protocol. Its deployment source is now `../zigrepper/services/harness-edge`, using `https://edge.codegraff.com`. The worker validates Harness tokens before forwarding requests into Durable Objects. Session, chat, registry, preview, and device rooms use WebSockets for live updates; R2 stores attachments and release artifacts. The CLI and iOS app use the same endpoint. See `docs/chat2-sync.md` and `docs/registry-sync.md` for wire details.

A synced device can request files and commands from another device through the relay. Treat account access as access to the connected device's workspace files, including ignored files when that option is enabled.

## Distribution

`scripts/package-macos.sh`, `scripts/package-linux.sh`, and `scripts/package-windows.ps1` produce platform archives with the Harness icon and license notices. The root `LICENSE` covers original Harness contributions under AGPLv3 from this change onward. Upstream and bundled material retain their own notices in `THIRD_PARTY_NOTICES.md`.
