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

Direct peer messages are for actionable questions, blockers, and final requested
results—not acknowledgements or progress updates. The header explicitly says no
reply is needed otherwise. Use an unmentioned room post for progress; it wakes
nobody. The server refuses another send to the same recipient while a message
from that sender remains queued, preserving the earlier message and any pending
human approval. This preflight is not a cross-process atomic queue reservation.
New peer envelopes carry a relay depth: a chain stops after four deliveries;
a new human request resets it. Legacy peer headers count as the first delivery.
These are coordination safeguards, not authentication of text supplied by users.

Archived chats are out of the active collaboration set. `list_chats` leaves
them out unless `include_archived` is set, and a `send_message` from a chat to
an archived chat fails with an archived error: nothing is sent and the chat
stays archived. The engine enforces the same rule for every peer delivery (a
`send_message` envelope or a room delivery), both when the message is accepted
and again when it would start a turn, so mail queued before the archive waits
in the queue until a person restores the chat. Room wakes for an archived chat
are dropped. A person's own prompt still restores the chat (#345, #498).

A turn fed only by peer mail completes without a completion sound, banner or
phone notification: its `Session.lastCompletedPeerOnly` is set. A person's
prompt or steer anywhere in the turn makes it an ordinary completion (#499).

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
| `dismiss_input`    | `QueueCommand` DismissInput (never an answer or approval) |
| `archive_chat`     | `Mutate setChatArchived`                                  |
| `list_bots`        | `graff bot list`, `routine list`, `due` in the project    |
| `run_bot`          | `graff bot prompt`, then `create_chat` with a first send  |
| `run_due_bots`     | `graff bot due --claim`, then one `create_chat` per row   |

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

External clients may wait up to 3600 s. When the server speaks for a chat
(`HARNESS_CHAT_ID` set), waits instead return one status snapshot immediately:
recipient work never parks the caller's conversation behind a silent tool call.
A still-running or not-yet-started recipient returns `timedOut` with a `note`
telling the caller to end its turn; the recipient's reply arrives asynchronously.
Explicit `wait_for_turn` snapshots return only the newest assistant message,
not the entire historical transcript.

`dismiss_input` requires a host supporting `dismiss-input-v1`. It cancels the
turn that still owns the specified question and pauses automatic queue delivery.
A stale request cannot stop a newer turn; an orphaned question is resolved
without starting a replacement turn. Dismissal never supplies answer labels.

### Bots

A graff Bot is a standing role kept in a project's `.graff/bots/<name>/`: one
job, a memory file, a work log and scheduled routines. graff owns that store
and the wording of every prompt; the three tools read both through
`graff bot … --json`, so nothing about a bot is kept in the engine.

A run is an ordinary graff chat in the bot's project, titled with the bot's
name (and the routine id). Its first message is the bot's standing text from
`graff bot prompt` followed by the task, so the run's approvals, steering and
result are where its owner already looks. In a chat the bot edits its memory
file and adds its own log line with `graff bot log`.

- The project defaults to the calling chat's. It must be hosted on this
  device: bots are files in the project folder.
- `run_bot` with `routine` runs it now and leaves its schedule alone.
  `run_due_bots` claims first (`--claim` moves each due routine to its next
  slot), so two callers do not start the same run; a chat that fails to start
  after the claim is listed under `failed`.
- Nothing calls `run_due_bots` on a timer. A routine runs when a chat calls it,
  or when the user runs `graff bot tick` from cron or launchd.
- A bot's `model` is a graff model name. One this device does not offer is
  dropped and returned as `modelIgnored`.
- A graff from before bots reads `bot list` as a prompt, so the server checks
  `graff --help` for the command first and refuses with "update graff".
- With no `project`, `list_bots` also returns the person's own bots as `yours`
  (the engine's `BotsState`), and `run_bot` for one of those names goes to the
  engine's `RunBot`, which puts the turn into that bot's standing chat. A named
  project always means that project's bot. See `docs/bots.md`.

## Graff delegated-context diagnostics

Graff's `run_task` accepts explicit reference `context`; Harness does not inherit
or replay the parent transcript, rewrite that argument, or select another
provider/account. The configured agent owns the MCP tool schema and execution.

When graff forwards `_meta["codegraff/runTask"]` on a completed ACP tool update,
Harness shows supplied/used **UTF-8 bytes** and whether the reference was
summarized. These are not token counts or the parent conversation's occupancy.
Only bounded diagnostic fields are synchronized, never the caller context or
task answer. Repeated completion metadata updates the same diagnostic row.

The print-mode runner currently exposes no per-task usage or settled charge.
Harness displays that unavailability and its reason, not a zero-dollar charge
or a list-rate estimate. Diagnostics never add to account totals; the selected
provider's account usage remains authoritative. Older graff versions that do
not forward the metadata simply omit the diagnostic row. This change does not
fix graff's shell-wait behavior.

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
