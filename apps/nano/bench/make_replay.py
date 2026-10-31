#!/usr/bin/env python3
"""A deterministic transcript replay for the resource comparison: the
engine's own frames (`TranscriptFrame`, crates/doc/src/transcript_delta.rs),
a user prompt and then a long Markdown reply streamed as text appends, as
`scripts/resource-profile.mjs` records them. Made-up content only.

    python3 bench/make_replay.py > bench/replay.json
"""
import json
import random
import sys

SECTIONS = 40
CHUNK = 24          # characters per append (HARNESS_MOCK_CHARS)
EVERY_MS = 20       # between appends (HARNESS_MOCK_DELAY_MS)
WORDS = ("ownership borrow lifetime move clone reference slice vector string "
         "stack heap drop scope mutable immutable trait generic iterator closure "
         "pattern match enum struct module crate thread channel arc mutex").split()

rng = random.Random(42)


def paragraph(n):
    return " ".join(rng.choice(WORDS) for _ in range(n)).capitalize() + "."


def reply():
    out = []
    for i in range(1, SECTIONS + 1):
        out.append(f"## {i}. {paragraph(3)[:-1].title()}\n\n{paragraph(60)}\n\n"
                   f"```rust\nfn section_{i}(v: &Vec<u32>) -> u32 {{\n    v.iter().sum::<u32>() + {i}\n}}\n```\n")
    return "\n".join(out)


def entry(eid, role, pid, text, at, status=None):
    e = {"id": eid, "role": role, "parts": [{"kind": "text", "id": pid, "text": text}],
         "createdAt": 1793000000000 + at, "deviceId": "local"}
    if status:
        e["status"] = status
    return e


def main():
    text = reply()
    frames = [{"at": 0, "frame": {"reset": [entry("u1", "user", "p0", "Write a tutorial of Rust ownership in 40 sections.", 0)]}}]
    t = 500
    frames.append({"at": t, "frame": {"upsert": [{"after": "u1", "entry": entry("a1", "assistant", "t1", "", t, "streaming")}],
                                      "append": [], "remove": [], "count": 2}})
    sent = 0
    while sent < len(text):
        t += EVERY_MS
        chunk = text[sent:sent + CHUNK]
        sent += len(chunk)
        frames.append({"at": t, "frame": {"upsert": [], "remove": [], "count": 2,
                                          "append": [{"entry": "a1", "part": "t1", "text": chunk,
                                                      "len": len(text[:sent].encode())}]}})
    t += EVERY_MS
    frames.append({"at": t, "frame": {"upsert": [{"after": "u1", "entry": entry("a1", "assistant", "t1", text, 500, "complete")}],
                                      "append": [], "remove": [], "count": 2}})
    json.dump(frames, sys.stdout)


if __name__ == "__main__":
    main()
