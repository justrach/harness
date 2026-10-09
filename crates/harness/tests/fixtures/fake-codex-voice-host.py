#!/usr/bin/env python3
"""Offline Codex voice helper: length-prefixed controls; never opens hardware or network.
Adapted from upstream zeronsh/zeron (MIT)."""
import json, os, pathlib, struct, sys
if sys.argv[1:] == ["--build-commit"]:
    print("fixture-build"); sys.exit(0)
# Launched with a cleared environment: log beside the test's codex-resources tree.
log = open(pathlib.Path(__file__).resolve().parents[3] / "helper.jsonl", "a")
def receive():
    header = sys.stdin.buffer.read(4)
    if len(header) < 4: return None
    return json.loads(sys.stdin.buffer.read(struct.unpack(">I", header)[0]))
def send(v):
    b = json.dumps(v).encode(); sys.stdout.buffer.write(struct.pack(">I", len(b)) + b); sys.stdout.buffer.flush()
while (frame := receive()) is not None:
    log.write(json.dumps(frame) + "\n"); log.flush()
    kind = frame["type"]
    if kind == "hello":
        assert frame == {"type": "hello", "protocol": 1, "buildCommit": "fixture-build"}; send({"type": "ready"})
    elif kind == "initializeRuntime": send({"type": "runtimeReady"})
    elif kind == "startTransport": send({"type": "offer", "sdp": "fixture-offer"})
    elif kind == "applyAnswer":
        assert frame["sdp"] == "fixture-answer"; send({"type": "transportReady"})
    elif kind == "openDevices": send({"type": "devicesOpened"})
    elif kind == "setAudioControls": send({"type": "audioControlsApplied"})
    elif kind == "inspectAudio": send({"type": "audioState", "state": {"microphonePeak": 16384, "speakerPeak": 0}})
    elif kind == "close": send({"type": "closed"}); break
    else: raise ValueError("unexpected command")
