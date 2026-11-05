#!/usr/bin/env python3
"""Parity check: each scene in parity/scenes drawn by the GPUI app and by
harness-nano, frame by frame, and compared.

    python3 parity/check.py                 # every scene; fails past the budget
    python3 parity/check.py settings-*.json # some of them
    python3 parity/check.py --update        # record today's numbers as the budget
    python3 parity/check.py --max-changed 0.0005  # every frame, including new ones, within 0.05%
    NANOUI_FORK=~/nanoui python3 parity/check.py   # against a nanoui checkout

Both draw offscreen, with no window and no engine: the GPUI app through its
headless renderer (crates/ui/examples/ui-scenes.rs, built once with
`cargo build --profile app-dev -p harness-ui --features ui-scenes --example
ui-scenes`; this script never builds it), nano through `harness-nano-snap`.
A frame is the first render, then one after each step.

For each frame it writes gpui | nano | difference to <out>/compare, and
reports `changed`: the share of pixels whose channels differ by more than
16 of 255 from every pixel within one of theirs in the other frame, so text
a fraction of a pixel along doesn't count but a box out of place does
(`exact`, without that allowance, is shown beside it). parity/budget.json holds each frame's budget; a frame over it by
more than half a point fails the run, so a change can only make nano closer
to the GPUI app unless the budget is raised on purpose with --update.
"""
from __future__ import annotations

import argparse
import json
import os
import pathlib
import subprocess
import sys

import numpy as np
from PIL import Image

HERE = pathlib.Path(__file__).resolve().parent
NANO = HERE.parent
REPO = NANO.parent.parent
SCENES = HERE / "scenes"
BUDGET = HERE / "budget.json"
GPUI_BIN = pathlib.Path(
    os.environ.get("HARNESS_UI_SCENES", REPO / "target/app-dev/examples/ui-scenes")
).expanduser()
SNAP_BIN = NANO / "zig-out/bin/harness-nano-snap"
# A channel differing by more than this counts the pixel as changed.
THRESHOLD = 16
# How far past its budget a frame may go before the run fails.
SLACK = 0.005


def run(cmd: list, **kw) -> None:
    # Low priority: the checker shouldn't take the machine over.
    r = subprocess.run(["nice", "-n", "10", *map(str, cmd)], capture_output=True, text=True, **kw)
    if r.returncode != 0:
        sys.exit(f"{cmd[0]} failed:\n{r.stdout[-2000:]}{r.stderr[-2000:]}")


def frames(scene: pathlib.Path) -> list[str]:
    s = json.loads(scene.read_text())
    return [f"{s['name']}.png"] + [f"{s['name']}-{i:02}.png" for i in range(1, len(s.get("steps", [])) + 1)]


