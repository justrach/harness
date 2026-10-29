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
- Agent rows stay visible and open their live transcript in a side tab without
  leaving the parent chat. Finished agents use their saved transcript, falling
  back to the document feed if the snapshot is unavailable.
- A native Browser side tab opens websites, localhost previews and generated
  HTML/MCP App pages. Transcript links open there, not in a separate browser.
  See [the browser's boundaries and checks](../../docs/nano-browser.md).

Also: answering the agent's questions, the message queue, the changes pane
and file explorer, project actions with their terminal dock, attachments,
dictation, pins and settings.

Not there yet: typing into the dock, split diffs, editing files,
dragging queued messages, Linux and Windows.

## Build and run

You need Zig 0.17.0 and, on macOS, Xcode or the Command Line Tools.

```sh
cd apps/nano
zig build test          # unit tests
zig build run           # build and open the window
sh scripts/bundle.sh    # release build as zig-out/Harness Nano.app
zig build snap -- scenes/narrow-panes.json /tmp/nano-snap   # draw a scene offscreen
open "zig-out/Harness Nano.app"
```

The bundler forwards Zig build arguments. When testing a local nanoui fork,
use the same override for the release app: `sh scripts/bundle.sh --fork=/path/to/nanoui`.
Otherwise it builds the dependency pinned in `build.zig.zon`.

harness-nano needs an engine. With Harness open, its engine is already
running, so harness-nano shows your chats. When nothing answers, harness-nano
starts `harness headless` itself (from `/Applications/Harness.app`,
`~/Applications/Harness.app`, or `harness` on `PATH`; `HARNESS_NANO_ENGINE_BIN`
names another), with its own environment, and writes the engine's output to
`harness-nano-engine.log` in Harness's logs folder. When harness-nano quits it
stops that engine, and only that one: an engine Harness.app, a daemon or a
terminal started is never stopped from here. If Harness.app attached to the
engine harness-nano started, it loses it when harness-nano quits. Set
`HARNESS_NANO_NO_ENGINE_START` to wait for an engine instead.

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
Harness's own SVGs (`crates/ui/assets/icons`); the interface icons are Solar
Linear by 480 Design (CC BY 4.0). File badges, explorer rows, tabs and diffs
reuse Harness's Symbols artwork and `crates/ui/src/file-icons.json` manifest,
including exact filenames, compound extensions and named folders. The app
keeps their authored colors and the GPUI dark palette; the manifest is
compiled at build time rather than parsed into memory on launch.

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

## Seeing the window without opening it

`zig build snap -- scene.json out-dir` draws the window offscreen from a
made-up scene (no window on screen, no engine) and saves a PNG for each
`snap` step. A scene gives the window's size and theme, the spaces, chats
and transcripts to show, and steps that press shortcuts, click, type and
check what's drawn (`expect`, `expectNot` fail the run). The format is at
the top of `src/snap.zig`; `scenes/` has examples.

## Checking it against the GPUI app

`python3 parity/check.py` draws every scene in `parity/scenes` in both apps
offscreen, the GPUI app through `crates/ui/examples/ui-scenes.rs` (built
once; the script never builds it) and nano through `harness-nano-snap`,
and compares them frame by frame. It writes gpui | nano | difference
images and `report.json` with unrounded per-frame differences and their mean.
Use `--max-changed 0.0005` to require every frame, including new scenes, to
stay within 0.05% changed pixels; the older per-frame budgets alone allow a
0.5-percentage-point regression and do not constrain new scenes. `--update`
records new budgets but cannot bypass an explicit ceiling.

Scenes declare the synthetic device's `dictationAvailable` capability
(default false). Both renderers use it rather than racing a probe of the
host's installed Codex; the model-picker scenes explicitly exercise the mic.
Run against the same nanoui revision as the app:
`NANOUI_FORK=/path/to/nanoui python3 parity/check.py --max-changed 0.0005`.
