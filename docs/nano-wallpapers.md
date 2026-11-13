# Nano new-chat wallpapers

Settings → Appearance → New-chat wallpaper offers None (the default), Dusk,
and Dunes. Parallax is Off, Subtle (the default), or Normal. These preferences
stay in Nano's existing device-local settings store. Existing conversations,
transcripts, files and browser views do not draw the wallpaper.

The two scenes are original procedural artwork in
`apps/nano/src/wallpapers/*.luau`. No external artwork, images, shaders,
network requests or plugins are downloaded. The host gives each scene only
its viewport, normalized pointer, color scheme and reduced-motion flag.
Choosing None releases the VM and cached trees. A broken scene falls back to
plain content with a visible notice and does not retry every frame; choosing
another scene explicitly recreates it.

## Boundary

The separate `nanoui_luau` module is opt-in at NanoUI's build boundary. Harness
Nano opts in. NanoUI consumers that do not select `-Dluau=true` retain the
existing core graph without Luau or C++. The bridge directly builds pinned
Luau compiler/VM source with Zig; there is no C shim or Rust dependency.

Luau returns bounded inert trees of containers, native text and rectangles,
with spring/tween offset targets. NanoUI's existing native motion store owns
retargeting, settling, frame requests and Reduce Motion. Scripts have no
application UI selectors, events, callbacks, filesystem, network, process,
chat or credential access. There is no third-party plugin loader in this PR.
This does not expand the separate conversation `show_visual` runtime/API.

Each visible pane leases its own host-owned tree cache. Lua runs only when
its input changes, not on every animation frame. Two panes cannot invalidate
each other's trees. Pointer exit returns to center. With Reduce Motion,
parallax targets are zero and native motion lands immediately. The wallpaper
has no interactive nodes, so it cannot consume composer clicks or keystrokes.

The VM uses a 16 MiB allocation cap, 20 ms cooperative deadlines, 64 KiB source,
128 nodes, depth 16, and 8 KiB aggregate output strings. Compilation/native
library work is not hard-preempted and compiler allocations are outside the
VM cap. This first integration accepts bundled source only; it is **not** a
hard isolation boundary for arbitrary external plugins.

## Verification

```sh
scripts/heavy-build.sh sh -c 'cd apps/nano && zig build test -Dtest-filter=wallpaper -j2'
scripts/heavy-build.sh sh -c 'cd apps/nano && zig build -Doptimize=ReleaseSafe -j2'
```

Set `NANO_WALLPAPER_SNAP_DIR` to an existing folder when running the tests to
capture before/after and both scenes in light/dark through the production
view, using synthetic data and NanoUI's offscreen Tester. The tests also
cover real settings controls, composer input, new-chat scope, failure/recovery,
Reduce Motion, pointer exit, cache reuse and idle quiescence.
