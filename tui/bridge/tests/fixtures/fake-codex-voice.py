#!/usr/bin/env python3
"""Offline `codex app-server` for the voice relay test: hosts a realtime session
on a shadow thread, then hands work off the way Codex does (a turn with a
<realtime_delegation> input). Logs every request it receives."""
import json, os, sys, time
log = open(os.environ["FAKE_VOICE_LOG"], "a")
def out(v):
    sys.stdout.write(json.dumps(v) + "\n"); sys.stdout.flush()
def note(method, **params):
    out({"jsonrpc": "2.0", "method": method, "params": params})
delegation = [{"type": "text", "text": "<realtime_delegation>run the tests</realtime_delegation>"}]
for line in sys.stdin:
    msg = json.loads(line)
    log.write(json.dumps(msg) + "\n"); log.flush()
    if "id" not in msg:
        continue
    method = msg["method"]
    reply = lambda result: out({"jsonrpc": "2.0", "id": msg["id"], "result": result})
    if method == "initialize":
        reply({"userAgent": "fixture"})
    elif method == "thread/start":
        reply({"thread": {"id": "shadow-1"}})
    elif method == "thread/realtime/listVoices":
        reply({"voices": {"v1": ["cedar"]}})
    elif method == "thread/realtime/start":
        assert msg["params"]["threadId"] == "shadow-1", msg
        reply({})
        note("thread/realtime/started", threadId="shadow-1", version="v3")
        note("thread/realtime/sdp", threadId="shadow-1", sdp="fixture-answer")
        note("thread/realtime/transcript/delta", threadId="shadow-1", role="user", delta="run the tests")
        time.sleep(0.2)
        note("turn/started", threadId="shadow-1", turn={"id": "shadow-turn", "items": [], "status": "inProgress"})
        note("item/started", threadId="shadow-1", turnId="shadow-turn", startedAtMs=0,
             item={"type": "userMessage", "id": "u1", "content": delegation})
        note("item/agentMessage/delta", threadId="shadow-1", turnId="shadow-turn", itemId="a1", delta="I'll run")
    elif method == "turn/interrupt":
        reply({})
    elif method == "thread/realtime/stop":
        reply({})
    else:
        out({"jsonrpc": "2.0", "id": msg["id"], "error": {"code": -32601, "message": "unknown " + method}})
