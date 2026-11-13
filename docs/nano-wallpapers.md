# Nano new-chat wallpapers

Settings → Appearance → New-chat wallpaper offers None (the default), Dusk,
and Dunes. Parallax is Off, Subtle (the default), or Normal. These preferences
stay in Nano's existing device-local settings store. Existing conversations,
transcripts, files and browser views do not draw the wallpaper.

The two scenes are original procedural geometry in
`apps/nano/src/wallpaper.zig`: five native colored shapes per scene. There
is no scripting runtime, compiler, plugin loader, downloaded artwork, image,
shader or additional build dependency for wallpapers. The vendored NanoUI
package is unchanged; the feature uses its existing boxes and motion API.
The separate conversation `show_visual` runtime/API is unaffected.

## Native rendering and motion

Each visible new-chat pane computes its own value-owned geometry from its
viewport and scheme. NanoUI's existing per-host keyed motion store owns the
springs, interruptible retargeting, settling and frame scheduling. There is
no application-level VM, tree cache, allocation lifecycle or retry loop.

Pointer exit returns to center. With Reduce Motion, parallax targets are zero
and native motion lands immediately. Disabled wallpapers draw nothing, and
unknown scene preferences fall back to None. The decoration has no
interactive nodes, so it cannot consume composer clicks or keystrokes.

## Verification

```sh
scripts/heavy-build.sh sh -c 'cd apps/nano && zig build test -Dtest-filter=wallpaper -j2'
scripts/heavy-build.sh sh -c 'cd apps/nano && zig build -Doptimize=ReleaseSafe -j2'
```

Set `NANO_WALLPAPER_SNAP_DIR` to an existing folder when running the tests to
capture before/after and both scenes in light/dark through the production
view, using synthetic data and NanoUI's offscreen Tester. Tests also cover
real settings controls, composer input, new-chat scope, unknown preferences,
Reduce Motion, pointer exit and idle quiescence.
