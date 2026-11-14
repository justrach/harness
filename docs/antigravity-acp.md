# Antigravity over ACP

Harness uses Antigravity's native `agy acp` entry point when the `agy` CLI is installed. The existing Antigravity agent identity, chats, model picker, sign-in and permission handling are retained; this is not a second provider.

## Setup and resolution

1. Install or update the Antigravity CLI using its original installation method.
2. Confirm `agy acp --help` works. Native ACP was verified with CLI 1.5.7; older CLIs without this subcommand need updating.
3. Enable Antigravity in Settings → Agents, then use Sign in if required.

Explicit `ANTIGRAVITY_ACP_EXECUTABLE` overrides take precedence. Point it to the executable, not a command string. Native executables named `agy` / `agy.exe` receive the `acp` subcommand. Custom legacy ACP servers receive the existing server arguments. Without an override, native `agy` takes precedence over a legacy `agy_acp_server` on PATH or a previously installed managed archive. Detection does not log in, start a session, or download an adapter.

Settings' Install action remains available for the pinned legacy ACP archive on supported platforms. Existing legacy installations and custom server overrides continue working. Harness does not automatically install a replacement CLI or enable permission-skipping flags.

## Update checklist

- Resolve the exact executable used by sessions before checking its version.
- Native `agy` / `agy.exe`: read `--version`; run that same executable with `update` only after an explicit update request.
- Do not invent `update --check` or `--yes`: the verified CLI does not document them. Without a non-mutating latest-version query, distinguish a check-and-update action from a confirmed available update.
- Legacy or custom ACP servers: show manual instructions; never send `update` to an arbitrary server or update its containing Homebrew package by inference.
- Keep active-run scheduling, cancellation and post-update version verification in the shared updater pipeline.

## Verification

Synthetic ACP fixtures exercise native discovery and a complete turn through `agy acp`, explicit overrides, native-before-legacy precedence, legacy server arguments and missing/partial installations. The native `initialize` handshake was also checked with a disposable home, telemetry disabled, no account credentials and no provider prompt. It advertised ACP version 1 and `oauth-personal` among its authentication methods. This does not constitute a signed-in live-model turn or physical Windows execution.
