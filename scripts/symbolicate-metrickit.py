#!/usr/bin/env python3
"""Print the call stacks in an iOS crash or hang report with function names.

A report shared from Harness on iOS (Settings -> Crash reports) is MetricKit's
JSON: every frame is a binary and an offset into it. Frames in Harness are
looked up in the build's dSYM with `atos`; the testflight workflow keeps each
build's dSYMs as the `dsyms-build-<number>` artifact.

    scripts/symbolicate-metrickit.py report.json path/to/dSYMs
"""

import json
import pathlib
import subprocess
import sys

KINDS = [
    ("crashDiagnostics", "Crash"),
    ("hangDiagnostics", "Hang"),
    ("cpuExceptionDiagnostics", "CPU"),
    ("diskWriteExceptionDiagnostics", "Disk writes"),
    ("appLaunchDiagnostics", "Launch"),
]

# The text segment's address in an arm64 iOS app. atos only needs the
# offset to be added to the load address it is told.
LOAD = 0x100000000


def dwarf_files(dsyms):
    found = {}
    for dsym in pathlib.Path(dsyms).glob("*.dSYM"):
        for dwarf in (dsym / "Contents" / "Resources" / "DWARF").glob("*"):
            out = subprocess.run(["dwarfdump", "--uuid", str(dwarf)], capture_output=True, text=True).stdout
            for line in out.splitlines():
                parts = line.split()
                if len(parts) >= 2 and parts[0] == "UUID:":
                    found[parts[1].upper()] = (dwarf, parts[2].strip("()") if len(parts) > 2 else "arm64")
    return found


def frames(node, depth=0):
    yield depth, node
    for child in node.get("subFrames", []):
        yield from frames(child, depth + 1)


def names(dwarf, arch, offsets):
    if not offsets:
        return {}
    addresses = [hex(LOAD + o) for o in offsets]
    out = subprocess.run(["atos", "-arch", arch, "-o", str(dwarf), "-l", hex(LOAD), *addresses],
                         capture_output=True, text=True).stdout.splitlines()
    return dict(zip(offsets, out))


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    report = json.loads(pathlib.Path(sys.argv[1]).read_text())
    dwarfs = dwarf_files(sys.argv[2])
    for key, label in KINDS:
        for diagnostic in report.get(key, []):
            meta = diagnostic.get("diagnosticMetaData", {})
            print(f"== {label} (build {meta.get('appBuildVersion', '?')}, {meta.get('osVersion', '?')})")
            for field in ("terminationReason", "hangDuration", "exceptionType", "signal"):
                if field in meta:
                    print(f"   {field}: {meta[field]}")
            tree = diagnostic.get("callStackTree", {})
            for n, stack in enumerate(tree.get("callStacks", [])):
                roots = stack.get("callStackRootFrames", [])
                every = [f for root in roots for f in frames(root)]
                lookups = {}
                for _, frame in every:
                    uuid = frame.get("binaryUUID", "").upper()
                    if uuid in dwarfs:
                        lookups.setdefault(uuid, set()).add(frame.get("offsetIntoBinaryTextSegment", 0))
                resolved = {}
                for uuid, offsets in lookups.items():
                    dwarf, arch = dwarfs[uuid]
                    for offset, name in names(dwarf, arch, sorted(offsets)).items():
                        resolved[(uuid, offset)] = name
                marker = " (crashed)" if stack.get("threadAttributed") else ""
                print(f"-- thread {n}{marker}")
                for depth, frame in every:
                    uuid = frame.get("binaryUUID", "").upper()
                    offset = frame.get("offsetIntoBinaryTextSegment", 0)
                    name = resolved.get((uuid, offset)) or f"{frame.get('binaryName', '?')} + {hex(offset)}"
                    print(f"   {'  ' * min(depth, 30)}{name}")
            print()


if __name__ == "__main__":
    main()
