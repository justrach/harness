# harness-nano

Harness's desktop app on [nanoui](https://github.com/justrach/nanoui), in Zig.

It's a new window over the same engine the GPUI app runs. The engine (the
Harness daemon, or `harness headless`) keeps the workspaces, sessions and
agents; harness-nano talks to it over the engine's local WebSocket RPC
(`crates/rpc`). Both apps can be open on one engine at once.

HTTPS goes through [http-zig](https://github.com/justrach/http-zig), the HTTP/2
client codegraff uses. For now it fetches the newest release's manifest.

## What it does

- Sidebar: your spaces and their chats, newest first, with each chat's status
  (working, waiting for you, errored). **Add folder** adds a space on this
  device.
- Chat: the transcript as it streams in, with Markdown replies (code
  highlighted, with a Copy button), reasoning, and each tool call with how it
  went.
- Composer: Return sends, Shift-Return starts a new line, **Stop** interrupts a
  running turn. A new chat picks its agent and model.

Also: answering the agent's questions, the message queue, the changes pane
and file explorer, and project actions with their terminal dock.

Not there yet: typing into the dock, split diffs, editing files, per-type file
icons, dragging queued messages, attachments and dictation, pins, settings,
starting an engine when none is running, Linux and Windows.

## Build and run

You need Zig 0.17.0 and, on macOS, Xcode or the Command Line Tools.

```sh
cd apps/nano
zig build test          # unit tests
zig build run           # build and open the window
sh scripts/bundle.sh    # release build as zig-out/Harness Nano.app
open "zig-out/Harness Nano.app"
```

An engine has to be running. With Harness open, its daemon already is, so
harness-nano shows your chats. Otherwise start one with `harness headless`.

harness-nano connects to `127.0.0.1:27664`. Set `HARNESS_IPC_PORT` to use
another engine.

## Trying it against a throwaway engine

To keep your own chats out of it, run a second engine with its own port, data
and home:

```sh
dir=$(mktemp -d)
HARNESS_IPC_PORT=27990 HARNESS_DATA_DIR="$dir/data" HOME="$dir/home" \
  /Applications/Harness.app/Contents/MacOS/harness headless &
HARNESS_IPC_PORT=27990 HARNESS_NANO_HARNESS=mock zig build run
```

`HARNESS_NANO_HARNESS` sets the agent new chats start with. The engine's
`mock` agent replies without a model or an account.

nanoui's flags render the window offscreen, with no window on screen, for
checks and screenshots:

```sh
HARNESS_IPC_PORT=27990 zig-out/bin/harness-nano --nanoui-snapshot=/tmp/nano.png \
  --nanoui-wait=3 --nanoui-script="click:Do anything…;type:Hello;key:enter;live:8"
```

To open a chat at launch (for those checks), set `HARNESS_NANO_OPEN_CHAT` to
its id.

## Tests that it matches the Rust desktop

`protocol/desktop/` holds what the Rust desktop and this app must agree on, as data: the sidebar's rules (times,
status marks, order), tool chips and group summaries, how transcript frames apply, the theme's roles, and every
request this app sends the engine. Both sides run the same files (`src/parity.zig` here; `crates/*/tests/desktop_*`
in Rust), and the Rust runner sends each request to a real engine. See `protocol/desktop/README.md`.

After changing a request on purpose: `zig build vectors`, then `cargo test -p harness-engine --test desktop_requests`.

## Matching the desktop app

Sizes, spacing, colours and rules come from the GPUI source and are checked
side by side against the real app on the same throwaway engine: the title
bar's buttons, the tab list, the project filter, session rows (status mark,
agent mark, project monogram, fading title, relative time), the header's
"project @ device", the transcript column (736 points), folded tool groups
("Ran 2 commands"), and the composer pill with its model chip. The icons are
Harness's own (`crates/ui/assets/icons`), rendered to PNG in `src/icons`;
the interface icons are Solar Linear by 480 Design (CC BY 4.0).

