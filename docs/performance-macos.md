# Native macOS resource follow-up

This follows PR #255 at `f10ef38c`. The app pins zui `0003b923`, which gates
unnecessary main-queue frame callbacks and bounds native Metal blur resources.
The Linux software-Vulkan results in [the earlier report](performance-resource-usage.md)
do not predict native Metal usage.

## Changes

- Transcript row derivation now has a content revision. Presence, catalog and
  other unrelated state notifications skip rebuilding rows, while selection,
  replay readiness, optimistic echo insertion/removal, transcript deltas and
  subagent content invalidate the cache. Live entries also skip an unused
  serialized fingerprint.
- The native frame loop parks clean-window callbacks and wakes for content,
  input or animations. It keeps the existing display clock and lifecycle
  protections. The timing thread still runs while the window is subscribed.
- Metal uses a per-frame autorelease pool and bounded caches for alternating
  blur surfaces. Smaller texture buckets reduce over-allocation; window shrink
  and idle transitions release obsolete extents. Current surfaces retain their
  resources. Blur sigma, shaders, clipping, animation clocks and scroll behavior
  stay unchanged.
- The resource driver now reports native process CPU and physical footprint as
  well as RSS. Its window helper rejects locked/asleep displays and invalidates
  measurements if the app loses the foreground or its window disappears.
- Replay recording clones frames before the transcript applier mutates them.
  Otherwise later appends corrupt historical reset/upsert records.

## Validation and limits

593 UI tests, 207 GPUI library tests and 15 native macOS tests passed. The native
suite covers wake after idle, animation continuation, resize, Gaussian blur
pixels, identical cold/warm rendering, cache bounds and menu-close trimming.
The macOS pasteboard tests share the system clipboard and are run serially.
The optional native UI replay example uses CoreText, Metal, the real shell and
real animation clocks; its completed transcript is rendered to `complete.png`.
The profiling feature and its benchmark dependencies are not enabled in normal
application builds.

The Mac's display was locked during this work. Native offscreen rendering is
valid for checking pixels and isolated rendering cost. It cannot verify native
window presentation, desktop background blur, display pacing, interactive input
or foreground whole-app CPU/memory savings. The user's reported memory swings
are not yet conclusively attributed. RSS alone is insufficient for comparison
because the native physical-footprint counter also accounts for charged
compressed and GPU memory.

Before merge, repeat foreground baseline/candidate runs and check typing,
selection/copy, scrolling, streaming/completion, menus, resizing, occlusion and
display reconnection with the Mac unlocked. This is a draft pending those checks.

## Repeated native offscreen comparison

Two sequential runs per build, ordered baseline/candidate/candidate/baseline,
on macOS 26.0.1 (25A362), arm64 Mac16,7 with 24 GiB RAM. The synthetic shell
replays the same protocol frames at the recorded cadence, at 1320×880 logical
pixels and 2× scale, then waits 15 seconds. Each phase excludes its first two
seconds. Both drivers use the same allocator and native text/Metal backends.
The baseline adds only the profiling driver and embedded-platform launch support.
[Raw samples and executable/trace hashes](performance/resource-macos-offscreen.json).

| UI-only replay metric | PR #255 | Candidate |
| --- | ---: | ---: |
| CPU, 100% per core | 18.49% | 18.46% |
| Mean of per-run peak physical footprint | 282.85 MiB | 286.69 MiB |

These runs establish **no meaningful streaming CPU or memory improvement** in
this isolated workload. It excludes native display-link dispatch and desktop
composition and does not open alternating menus. The completed 2640×1760 app
image is byte-identical between baseline and candidate in the first matched pair.
The frame-gating and unused-resource cleanup benefits still require a foreground
comparison. Do not present these results as a reduction in the reported whole-app
streaming usage, or as a universal memory floor.

## Reproduction

Requires Node 22+, Rust and Xcode Command Line Tools. Foreground profiling needs
existing Accessibility access to activate and size the isolated window. Keep
that window foreground and the display awake for the entire run. Replay uses
an isolated profile and the bundled sanitized fixture; it makes no model API call.

```sh
cargo build --release --locked -p zeron
ZERON_FRAME_STATS=0 ZERON_PROFILE_IDLE_MS=45000 \
  CLAUDE_CODE_EXECUTABLE="$PWD/scripts/replay-claude.py" \
  ZERON_REPLAY_JOURNAL="$PWD/scripts/fixtures/resource-stream.jsonl" \
  node scripts/resource-profile.mjs target/release/zeron /tmp/zeron-native claude-code

# UI-only offscreen replay of those verified protocol frames:
cargo build --release --locked -p zeron-ui --features resource-profile \
  --example macos-resource-profile
ZERON_FRAME_STATS=0 target/release/examples/macos-resource-profile \
  /tmp/zeron-native/frames.json /tmp/zeron-native-ui

# Native counter usable with either process (CPU uses 100% per core):
xcrun clang -O2 scripts/macos-resource-stat.c -o /tmp/zeron-stat
/tmp/zeron-stat PID
```

Compare fresh release builds in alternating order, with the same trace,
window geometry, display scale and settings. Do not compile or run a profiler
concurrently with timed comparisons. Engine and harness processes are reported
separately from the UI; the offscreen example excludes both and the window
compositor. Its polling loop must not be reported as native idle CPU.
