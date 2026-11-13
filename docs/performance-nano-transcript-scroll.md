# Settled Nano transcript scrolling

A settled conversation rebuilt and laid out every warmed message on wheel
frames. Its culling policy assumed NanoUI could instead shift a retained
scene. That assumption does not hold for this transcript: its required
nested column clip makes `retain.cannotRetain` reject the scene. The
pre-fix regression recorded 5,310 nodes and `retained=false` on every frame
of a synthetic 160-reply conversation.

## Change

Use the existing measured-height spacers for completed offscreen rows on
ordinary live frames too, not only during streaming, other-session work,
resize or sidebar animation. The visible rows and a 380-point skirt still
render normally. These are lightweight spacers, not a new list/index,
background worker, timer, animation loop or dependency.

Previous row rectangles belong to the previous layout. Project their bounds
through the pending scroll-offset delta before deciding to skip them, so a
large wheel jump mounts its destination immediately instead of displaying a
spacer where new content should be. Width changes still require valid
measurements at the new column width. Active text selection and prompt-rail
navigation retain the full-content path. The offscreen fixture path can
still explicitly request the full tree as a reference.

This bounds expensive Markdown/layout work to nearby completed rows; it
still iterates cheap per-entry spacers. It is not a claim of constant-time
work for arbitrarily large histories or virtualization within one giant
Markdown message.

## Evidence and limits

`tests_scroll_performance.zig` drives NanoUI's actual wheel path over 160
synthetic completed Markdown replies, measuring 24 warm frames. The
production transcript source at the pre-fix baseline (`611baa21`) is
identical to `origin/main`'s. The new regression
`transcript scroll cost tracks the viewport instead of all warmed history`
fails before the production patch: both the reference and live path build
5,310 nodes. After the fix, the live path builds 474 nodes.

Representative ReleaseSafe runs measured approximately **1.4–1.8 ms** per
reference/full-tree wheel frame versus **0.10–0.11 ms** for the optimized
path. The [recorded matched run](performance/nano-transcript-scroll.json)
measured **1.81 ms → 0.11 ms**. The automated gate uses generous ratios: at least 5× fewer nodes and
3× lower wheel-frame CPU cost, rather than a machine-dependent deadline.

The reference and optimized paths have identical scroll bounds/offsets and
identical rendered pixel hashes after ordinary scrolling, a 10,000-point
wheel jump, and a width change. A production-shell test selects and copies
native transcript text while verifying that selection restores the full
content tree. The earlier #814 background-working shape regression retains
its 5× assertion against an explicitly full-tree reference; an idle live
chat is no longer an unoptimized baseline.

A 120-Hz frame budget is roughly 8.33 ms **in total**. These measurements are
offscreen UI build/layout/paint CPU work, not GPU/presentation timing or a
claim of sustained 120 fps on every display and workload. No frame-rate cap
was forced, and no animation or scroll behavior was slowed to win the test.

## Reproduce

```sh
scripts/heavy-build.sh sh -c 'cd apps/nano && zig build test -Dtest-filter="transcript scroll" -Doptimize=ReleaseSafe -j2 --summary all'
scripts/heavy-build.sh sh -c 'cd apps/nano && zig build test -j2'
python3 scripts/test_run_nano_demo.py
python3 scripts/run-nano-demo.py --no-build
```

Set `NANO_SCROLL_SNAP_DIR` to an existing directory to save matching
full/live wheel, jump and resize images. No personal conversation, journal,
account, system clipboard or real-screen input is used by the regressions.
The [isolated native demo](nano-demo.md) opens a ready-made synthetic
conversation beside real local Git history so the interaction can also be
tried manually. Its empty PR state is intentional: it has no GitHub remote
or authentication, and does not pretend to demonstrate live PR integration.
