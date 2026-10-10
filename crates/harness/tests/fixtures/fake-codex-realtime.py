#!/usr/bin/env python3
"""Offline `codex app-server` for dictation tests: answers the realtime handshake
and plays a scripted transcript. Never touches the network."""
import json, os, sys, time
log = open(os.environ["FAKE_DICTATION_LOG"], "a")
mode = os.environ.get("FAKE_DICTATION_MODE", "")
def out(v):
    sys.stdout.write(json.dumps(v) + "\n"); sys.stdout.flush()
def note(method, **params):
    out({"jsonrpc": "2.0", "method": method, "params": dict(threadId="thr-1", **params)})
for line in sys.stdin:
    msg = json.loads(line)
    method = msg.get("method")
    log.write(json.dumps(msg) + "\n"); log.flush()
    if "id" not in msg:
        continue
    reply = lambda result: out({"jsonrpc": "2.0", "id": msg["id"], "result": result})
    if method == "initialize":
        reply({"userAgent": "fixture"})
    elif method == "thread/start":
        reply({"thread": {"id": "thr-1"}})
    elif method == "thread/realtime/start":
        if mode == "fail-start":
            out({"jsonrpc": "2.0", "id": msg["id"], "error": {"code": -32000, "message": "not signed in"}})
            continue
        # The start rules real Codex enforces (core/src/realtime_conversation.rs).
        p = msg["params"]
        version = p.get("version", "v1")
        # A missing field fails the request; the rest is accepted, then refused
        # as a realtime error.
        if "outputModality" not in p:
            out({"jsonrpc": "2.0", "id": msg["id"], "error": {"code": -32600, "message": "Invalid request: missing field `outputModality`"}})
            continue
        refusal = None
        if p.get("transport", {}).get("type") == "webrtc" and version == "v2":
            refusal = "AVAS realtime calls require realtime v1 or v3"
        elif p.get("initialItems") and version != "v3":
            refusal = "initial realtime items require realtime v3"
        elif p["outputModality"] == "text" and version != "v2":
            refusal = "text realtime output modality requires realtime v2"
        if refusal:
            reply({})
            note("thread/realtime/error", message=refusal)
            continue
        reply({})
        note("thread/realtime/started", version="v3", realtimeSessionId=msg["params"]["realtimeSessionId"])
        note("thread/realtime/sdp", sdp="fixture-answer")
        time.sleep(0.3)
        note("thread/realtime/transcript/delta", role="user", delta="hello ")
        note("thread/realtime/transcript/delta", role="user", delta="world")
        note("thread/realtime/transcript/delta", role="assistant", delta="Sure, I can")
        note("thread/realtime/item/completed", item={"type": "transcriptSegment", "role": "user", "text": "hello world"})
        note("thread/realtime/transcript/done", role="user", text="hello world")
        note("thread/realtime/item/completed", item={"type": "transcriptSegment", "role": "assistant", "text": "Sure, I can help."})
        note("thread/realtime/transcript/delta", role="user", delta="and more")
    elif method == "thread/realtime/stop":
        reply({})
    else:
        out({"jsonrpc": "2.0", "id": msg["id"], "error": {"code": -32601, "message": "unknown"}})