## Layout

| File | |
|---|---|
| `src/ws.zig` | WebSocket client for the engine's socket. It sends no `Origin` header, which the engine refuses. |
| `src/rpc.zig` | The RPC frames: calls, replies, streams, cancel. |
| `src/engine.zig` | The connection: a reader thread, messages handed to the UI thread, reconnecting every 2 s. |
| `src/workspace.zig` | Spaces, chats, sessions, agents and models, each list replaced whole. |
| `src/transcript.zig` | A chat's transcript: resets and deltas, checked as `apply_transcript_frame` checks them. |
| `src/app.zig` | The state, and the calls the GPUI app makes to open a chat, create one and send. |
| `src/view*.zig`, `src/theme.zig` | The window: title bar, sidebar, transcript, composer, new-chat canvas, menus and pickers, in Harness's Codegraff Light and Dark roles. |
| `src/tabs.zig`, `src/rules.zig`, `src/tools.zig` | Tabs; relative times, project monograms and reasoning labels; how tool calls fold and what their groups say. |
| `src/icons.zig`, `src/icons/` | Harness's icons and agent marks, tinted as drawn. |
| `src/markdown.zig`, `markdown_html.zig`, `highlight.zig` | nanoterm's Markdown parser and code highlighting, unchanged. |
| `src/release.zig` | The newest release, over HTTP/2. |

## Recorded agent edit chart

The chat's live tail now includes a compact native activity chart. The green
and red stepped envelopes are **cumulative recorded tool-result additions and
removals**; dots show their difference. These are editing churn, not the final
working-tree patch. Repeated edits to the same lines count repeatedly.

Hover the chart to inspect a result; click to pin its detail. **Details** (or
**Alt+D**) opens the detail pane, **Previous/Next** or **Alt+[ / Alt+]** steps
through results. File lanes mark recorded result positions, not editing
durations. Navigation resets when changing chats. There is no chart animation,
so reduced-motion users receive the same information without motion.

Data is from the selected chat's `WatchDocMessages` transcript: resolved,
successful tool `diffStats` (the engine's persisted line counts), with legacy
inline `diff.oldText/newText` excerpts when present. New-file counts can also
be counted directly from their recorded text. Other absent counts stay
unknown. Failed/pending tools are not counted. Sidecar-only/binary/legacy text
has an explicit unavailable preview; missing history/counts are marked partial.

**Protocol limitation:** this branch records `createdAt` per message, not
per tool. The x-axis is therefore **recorded edit order**, not a fabricated time
axis. Detail labels the real message timestamp as **turn started**, in SGT,
not as an edit timestamp. Parallel tools are shown in transcript order; the
chart does not claim their execution/completion chronology. No durations or
activity spans are inferred from final git totals or wall-clock observation.
Precise timed playback requires an additive engine/protocol timestamp contract.

### Offline native visual fixture

This separate executable never starts or connects to an engine. Its embedded
sample transcript and visible badge explicitly say **DEMO FIXTURE — NOT ACCOUNT
DATA**. It is not installed by the normal production build.

```sh
zig build chart-fixture
zig-out/bin/harness-chart-fixture                 # interactive native window
zig-out/bin/harness-chart-fixture --nanoui-snapshot=/tmp/chart-dark.png
HARNESS_CHART_LIGHT=1 zig-out/bin/harness-chart-fixture \
  --nanoui-snapshot=/tmp/chart-detail-light.png --nanoui-script='click:Details'
```

Snapshots use nanoui's actual offscreen native renderer, not a web recreation.
They verify fixture layout only, not a live engine editing session. Production
still launches with `zig build run` against the normal engine. Unit regressions
cover cumulative churn, distinct files, replay/reset, missing/empty history,
out-of-order turn timestamps, failed/pending tools, new files and binary-style
sidecar results (`zig build test`).
