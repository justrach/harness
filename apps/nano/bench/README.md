# harness-nano against the GPUI app: resources

`resource.py` runs the GPUI app's UI-only replay
(`crates/ui/examples/macos-resource-profile.rs`) and harness-nano's
(`src/profile.zig`) on the same made-up transcript replay
(`make_replay.py`), one after the other, never together, and samples each
with `scripts/macos-resource-stat.c` (CPU time, resident size, physical
footprint, idle wakeups) every 500 ms. Both draw offscreen with real
CoreText and Metal at 1320 by 880, 2x; no window, engine or account.
The nano replay mirrors GPUI's connected state and per-frame session status,
including the working animation while text streams and its removal at settle.

```bash
# From the repository root, build the GPUI profiler (once):
CARGO_TARGET_DIR="$PWD/target" CARGO_INCREMENTAL=0 \
  scripts/heavy-build.sh cargo build --profile app-dev -p harness-ui \
  --features resource-profile --example macos-resource-profile
# Then from apps/nano, build nano and run the comparison:
cd apps/nano
zig build -Doptimize=ReleaseFast --fork=$HOME/nanoui
python3 bench/resource.py --runs 2
```

Both scripts default to this checkout's `target/app-dev/examples` directory,
resolved from the script location rather than the working directory:
`bench/resource.py` uses `macos-resource-profile` (override with
`HARNESS_RESOURCE_PROFILE`), and `parity/check.py` uses `ui-scenes` (override
with `HARNESS_UI_SCENES`). Overrides expand `~`; there is no shared-cache
fallback.

CPU and wakeup rates exclude the first two seconds of each phase. Peak
footprint and RSS include the entire phase: a startup or settling spike
must not disappear behind the rate warmup. Zero-footprint exit samples are
ignored: macOS can report a process's historical RSS after its charged memory
has gone, which otherwise makes resting memory spuriously low. The summary
rules are checked with synthetic samples (run from the repository root):

```bash
python3 -m unittest discover -s apps/nano/bench -p test_resource.py
```

The last results are in `docs/performance/nano-gpui-offscreen.json`.
