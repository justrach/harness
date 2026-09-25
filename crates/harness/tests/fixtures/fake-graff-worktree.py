#!/usr/bin/env python3
"""Offline ACP fixture for Graff-owned worktrees: `-w <name>` creates (or
reuses) `.graff/worktrees/<name>` and runs the session there; session/new
reports it as the root `cwd` (pre-`_meta` builds), and session/load only
accepts the checkout the process runs in, like graff 0.0.302.x."""

import json
import os
import sys


def reply(request, result=None, error=None):
    body = {"jsonrpc": "2.0", "id": request["id"]}
    body["error" if error else "result"] = error or result or {}
    print(json.dumps(body), flush=True)


args = sys.argv[1:]
if "-w" in args:
    name = args[args.index("-w") + 1]
    tree = os.path.join(os.getcwd(), ".graff", "worktrees", name)
    os.makedirs(tree, exist_ok=True)
    os.chdir(tree)

for line in sys.stdin:
    request = json.loads(line)
    method = request.get("method")
    if method == "initialize":
        reply(request, {"protocolVersion": 1, "agentCapabilities": {"loadSession": True}})
    elif method == "session/load":
        cwd = request.get("params", {}).get("cwd")
        if cwd and os.path.exists(cwd) and os.path.samefile(cwd, os.getcwd()):
            reply(request)
        else:
            reply(request, error={"code": -32602, "message": "Session workspace does not match the selected workspace"})
    elif method == "session/new":
        reply(request, {"sessionId": "fresh", "cwd": os.getcwd()})
    elif method == "session/prompt":
        reply(request, {"stopReason": "end_turn"})
        break
    else:
        reply(request)
