# Harness MCP server

`harness mcp` serves the Model Context Protocol on stdin/stdout and proxies every
tool into the running engine's localhost IPC (`ws://127.0.0.1:$HARNESS_IPC_PORT`,
default 27654) — the same `harness_rpc` surface the headed app and `harness sync`
dial. It is a subcommand of the one `harness` binary: no Node runtime, no extra
install, a few MB resident.

Crate: `crates/mcp` (`harness-mcp`). The protocol layer is hand-rolled
(`initialize`, `ping`, `tools/list`, `tools/call`; newline-delimited JSON-RPC
2.0) — the repo already owns JSON-RPC framing for the Codex and ACP drivers and
the stdio tool-server subset is tiny, so no SDK dependency was taken.

## Identity

The engine can inject this server into a harness's MCP config with the
originating chat in the environment:

| Variable          | Meaning                                                       |
| ----------------- | ------------------------------------------------------------- |
| `HARNESS_IPC_PORT`  | Engine to proxy (default 27654).                              |
| `HARNESS_CHAT_ID`   | The chat whose agent spawned this server.                     |
| `HARNESS_DEVICE_ID` | That chat's host device.                                      |

When `HARNESS_CHAT_ID` is set, every `send_message` is prefixed with a
`[Message from Harness chat <title> (<id8>) …]` line so the receiving agent and the
human reading that transcript can tell an agent-to-agent message from a typed
one, and the server refuses to message its own chat.

### Parent links

A chat created through `create_chat` records the creating chat as its parent:
`Chat.parent_chat_id` (proto) ⇄ `parentChatId` on the registry/workspace chat
row (`Mutate createChat { parentChatId? }` → `WorkspaceHost::create_chat_with_parent`).
The default is the origin chat (`HARNESS_CHAT_ID`); an explicit `parent` argument
(id, prefix, or title) overrides it. `list_chats { parent }` returns a chat's
children, and every chat summary carries `parentChatId`. The field is additive
and serde-defaulted: rows written by older engines read as parentless, and a
dangling id (parent deleted) is tolerated rather than cascaded.

The left sidebar hides chats that have a parent: `AppState::visible_chats`
(the Sessions list, project tabs, jump slots) and the Archived section both
require `parent_chat_id == None`. Children remain addressable by id, deep
link, and every MCP tool; `list_chats { parent }` is how an orchestrator
finds them.

Nothing is injected yet: every harness still launches with an empty MCP config
(`claude/mod.rs --strict-mcp-config`, ACP `session/new mcpServers: []`, codex
`mcp_servers.*.enabled = false`). Wiring the injection per harness is the
follow-up; the env contract above is what it will set.

## Tools

Chats are referenced by full id, a unique id prefix, or an exact title.
Projects by id, path, display name, or unique path suffix. Devices by id or
name (default: the local engine's device).

| Tool               | Engine calls                                              |
| ------------------ | --------------------------------------------------------- |
| `whoami`           | `LocalDevice`, `EngineInfo`, origin chat summary          |
| `list_devices`     | `WatchDevices` snapshot                                   |
| `list_projects`    | `WatchSpaces` snapshot                                    |
| `list_harnesses`   | `ListHarnesses`                                           |
| `list_models`      | `ListModels {harness}`                                    |
| `list_chats`       | `WatchChats` + `WatchSessions` snapshots (status merged)  |
| `get_chat`         | above + `WatchDocMessages` opening frame (pending input)  |
| `create_chat`      | `Mutate createChat` (+ `renameChat`; optional first send) |
| `read_chat`        | `WatchDocMessages` opening `reset` frame, rendered        |
| `send_message`     | `QueueCommand` Run / Steer, or `QueueMessage`             |
| `wait_for_turn`    | `WatchSessions` until the chat settles                    |
| `interrupt_chat`   | `QueueCommand` Interrupt                                  |
| `respond_to_input` | `QueueCommand` RespondInput                               |
| `archive_chat`     | `Mutate setChatArchived`                                  |

Watch streams are the engine's only read surface (there is no one-shot "get
transcript" RPC); a snapshot is "subscribe, take the first item, drop" — drop
cancels server-side, exactly what the sidebar does on attach.

`send_message` mode `auto` mirrors the composer: idle → `run`; working → `steer`
when the harness steers mid-turn (claude, codex), else a queue row held for the
end of the turn; `awaitingInput` → refuses and points at `respond_to_input`.
A working row older than 45 s is treated as idle (the UI's staleness window).

`wait_for_turn` after a send is edge-triggered on the `Session` row captured
before the send: it returns on a new `last_completed_turn`, an
`awaitingInput`/`errored` stamp newer than the baseline, or a working→idle
edge. A brand-new chat has no session row until the host picks the run up, so
the wait keeps waiting in that case rather than reporting the unstarted run as
done (this was the one bug the first live run found).

## Smoke recipe

```sh
BIN=target/debug/harness
{ echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}'
  echo '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_chats","arguments":{"limit":5}}}'
  sleep 5; } | HARNESS_IPC_PORT=27655 $BIN mcp
```

`create_chat` with `"prompt": "Reply with exactly the word pong", "wait": true`
against a live daemon returns the assistant's `pong` in a few seconds; archive
the chat afterwards with `archive_chat`. Unit tests (`cargo test -p harness-mcp`)
drive the whole tool set against an in-memory stub `RpcService`.
