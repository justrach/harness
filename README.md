# Zeron

Control your coding agents (Claude Code, Codex, Cursor, Grok, Hermes, Pi) locally by default, with optional multi-device sync.

![Zeron driving a Claude Code session with a live branch diff sidebar](apps/landing/public/assets/app-screenshot.jpg)

Every device runs a small engine that stores sessions on that device. A new installation starts in local-only mode without an account or a network connection.

## Install and run locally (Linux)

```bash
curl -fsSL https://comet.zeron.sh/install.sh | sh
comet status
```

The installer starts the daemon immediately and keeps it running across reboots. No sign-in or sync configuration is required.

Day-to-day:

```bash
comet status      # local/synced mode and engine status
comet update      # update to the latest release
comet daemon start|stop|restart|status
```

## Optional multi-device sync

Sign in only when you want to open your account's synced workspace. Authentication changes the profile selected by the next engine start, so stop the daemon before changing it:

```bash
comet daemon stop
comet login
comet daemon start
```

You can then start an agent on one synced device and follow or drive it from another. An always-on machine such as a VPS can keep those agents working after you close your laptop.

Signing in does not upload, move, or import existing local sessions. Local sessions and their attachments remain under the local profile and reappear when you return to local-only mode:

```bash
comet daemon stop
comet logout
comet daemon start
```

`comet login` and `comet logout` refuse to modify credentials while an engine owns the data directory. The desktop app follows the same next-restart profile boundary.

On macOS: use the desktop release, or build `comet` from source and run `comet daemon install` to install the launchd service.

---

Developing or curious how it works? [![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/zeronsh/comet) or check out [ARCHITECTURE.md](ARCHITECTURE.md).

Licensed under the [MIT License](LICENSE).
