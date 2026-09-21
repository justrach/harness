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
    if method is None and ident == 900:
        assert frame["result"]["outcome"]["outcome"] == "cancelled", frame
        update("foreign permission rejected")
        emit({"id": pending, "result": {"stopReason": "end_turn"}})
    elif method == "initialize":
        emit({"id": ident, "result": {"protocolVersion": 1, "agentCapabilities": {}}})
    elif method == "session/new":
        for index in range(40):
            emit({"method": "session/update", "params": {"sessionId": f"foreign-{index}", "update": {
                "sessionUpdate": "current_mode_update", "currentModeId": "wrong"}}})
        for kind, key, value in [
            ("available_commands_update", "availableCommands", [{"name": "early", "description": "Early command"}]),
            ("config_option_update", "configOptions", []),
            ("current_mode_update", "currentModeId", "plan"),
        ]:
            emit({"method": "session/update", "params": {"sessionId": "parent", "update": {
                "sessionUpdate": kind, key: value}}})
        emit({"id": ident, "result": {"sessionId": "parent"}})
    elif method == "session/prompt":
        prompt = frame["params"]["prompt"][0]["text"]
        if prompt == "foreign":
            pending = ident
            emit({"method": "_x.ai/session/prompt_complete", "params": {"sessionId": "child", "stopReason": "end_turn"}})
            emit({"method": "_x.ai/session_notification", "params": {"sessionId": "child", "update": {
                "sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "foreign"}}}})
            emit({"method": "session/update", "params": {"sessionId": "child", "update": {
                "sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "foreign"}}}})
            emit({"id": 900, "method": "session/request_permission", "params": {"sessionId": "child", "options": [
                {"optionId": "allow", "kind": "allow_once", "name": "Allow"}]}})
            continue
        if prompt == "frames":
            print("diagnostic noise", flush=True)
            for noise in [None, 42, [], "plain", {"unrelated": True}]:
                emit(noise)
            update("x" * (2 * 1024 * 1024))
        elif prompt == "burst":
            for index in range(300):
                update(f"{index},")
        emit({"id": ident, "result": {"stopReason": "end_turn"}})
