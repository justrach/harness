#!/usr/bin/env python3
"""Compile Lean kernels, check generated telemetry witnesses, then test Zig.

No network, telemetry uploads, personal data or production app launch. Requires
Lean 4 and the project's Zig toolchain. --update-vectors regenerates witnesses;
ordinary runs fail on model/vector drift. Compiler outputs live in a temp folder.
"""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
PROOFS = ROOT / "apps/nano/lean-proofs"
VECTORS = ROOT / "apps/nano/src/telemetry_policy_vectors.csv"


def run(args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def check_hot_path():
    # A deliberately narrow drift guard, not a Zig compiler/refinement proof.
    # The policy proofs and runtime no-allocation/blocked-consumer tests provide
    # separate evidence. Keep costly operations out of these actual entrypoints.
    source = (ROOT / "apps/nano/src/performance.zig").read_text()
    for name in ["publish", "sample", "reconcile", "begin", "completed"]:
        start = source.index("fn " + name + "(")
        opening = source.index("{", start)
        depth, end = 1, opening + 1
        while depth:
            depth += (source[end] == "{") - (source[end] == "}")
            end += 1
        body = source[opening:end]
        for forbidden in [".json(", ".post(", ".spawn(", ".join(", ".alloc(",
                          ".create(", ".futexWait", ".frameIn(", ".sleep(",
                          ".redraw(", ".animationFrame(", ".requestFrame"]:
            if forbidden in body:
                raise SystemExit("forbidden foreground operation in " + name + ": " + forbidden)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--update-vectors", action="store_true")
    parser.add_argument("--skip-zig", action="store_true", help="only check Lean and witnesses")
    args = parser.parse_args()
    check_hot_path()
    with tempfile.TemporaryDirectory(prefix="nano-telemetry-proof-") as directory:
        output = Path(directory)
        (output / "Nano").mkdir()
        env = dict(os.environ, LEAN_PATH=str(output) + os.pathsep + str(PROOFS))
        for name in ["FrameSchedule", "ScrollFollow", "Tween", "StripMenu", "FooterChips", "QuestionPanel", "Telemetry"]:
            run(["lean", "-R", str(PROOFS), "-o", str(output / "Nano" / (name + ".olean")),
                 str(PROOFS / "Nano" / (name + ".lean"))], cwd=PROOFS, env=env)
        run(["lean", "--run", "Main.lean"], cwd=PROOFS, env=env)
        generated = subprocess.check_output(["lean", "--run", "TelemetryVectors.lean"], cwd=PROOFS, env=env)
        if args.update_vectors:
            VECTORS.write_bytes(generated)
        elif generated != VECTORS.read_bytes():
            raise SystemExit("Lean telemetry vectors changed; regenerate and inspect the policy change")
        print("PASS: Lean kernels, 704 shared policy vectors and foreground-effect drift guard", flush=True)
    if not args.skip_zig:
        run([str(ROOT / "scripts/heavy-build.sh"), "zig", "build", "test",
             "-Dtest-filter=desktop performance", "--summary", "all"], cwd=ROOT / "apps/nano")


if __name__ == "__main__":
    main()
