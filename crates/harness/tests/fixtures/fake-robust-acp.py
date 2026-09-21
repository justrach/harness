#!/usr/bin/env python3
"""ACP wire edge cases shared by adapter specifications."""
import json
import sys


def emit(frame):
    sys.stdout.write(json.dumps(frame) + "\r\n")
    sys.stdout.flush()


def update(text):
    emit({"method": "session/update", "params": {"sessionId": "parent", "update": {
        "sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}}}})


for line in sys.stdin:
    frame = json.loads(line)
    method = frame.get("method")
    ident = frame.get("id")
    if method == "initialize":
        emit({"id": ident, "result": {"protocolVersion": 1, "agentCapabilities": {}}})
    elif method == "session/new":
        emit({"id": ident, "result": {"sessionId": "parent"}})
    elif method == "session/prompt":
        prompt = frame["params"]["prompt"][0]["text"]
        if prompt == "frames":
            print("diagnostic noise", flush=True)
            for noise in [None, 42, [], "plain", {"unrelated": True}]:
                emit(noise)
            update("x" * (2 * 1024 * 1024))
        emit({"id": ident, "result": {"stopReason": "end_turn"}})
