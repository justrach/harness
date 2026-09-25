#!/usr/bin/env python3
"""Offline ACP fixture: advertises promptCapabilities.image when
FAKE_ACP_IMAGES=1 and records every session/prompt's blocks to prompt.json
in its working directory."""

import json
import os
import sys


def reply(request, result=None):
    print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result or {}}), flush=True)


images = os.environ.get("FAKE_ACP_IMAGES") == "1"
for line in sys.stdin:
    request = json.loads(line)
    method = request.get("method")
    if method == "initialize":
        reply(request, {"protocolVersion": 1, "agentCapabilities": {"promptCapabilities": {"image": images}}})
    elif method == "session/new":
        reply(request, {"sessionId": "s"})
    elif method == "session/prompt":
        with open("prompt.json", "w") as f:
            json.dump(request["params"]["prompt"], f)
        reply(request, {"stopReason": "end_turn"})
        break
    else:
        reply(request)
