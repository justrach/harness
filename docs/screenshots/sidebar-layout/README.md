Native GPUI screenshots from the isolated `sidebar-fixture` example. All projects,
chats, icons and PR metadata are synthetic; no engine or account is connected.

```sh
cargo run -p zeron-ui --example sidebar-fixture --features project-palette-fixture
ZERON_SIDEBAR_COMPACT=1 cargo run -p zeron-ui --example sidebar-fixture --features project-palette-fixture
```

Set `ZERON_SIDEBAR_HIDE_LABEL=1` to start with the project/device label hidden.
The sidebar view menu persists all three display preferences and project grouping.

Repository artwork follows [Conductor's documented filename priority](https://www.conductor.build/docs/faq#where-does-conductor-get-the-repo-icon).
The first existing file wins; missing or invalid artwork uses the supplied code
icon. Local reads and bounded image decoding run off the UI thread. Remote
projects use the owning device's workspace file RPC, including ICO support.
Artwork is shared across a project's rows, refreshed after five minutes, and
released from the image atlas when its cache entry expires. Raster thumbnails
are bounded to 64 pixels; SVGs retain their original colors.

Native X11 checks cover compact and detailed rows, independently hidden labels,
project icons and fallback icons, project groups, hover controls, and dragging
pinned sessions. The compact hover capture retains the remote icon and PR badge.
The moving card follows the pointer continuously and neighbors animate around
its destination. Clicking Pinned was checked against the filter button's pixels
both during mouse-down and immediately after mouse-up; its border remains unchanged.

Headless regression checks exercise pin/unpin, pin reordering, cancellation,
remote pin conflicts, actual row-height hit testing, small pointer movements,
project grouping/keyboard order, icon lookup priority, SVG/ICO decoding, and
settings persistence. Native macOS and Windows interactions were not exercised.

Validation: `cargo test -p zeron-ui --lib -- --test-threads=1` passed all 1,119
tests. The native fixture build, formatting checks, and `git diff --check` passed.
