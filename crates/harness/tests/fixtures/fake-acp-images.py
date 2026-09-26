#!/usr/bin/env python3
"""Offline ACP fixture: advertises promptCapabilities.image when
FAKE_ACP_IMAGES=1 and records the first session/prompt's blocks to
prompt.json in its working directory. With FAKE_ACP_TURNS=2 the first turn
lingers (so a follow-up can queue) and the second prompt's blocks go to
prompt-2.json. A fixture.json in the working directory overrides both
(tests running in parallel share one environment)."""

import json
import os
import sys
import time


def reply(request, result=None):
    print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result or {}}), flush=True)


images = os.environ.get("FAKE_ACP_IMAGES") == "1"
turns = int(os.environ.get("FAKE_ACP_TURNS", "1"))
if os.path.exists("fixture.json"):
    with open("fixture.json") as f:
        config = json.load(f)
    images = config.get("images", images)
    turns = config.get("turns", turns)
seen = 0
for line in sys.stdin:
    request = json.loads(line)
    method = request.get("method")
    if method == "initialize":
        reply(request, {"protocolVersion": 1, "agentCapabilities": {"promptCapabilities": {"image": images}}})
    elif method == "session/new":
        reply(request, {"sessionId": "s"})
    elif method == "session/prompt":
        seen += 1
        with open("prompt.json" if seen == 1 else f"prompt-{seen}.json", "w") as f:
            json.dump(request["params"]["prompt"], f)
        if seen < turns:
            time.sleep(1)
        reply(request, {"stopReason": "end_turn"})
        if seen >= turns:
            break
    else:
        reply(request)
