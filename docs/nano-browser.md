# Nano's Browser pane

Nano keeps its native UI. A Browser side tab embeds the system WKWebView on
macOS; it does not put the app itself in a webview. The sidebar, transcript,
composer and browser controls still use Harness's original SVGs and native
layout.

Open the right pane, press **+**, then choose **Browser**. Enter a website
or a local address such as `localhost:3000`; bare loopback addresses use HTTP,
other bare hosts use HTTPS. Back, Forward, Reload and Copy address are in the
native toolbar. Each Browser tab belongs to its conversation. Switching away
or closing the pane hides its native view; closing the tab destroys it at a
safe frame boundary.

Click a Markdown HTTP(S) link to open a new Browser tab in that conversation.
Links in a subagent or a Markdown file preview keep the containing chat as
their owner. Link destinations appear on hover. A queued activation is
abandoned if the selected conversation changes before the next frame.
Privileged schemes, malformed URLs and embedded credentials are rejected;
they never fall through to a system-browser launch.

A tool's generated-page chip opens its saved HTML or MCP App in the pane.
These are host-local: an unknown or different host is not guessed. Only a
validated kind and 32-character lowercase hexadecimal ID can locate a page,
under `.graff/views` or `.graff/mcp-apps` in the host's home directory. The
reader refuses symlinks and non-regular files and bounds the body to 16 MiB.
The `graff-view` scheme supplies Harness's existing Content Security Policy:
inline scripts/styles, no network or forms, sandboxed origin, and only the
MCP App kind's inline data frames. These tabs cannot navigate to websites or
arbitrary files.

Ordinary websites have no nanoui IPC bridge, injected app scripts, or engine
handles. WebKit is allocated only when a nonempty Browser tab is actually
shown; the normal native app's startup does not create browser processes.
Browser navigation is event driven, not polled.

## Checks

From `apps/nano`, using the same local nanoui dependency as the release app:

```sh
../../scripts/heavy-build.sh zig build test --fork=/path/to/nanoui
```

`tests_ui_surfaces.zig` drives the native controls, transcript links and agent
side tabs using synthetic data. `tests_browser_native.zig` exercises real,
hidden WebKit against a generated page in a temporary home and an ephemeral
localhost HTTP server. Tests use a nonpersistent website data store and never
consult a person's saved pages, browser history, accounts or engine.
