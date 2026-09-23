# Harness

A native desktop GUI for the coding agents already on your machine — Claude Code, Codex, Cursor, Devin, Grok, Hermes, graff, Pi, OpenCode, and Antigravity. Local by default. Optional multi-device sync when you want it.

*English | [简体中文](README.zh-CN.md)*

The app is **Harness** (`harness.codegraff.app`). The CLI binary is `harness`. `HARNESS_*` env vars win; `ZERON_*` still works. One binary covers headed GUI and a headless engine.

New installs open on the **Codegraff** theme (Warm Graphite — cream and amber light, near-black and gold dark). Settings → Appearance still has Harness, the VS Code catalog, and VS Code import.

## Run from source

Needs the Rust toolchain in `rust-toolchain.toml` (currently 1.97.1).

### macOS

```bash
./scripts/run-macos-dev.sh
```

That builds `harness`, stages `target/macos-dev/Harness.app`, and opens it through Launch Services so TCC stays on the app instead of the terminal. Dev data lives under `target/macos-dev/data` (override with `HARNESS_DEV_DATA_DIR`); IPC defaults to port `49777`. Quit the app before rebuilding.

Offline look-and-feel with seeded sessions:

```bash
./scripts/dev-demo.sh
```

### Linux

```bash
cargo build -p harness
./target/debug/harness
```

Release-style local install still uses the daemon:

```bash
harness status
harness daemon start|stop|restart|status
harness update
```

The sidebar browser needs the [Linux browser runtime](docs/reference/linux-browser.md).

### Windows

Extract a portable ZIP and run `harness.exe`, keeping `harness-update.json` beside it for in-app updates. Source builds: [Windows development](docs/reference/windows-development.md).

```powershell
cargo run --locked -p harness
```

## How it works

Every device runs a small engine that stores sessions on that device. A new install starts local-only — no account, no network.

- **Headed** (`harness`): opens the GUI. If a daemon is already on the IPC port, it attaches; otherwise it runs the engine in-process and serves that same engine for other viewports.
- **Headless** (`harness headless`): engine only. A VPS can keep agents running after you close the laptop.
- **Agents** are discovered on `PATH` (plus a documented `*_EXECUTABLE` override). Settings → Agents says so. A new harness is an adapter, not a fork of the GUI.

See [ARCHITECTURE.md](ARCHITECTURE.md) and [docs/theme-system.md](docs/theme-system.md).

## Optional multi-device sync

Sign in only when you want the account's synced workspace. Authentication changes the profile the *next* engine start will use, so stop the daemon first:

```bash
harness daemon stop
harness login
harness daemon start
```

You can start an agent on one synced device and follow or drive it from another.

Devices signed in to the same synced account are trusted with remote workspace access. A device controlling a workspace on another device can list, read, and write its files; enabling `Show ignored files` also makes gitignored files such as `.env` available remotely. `.git` is always excluded. Only sign in devices you trust with the full contents of your workspaces.

Signing in does not upload, move, or import existing local sessions. They stay under the local profile and come back when you return to local-only mode:

```bash
harness daemon stop
harness logout
harness daemon start
```

`harness login` and `harness logout` refuse to change credentials while an engine owns the data directory. The desktop app uses the same next-restart boundary.

On macOS, use the desktop release or build `harness` and run `harness daemon install` for launchd.

## License

[MIT](LICENSE). Taken from [Zeron](https://github.com/zeronsh/zeron) (Wing).
