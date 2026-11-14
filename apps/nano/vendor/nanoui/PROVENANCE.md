# Vendored nanoui

Source: https://github.com/justrach/nanoui

Pinned revision: `09033e1fc9a2fe99fe9d276bb5e548914f4733a5` (nanoui 0.13.0).
Original Zig package hash: `nanoui-0.13.0-we0KMZixOgAWGOwh3EwZBX_6abC1iZRv9nr53YZoE_wn`.
The unmodified copy was verified with `zig fetch` to produce that exact hash before local changes.

Only the upstream package's declared distribution paths are included: build files, `src`, `tools/ios`, `tools/android`, `LICENSE`, `THIRD_PARTY_NOTICES.md`, and `third_party/licenses`. Examples, build output, package caches, and unrelated tools are not vendored. The MIT license and all bundled third-party notices/licenses are retained unchanged.

Harness-local changes restore scroll viewport alpha fades (#427): `Style.scroll_edge_fade` masks a scrolling box's complete content after compositing it, leaving its own background, native scrollbar and hit regions intact. Hidden-edge rules live in `src/ui/scroll_fade.zig`. Metal, OpenGL/ES, D3D11 and the CPU reference renderer consume the same nested group stream without changing the 192-byte GPU instance ABI. D3D11 uses grayscale glyph coverage inside transparent groups. Existing ordinary-opacity groups retain their parent-backdrop glass behavior.

The scrolling-mask local edits are limited to the two build manifests; `src/ui/{types,gpu,paint,metal,opengl,d3d11,raster,ui}.zig`; the three `shader.{metal,glsl,hlsl}` files; and the new `scroll_fade.zig` / `tests_scroll_fade.zig`. `test-scroll-fade` runs native or portable pixel/rule tests; `check-scroll-fade` compiles the platform GPU entry points without running a cross-target executable. Examples and unrelated tools are not required by either gate. `.gitignore` excludes only generated local build/dependency directories.

Harness-local pointer-selection changes also update `src/ui/selection.zig`
and add `text_selection.zig`, generated `text_selection_data.zig`, and the
unmodified Unicode 17.0.0 `grapheme_break_test.txt`. Double-click hit testing
uses the glyph cell under the pointer, not the nearest insertion caret or
word-cursor navigation. Unicode UAX #29 extended-grapheme segmentation
preserves combining marks, emoji modifiers, flags, ZWJ sequences, and Indic
conjuncts; words retain identifier and Unicode letter/number runs, while
punctuation/emoji select whole individual graphemes. Original UTF-8 source
bytes and ordinary caret/drag indexing are unchanged. Native and reference
shapers use the same rule. Prior viewport mask/fade changes are retained.

The Unicode 17.0.0 official UCD sources are listed in the generated table
header. Regenerate offline using `python3 src/ui/gen_text_selection.py
<ucd-directory>` with those four property files plus `GraphemeBreakTest.txt`.
Hangul LV/LVT properties are computed algorithmically; all other
break properties, Extended_Pictographic, and Indic_Conjunct_Break come from
the pinned Unicode data. The Unicode license and notice are retained in
`third_party/licenses/Unicode-3.0.txt` and `THIRD_PARTY_NOTICES.md`.
`zig test src/ui/text_selection.zig -fllvm` runs the full pinned Unicode
GraphemeBreakTest corpus and word/pointer boundary vectors. Harness's
`deep interface doubleclick` tests exercise production native rendering
and source-byte Copy across glyph-cell edges.

Harness-local desktop termination gating adds the optional
`Options.should_terminate` predicate to `src/app.zig`, `src/linux/app.zig`
and `src/windows/app.zig`. `App.quit` checks it before changing lifecycle
state or stopping the event loop, so explicit Save/Discard/Cancel decisions
can safely veto Quit. A null hook preserves upstream behavior. The macOS
native delegate and imperative Quit share the gate; the native veto test
also checks exactly-once termination callbacks. AppOptions changed, so
rebuild the native runtime through the normal package graph after updating.

The Linux native window also retains `Options.should_close` and honors it
for GTK 3 delete events, GTK 4 close requests and imperative close. Final App
teardown uses `destroyNow` after close decisions have been resolved, matching
Windows' forced-disposal path and avoiding a vetoed-close teardown loop.
This supplies the same dirty-document veto contract to all desktop windows.

The native timeline row is cherry-picked from upstream proposal
https://github.com/justrach/nanoui/pull/177, commit
`b641cf30f360d40f41248478fea3aed0597a14ed`: `src/kit/timeline.zig`
and its two public exports in `src/kit/kit.zig`. The upstream base/pin is
unchanged. The proposal carries the domain-neutral component tests and
cross-platform checks; Harness's native history tests exercise the consumer.
No Luau module or runtime is included.

Harness-local responsiveness instrumentation adds an optional `View.after_frame`
callback in `src/ui/ui.zig`, invoked exactly once by `src/ui/frame.zig` after
completed CPU-frame work (including retained frames). A null callback leaves
upstream behavior unchanged. Harness owns the bounded metric recorder and
background transport; the toolkit hook does not serialize or send data.

Harness-local bottom overscroll changes in `src/ui/scroll.zig` use a bounded
nonlinear resistance curve and its inverse, preserving event-coalescing and
reversal behavior. Discrete wheels, native momentum, Reduce Motion and idle
spring termination retain their explicit paths. Harness's `tests_scroll_bounce`
module exercises the production consumer.

Harness-local ImageIO orientation handling in `src/ui/image.zig` reports
EXIF-oriented dimensions for both header layout and transformed thumbnails.
Small rotated/mirrored images also use ImageIO's transformed thumbnail path,
so their decoded pixels and layout agree. Harness's native headless
`image orientation` regression checks small and large synthetic PNGs and
actual rendered quadrant positions; ordinary reply-image tests remain intact.

These changes live in this checked-in package, not an ignored download cache.

To update: start with the pinned upstream distribution, retain the notices,
reapply/reconcile the local mask, pointer-selection and termination changes, and run the
`test-scroll-fade` gate in both native and `-Dportable=true` modes with LLVM.
Also run the Unicode conformance/helper and Harness double-click gates above.
Update this revision/hash when changing the upstream base; a Unicode data
upgrade updates its pinned version, tables, conformance vectors and notice
together.
