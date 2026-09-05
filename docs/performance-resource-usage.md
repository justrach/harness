# Resource profiling, 2026-09-05

Baseline: main `f1d4bad` (v0.2.37). Optimized application source: `4902c79`.
Both are release builds. The optimized build pins
[`zeronsh/zui` at `25f1c948`](https://github.com/zeronsh/zui/commit/25f1c948cef229df2536cf4b7b6731bcb30602e1).

## Measured results

UI + engine totals, foreground window with a focused composer. The short
workload is the same captured Haiku response in every run: 51,769 bytes of
assistant Markdown, or 52,624 bytes including reasoning and part separators.
Values below average two independent runs with one software-rendering worker.
The exact executable hashes, reply hashes and individual measurements are in
[baseline](performance/resource-baseline.json) and
[candidate](performance/resource-candidate.json).

| Metric | Old Zeron | Optimized | Change |
| --- | ---: | ---: | ---: |
| Idle peak RSS | 331.10 MiB | 204.08 MiB | -38.4% |
| Streaming peak RSS | 359.39 MiB | 230.13 MiB | -36.0% |
| Streaming CPU | 113.51% | 109.78% | -3.3% |
| Post-completion CPU, last 10 s | 20.96% | 14.66% | -30.1% |

The synthetic long workload repeats the same captured deltas ten times,
producing a 526,258-byte combined reply. Each build ran it once:
[baseline](performance/resource-long-baseline.json),
[candidate](performance/resource-long-candidate.json).

| Long-stream metric | Old Zeron | Optimized | Change |
| --- | ---: | ---: | ---: |
| Streaming peak RSS | 398.13 MiB | 254.06 MiB | -36.2% |
| Streaming CPU | 112.30% | 113.50% | +1.1% |
| Post-completion CPU, last 10 s | 92.77% | 15.55% | -83.2% |

The long completion result captures an actual defect: a landed spring could
keep requesting frames, and subsequent virtual-list height estimates could
restart its glide indefinitely. The optimized build parks and anchors to the
final list item. Real scrolling still uses the existing spring integration.

The single graphics worker is saturated while streaming. Total streaming CPU
is effectively unchanged there; those samples do not establish a meaningful
streaming CPU reduction. A separate four-worker check reduces that constraint
and also records proportional memory, which apportions shared mappings instead
of counting their full RSS in both processes. This is one run per build, not
the repeated comparison above; see [raw results](performance/resource-four-workers.json).

| Four-worker metric | Old Zeron | Optimized | Change |
| --- | ---: | ---: | ---: |
| Idle peak RSS | 330.69 MiB | 203.04 MiB | -38.6% |
| Idle peak proportional memory | 274.02 MiB | 146.20 MiB | -46.6% |
| Streaming peak proportional memory | 300.74 MiB | 173.67 MiB | -42.3% |
| Streaming CPU | 267.42% | 227.40% | -15.0% |

## Changes supported by profiling

- OpenCode model discovery built a full generic JSON tree for `/provider` and
  deep-copied it before filtering. Heaptrack measured a 112.25 MB engine heap
  peak dominated by this catalog. Discovery and run setup now decode only the
  required IDs, names and reasoning variant keys, skip unused nested bodies,
  and stream the response through a 64 KiB buffer. Cancellation interrupts a
  stalled body read. Connected-provider filtering and older-server fallback
  remain. The catalog is dropped once run setup chooses the variant.
- Engine transcript snapshots are shared across RPC watches. UI row derivation
  borrows app-state messages instead of copying the complete transcript.
- Incremental Markdown trees share immutable completed blocks across canonical,
  display and previous frames. Only the changing tail reparses and mends.
- Tree-sitter queries compile once per used grammar. Injection grammars load
  when actually requested; Markdown no longer eagerly compiles 27 languages.
- Text dissolves use the shared 30 Hz clock; small shell spinners use a 15 Hz
  lease. Leases expire when hidden or retired. Real scroll motion and reduced
  motion behavior remain intact. A stationary spring no longer redraws its
  500 ms state-retention grace period.
- The sidebar has a cached GPUI view identity, invalidated by shell changes
  and its own animations. Markdown flatten/code caches retain the viewport
  and overdraw rather than every row visited while scrolling.
- The wgpu blur prepares normalized Gaussian weights once per surface, pairs
  adjacent unit-stride texture samples, and scissors each pass to the pixels
  needed by compositing and the next pass. Original downsampled tap positions,
  blur radius and an oversized-kernel fallback remain. Zui's extracted crate
  sources matched the previous fork revision before this patch was applied.

An optimized standalone parser benchmark holds the previous display tree while
constructing the next, using the captured text and 160-byte commits:

| Parser-only metric | Baseline | Optimized |
| --- | ---: | ---: |
| Allocated bytes | 24,268,705 | 8,927,654 |
| Allocation calls | 133,054 | 11,210 |
| Peak live bytes above input | 377,910 | 206,520 |
| Retained bytes above input | 279,770 | 188,057 |
| Elapsed time | 12.84 ms | 2.21 ms |

These are parser-only allocation/time results, not whole-process RSS or CPU.

## Method and limits

Linux x86-64, Xvfb 1440×900, app window 1280×800, GPUI software Vulkan rendering.
CPU uses one core = 100% and includes every process thread. RSS totals sum each
process's phase peak; those peaks need not occur simultaneously. UI + engine
figures exclude Claude/OpenCode child processes, which are sampled separately.
OpenCode is installed and automatic model discovery is included. Catalog-related
memory savings depend on that workload. Sampling begins after the initial
window configure/focus, so the idle phase is not a complete startup-peak capture.

Each matched run uses a new profile, project and chat; 10 seconds before sending,
fixed replay cadence (40 ms short, 8 ms long), and 45 seconds after completion.
The last 10 seconds are reported separately from final scroll/fade settling.
Runs were sequential with no concurrent task builds. Frame diagnostics were
disabled for matched measurements. Each driver snapshots and hashes its binary,
validates production transcript reset/upsert/append/remove frames, and requires
successful completion. Matching reply hashes verify identical content.

A process-targeted `perf` sample attributed about 95% of UI CPU to software
rendering. UI heaptrack's largest allocation groups were 54.32 MB in lavapipe
and 28.38 MB in Gallium/EGL. Those are graphics-driver costs on this host;
they are not measurements of macOS Metal or a universal laptop resource ceiling.

## Validation and reproduction

978 application tests passed, with four existing ignored tests: UI (592),
document (87), engine library (127), harness library (103), RPC (12), syntax
library/integration (25), Claude/OpenCode adapter integration (21), and targeted
engine integration (11). The 592 UI tests were rerun in release mode against
the final zui dependency. Five additional zui numerical tests cover convolution
equivalence, paired samples at texture edges, oversized radii, scissor coverage
and translated snapshots. Script checks and `git diff --check` passed. This is
not a claim that every workspace integration target ran.

A fresh authenticated Haiku 4.5 turn was submitted through the composer on the
final executable. It completed a shell-tool call successfully and produced
30 sections and 27,062 bytes of reply text/reasoning. Sidebar collapse/expand,
scrolling away and returning to the live tail, syntax highlighting, selected
text copy/paste and the completed state were checked in the real window. Its
[summary](performance/resource-live.json) is functional verification: manual
interactions and a concurrent test build make its CPU values unsuitable for
the matched comparison.

Requires Node 22+, Rust, Python 3, Xvfb/xdotool for Linux desktop profiling,
and an authenticated Claude CLI for a live run. Live mode incurs API usage.
The checked-in [sanitized fixture](../scripts/fixtures/README.md) reproduces the
measured replay without an API call. Use a dedicated display and new output
directories; the driver requires exactly one Zeron window.

```sh
cargo build --release -p zeron
Xvfb :98 -screen 0 1440x900x24 -nolisten tcp
# In another terminal, run the exact short replay:
DISPLAY=:98 WAYLAND_DISPLAY= LP_NUM_THREADS=1 ZERON_FRAME_STATS=0 \
  ZERON_PROFILE_IDLE_MS=45000 \
  CLAUDE_CODE_EXECUTABLE="$PWD/scripts/replay-claude.py" \
  ZERON_REPLAY_JOURNAL="$PWD/scripts/fixtures/resource-stream.jsonl" \
  node scripts/resource-profile.mjs target/release/zeron /tmp/zeron-short claude-code

# Add ZERON_REPLAY_REPEAT=10 ZERON_REPLAY_DELAY_MS=8 for the long workload.
# Use LP_NUM_THREADS=4 ZERON_PROFILE_PSS=1 for the four-worker check.
# For a live turn, omit the replay variables and point
# CLAUDE_CODE_EXECUTABLE to the real CLI. ZERON_PROFILE_SUBMIT_UI=1
# submits through the composer instead of QueueCommand.
```

Each run writes its summary, raw process samples, RPC frames, final transcript
and process logs. Optional `ZERON_MAX_ENGINE_RSS_MIB` / `ZERON_MAX_UI_RSS_MIB`
set machine-specific peak-RSS budgets. `ZERON_FRAME_STATS=1` enables render
cadence and row-cost diagnostics; application diagnostics are off by default.
The replay helper deliberately rejects failed/tool/subagent journals: those
features require the real harness or integration suites.