def compare(a_path: pathlib.Path, b_path: pathlib.Path, out: pathlib.Path) -> dict:
    a = np.asarray(Image.open(a_path).convert("RGB"), dtype=np.int16)
    b = np.asarray(Image.open(b_path).convert("RGB"), dtype=np.int16)
    if a.shape != b.shape:
        return {"changed": 1.0, "mae": 1.0, "error": f"sizes differ: {a.shape} vs {b.shape}"}
    d = np.abs(a - b).max(axis=2)
    exact = float((d > THRESHOLD).mean())
    # The least difference to any pixel a step away, either way round.
    near = np.full(d.shape, 255, dtype=np.int16)
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            shifted = np.roll(np.roll(b, dy, axis=0), dx, axis=1)
            near = np.minimum(near, np.abs(a - shifted).max(axis=2))
    off = near > THRESHOLD
    changed = float(off.mean())
    mae = float(np.abs(a - b).mean() / 255)
    # Difference in red over a dimmed copy of the GPUI frame; text a
    # fraction of a pixel along in dim red.
    heat = (a * 0.35).astype(np.uint8)
    heat[d > THRESHOLD] = [110, 30, 30]
    heat[off] = [255, 40, 40]
    side = np.concatenate([a.astype(np.uint8), b.astype(np.uint8), heat], axis=1)
    Image.fromarray(side).save(out)
    return {"changed": changed, "exact": exact, "mae": mae}


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("scenes", nargs="*", help="scene files or names in parity/scenes (default: all)")
    ap.add_argument("--out", default="/tmp/nano-parity", help="where frames and comparisons go")
    ap.add_argument("--update", action="store_true", help="write these numbers as the budget")
    ap.add_argument("--max-changed", type=float, help="absolute changed-pixel fraction allowed in every frame, including new scenes")
    args = ap.parse_args()
    if args.max_changed is not None and not 0 <= args.max_changed <= 1:
        ap.error("--max-changed must be a finite fraction between 0 and 1")

    scenes = [p if (p := pathlib.Path(s)).exists() else SCENES / s for s in args.scenes] or sorted(SCENES.glob("*.json"))
    if not GPUI_BIN.exists():
        sys.exit(f"no GPUI renderer at {GPUI_BIN}: build it (see this script's header), or set HARNESS_UI_SCENES")
    out = pathlib.Path(args.out)
    for d in ("gpui", "nano", "compare"):
        (out / d).mkdir(parents=True, exist_ok=True)

    fork = os.environ.get("NANOUI_FORK")
    run(["zig", "build", *([f"--fork={fork}"] if fork else [])], cwd=NANO)
    for scene in scenes:
        # Files a scene reads (a theme to import, say), made up, where it says.
        for path, text in json.loads(pathlib.Path(scene).read_text()).get("files", {}).items():
            pathlib.Path(path).parent.mkdir(parents=True, exist_ok=True)
            pathlib.Path(path).write_text(text)
        # One process a scene: the renderer keeps one settings file for its
        # run, so a later scene would open Settings where the last one left it.
        run([GPUI_BIN, scene, "--out", out / "gpui"])
        # nano's clock is simulated: it replays how long each GPUI step took.
        name = json.loads(pathlib.Path(scene).read_text()).get("name", "")
        steps = out / "gpui" / f"{name}.steps.json"
        run([SNAP_BIN, scene, out / "nano"], env={**os.environ, "NANO_GPUI_STEPS": str(steps)})

    budget = json.loads(BUDGET.read_text()) if BUDGET.exists() else {}
    failed = []
    results = {}
    print(f"{'frame':40} {'changed':>8} {'budget':>8} {'exact':>8}")
    for scene in scenes:
        for f in frames(scene):
            r = compare(out / "gpui" / f, out / "nano" / f, out / "compare" / f)
            results[f] = r["changed"]
            limit = budget.get(f)
            over = (not args.update and limit is not None and r["changed"] > limit + SLACK) or (
                args.max_changed is not None and r["changed"] > args.max_changed
            )
            mark = "  FAIL" if over else ("  new" if limit is None else "")
            budget_s = f"{limit:8.2%}" if limit is not None else f"{'':8}"
            print(f"{f:40} {r['changed']:8.2%} {budget_s} {r.get('exact', 1):8.2%}{mark}  {r.get('error', '')}")
            if over:
                failed.append(f)
    report = {
        "frames": len(results),
        "meanChanged": sum(results.values()) / len(results) if results else 0,
        "maxChanged": max(results.values(), default=0),
        "maxAllowed": args.max_changed,
        "failed": failed,
        "changed": results,
    }
    (out / "report.json").write_text(json.dumps(report, indent=1) + "\n")
    print(f"{len(results)} frames; mean {report['meanChanged']:.4%}; max {report['maxChanged']:.4%}")
    print(f"comparisons: {out / 'compare'}")
    if failed:
        sys.exit(f"{len(failed)} frame(s) exceed the parity limits: {', '.join(failed)}")
    if args.update:
        budget.update(results)
        BUDGET.write_text(json.dumps(dict(sorted(budget.items())), indent=1) + "\n")
        print(f"budget written: {BUDGET}")


if __name__ == "__main__":
    main()
