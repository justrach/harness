#!/usr/bin/env python3
"""The GPUI app and harness-nano measured on the same UI-only replay, by the
same sampler: each binary replays bench/replay.json offscreen (GPUI:
crates/ui/examples/macos-resource-profile.rs; nano: src/profile.zig) while
scripts/macos-resource-stat.c reads its CPU time, resident size and
physical footprint every 500 ms, as scripts/resource-profile.mjs does.
Phases come from the binaries' `phase=replay` / `phase=settled` lines; the
first 2 s of each are left out of CPU and wakeup rates. Memory peaks
include every sample in the phase, including that warmup window.

    python3 bench/resource.py [--runs 2] [--out /tmp/nano-resource]

Runs alternate (gpui, nano, nano, gpui, ...) and never overlap. No window,
engine or account is used.
"""
from __future__ import annotations

import argparse
import json
import os
import pathlib
import statistics
import subprocess
import sys
import threading
import time

HERE = pathlib.Path(__file__).resolve().parent
NANO = HERE.parent
REPO = NANO.parent.parent
STAT_SRC = REPO / "scripts/macos-resource-stat.c"
GPUI_BIN = pathlib.Path(os.environ.get(
    "HARNESS_RESOURCE_PROFILE", REPO / "target/app-dev/examples/macos-resource-profile")).expanduser()
NANO_BIN = NANO / "zig-out/bin/harness-nano-profile"
SKIP_S = 2.0


def stat(tool: pathlib.Path, pid: int) -> dict | None:
    try:
        rows = json.loads(subprocess.run([tool, str(pid)], capture_output=True, text=True).stdout)
        # An exiting process can retain historical RSS but report zero
        # physical footprint. Do not average that teardown row into rest.
        return rows[0] if rows and rows[0].get("footprintMiB", 0) > 0 else None
    except Exception:
        return None


def summarize(samples: list[dict]) -> dict:
    summary = {}
    for p in ("replay", "settled"):
        phase_rows = [s for s in samples if s["phase"] == p]
        if not phase_rows:
            continue
        t0 = phase_rows[0]["at"] + SKIP_S
        rows = [s for s in phase_rows if s["at"] >= t0] or phase_rows
        first, last = rows[0], rows[-1]
        span = max(last["at"] - first["at"], 1e-9)
        summary[p] = {
            "durationSeconds": round(span, 2),
            "cpuPercent": round(100 * (last["cpuSeconds"] - first["cpuSeconds"]) / span, 2),
            "peakFootprintMiB": round(max(s["footprintMiB"] for s in phase_rows), 1),
            "endFootprintMiB": round(last["footprintMiB"], 1),
            "peakRssMiB": round(max(s["rssMiB"] for s in phase_rows), 1),
            "endRssMiB": round(last["rssMiB"], 1),
            "idleWakeupsPerSecond": round((last["idleWakeups"] - first["idleWakeups"]) / span, 1),
        }
    summary["lifetimePeakFootprintMiB"] = round(max(s["lifetimePeakFootprintMiB"] for s in samples), 1)
    summary["totalCpuSeconds"] = round(samples[-1]["cpuSeconds"], 2)
    return summary


def profile(name: str, cmd: list, tool: pathlib.Path, out: pathlib.Path) -> dict:
    out.mkdir(parents=True, exist_ok=True)
    proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    phase = {"now": "startup"}
    marks: list[tuple[float, str]] = []
    start = time.monotonic()

    def read():
        for line in proc.stderr:
            if "phase=replay" in line:
                phase["now"] = "replay"
            elif "phase=settled" in line:
                phase["now"] = "settled"
            else:
                continue
            marks.append((time.monotonic() - start, phase["now"]))

    reader = threading.Thread(target=read, daemon=True)
    reader.start()
    samples = []
    while proc.poll() is None:
        s = stat(tool, proc.pid)
        if s:
            s.update(at=time.monotonic() - start, phase=phase["now"])
            samples.append(s)
        time.sleep(0.5)
    reader.join(timeout=2)
    if proc.returncode != 0:
        sys.exit(f"{name} exited {proc.returncode}")
    summary = summarize(samples)
    (out / "samples.json").write_text(json.dumps(samples))
    (out / "summary.json").write_text(json.dumps(summary, indent=1))
    return summary


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--runs", type=int, default=2, help="runs of each, alternating")
    ap.add_argument("--out", default="/tmp/nano-resource")
    ap.add_argument("--only", choices=["gpui", "nano"])
    args = ap.parse_args()
    out = pathlib.Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    tool = out / "macos-resource-stat"
    if not tool.exists():
        subprocess.run(["xcrun", "clang", "-O2", STAT_SRC, "-o", tool], check=True)
    replay = out / "replay.json"
    replay.write_text(subprocess.run([sys.executable, HERE / "make_replay.py"], capture_output=True, text=True, check=True).stdout)
    which = [args.only] if args.only else ["gpui", "nano"]
    for name, path in (("gpui", GPUI_BIN), ("nano", NANO_BIN)):
        if name in which and not path.exists():
            sys.exit(f"no {name} profiler at {path}: build it (see bench/README)")
    order = []
    for i in range(args.runs):
        order += which if i % 2 == 0 else list(reversed(which))
    results: dict[str, list] = {n: [] for n in which}
    for n, name in enumerate(order):
        run_dir = out / f"{name}-{n}"
        cmd = [GPUI_BIN if name == "gpui" else NANO_BIN, replay, run_dir]
        print(f"run {n + 1}/{len(order)}: {name}", file=sys.stderr)
        results[name].append(profile(name, [str(c) for c in cmd], tool, run_dir))
    means = {}
    for name, runs in results.items():
        m = {}
        for p in ("replay", "settled"):
            keys = runs[0].get(p, {}).keys()
            m[p] = {k: round(statistics.mean(r[p][k] for r in runs if p in r), 2) for k in keys}
        m["lifetimePeakFootprintMiB"] = round(statistics.mean(r["lifetimePeakFootprintMiB"] for r in runs), 1)
        means[name] = m
    report = {"replay": "bench/make_replay.py", "runs": results, "means": means}
    (out / "report.json").write_text(json.dumps(report, indent=1))
    print(json.dumps(means, indent=1))


if __name__ == "__main__":
    main()
