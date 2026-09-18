Native GPUI screenshots from the isolated `sidebar-fixture` example. All projects,
chats, icons and PR metadata are synthetic; no engine or account is connected.

```sh
cargo run -p zeron-ui --example sidebar-fixture --features project-palette-fixture
ZERON_SIDEBAR_COMPACT=1 cargo run -p zeron-ui --example sidebar-fixture --features project-palette-fixture
```

Set `ZERON_SIDEBAR_HIDE_LABEL=1` to start with the project/device label hidden.
The sidebar view menu persists all three display preferences and project grouping.
Ungrouped rows live in a collapsible Sessions accordion; project/device groups
remain separate accordions. All sidebar accordion headers have no divider rules.
Archived sessions share active-session metadata and layout preferences, with muted
project/harness artwork and an Unarchive action in the same hover slot.

Repository artwork follows [Conductor's documented filename priority](https://www.conductor.build/docs/faq#where-does-conductor-get-the-repo-icon).
The first existing file wins; missing or invalid artwork uses the project initial on a neutral, translucent
frosted background using the composer’s backdrop-blur helper. A stable hash of the project path chooses the shade; theme ink keeps
it readable on glass in light and dark themes. Local reads and bounded image decoding run off the UI thread. Remote
projects use the owning device's workspace file RPC, including ICO support.
Artwork is shared across a project's rows, refreshed after five minutes, and
released from the image atlas when its cache entry expires. Raster thumbnails
are bounded to 64 pixels; SVGs retain their original colors.

Native X11 checks cover compact and detailed rows, independently hidden labels,
project icons and fallback icons, project groups, borderless accordions, hover controls, and dragging
pinned sessions. Compact rows place status on the left, followed by harness and project icons,
the name, remote/archive control, PR badge, and elapsed time on the right. Hover
replaces the remote icon with Archive (or reveals it for local sessions), keeping
status, PR, and time visible. Local rows reserve no empty action slot at rest,
so the title uses that space until Archive appears on hover. Compact Archive and
Unarchive are background-free, with the same 13px size as the remote icon.
The moving card follows the pointer continuously and neighbors animate around
its destination. Clicking Pinned was checked against the filter button's pixels
both during mouse-down and immediately after mouse-up; its border remains unchanged.

Headless regression checks exercise pin/unpin, pin reordering, cancellation,
remote pin conflicts, actual row-height hit testing, small pointer movements,
project grouping/keyboard order, icon lookup priority, SVG/ICO decoding, and
settings persistence. Native macOS and Windows interactions were not exercised.

Validation: `cargo test -p zeron-ui --lib -- --test-threads=1` passed all 1,119
tests. The native fixture build, formatting checks, and `git diff --check` passed.

Latest icon/order follow-up: all 40 sidebar regression tests passed; native screenshots
were refreshed with the server-square remote icon and harness-first ordering.
