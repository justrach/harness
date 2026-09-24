#!/usr/bin/env python3
"""Offline ACP fixture: a hosted workspace must not be auto-isolated."""

import json
import os
import sys


def reply(request, result=None, error=None):
    body = {"jsonrpc": "2.0", "id": request["id"]}
    body["error" if error else "result"] = error or result or {}
    print(json.dumps(body), flush=True)


for line in sys.stdin:
    request = json.loads(line)
    method = request.get("method")
    if method == "initialize":
        reply(request, {"protocolVersion": 1, "agentCapabilities": {"loadSession": True}})
    elif method == "session/load":
        params = request.get("params", {})
        cwd = params.get("cwd")
        if (
            os.environ.get("GRAFF_AUTO_ISOLATE") == "0"
            and cwd
            and os.path.samefile(cwd, os.getcwd())
        ):
            reply(request)
        else:
            reply(request, error={"code": -32602, "message": "Session workspace does not match the selected workspace"})
    elif method == "session/new":
        reply(request, {"sessionId": "fresh"})
    elif method == "session/prompt":
        reply(request, {"stopReason": "end_turn"})
        break
    else:
        reply(request)
