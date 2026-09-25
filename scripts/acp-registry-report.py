#!/usr/bin/env python3
"""Compare Harness's agent adapters with the public ACP registry.

Reports (1) adapter pins that trail the registry's current release and
(2) registry agents Harness has no adapter for, with the distribution an
`AcpAgentSpec` would install (see docs/adr/0004-acp-registry-agents.md).

Usage: scripts/acp-registry-report.py [registry.json]
Without an argument it fetches the live registry. Read-only: it never edits
pins; bump them by hand after testing the new agent release.
"""
import json
import pathlib
import re
import sys
import urllib.request

REGISTRY_URL = "https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json"
ROOT = pathlib.Path(__file__).resolve().parent.parent
ACP_SPECS = ROOT / "crates/harness/src/acp/mod.rs"
CURSOR = ROOT / "crates/harness/src/cursor/mod.rs"

# Registry ids Harness already drives: native drivers and hand-written ACP specs.
COVERED = {
    "claude-acp": "Claude Code (native driver)",
    "codex-acp": "Codex (native driver)",
    "cursor": "Cursor (native @cursor/sdk shim)",
    "opencode": "OpenCode (native HTTP/SSE driver)",
    "devin": "Devin (ACP spec, `devin acp`)",
    "grok-build": "Grok (ACP spec)",
    "pi-acp": "Pi (ACP spec via pi-acp)",
    "antigravity-acp": "Antigravity (ACP spec, pinned archive)",
}


def load_registry():
    if len(sys.argv) > 1:
        return json.loads(pathlib.Path(sys.argv[1]).read_text())
    with urllib.request.urlopen(REGISTRY_URL, timeout=20) as response:
        return json.load(response)


def version_key(version):
    return tuple(int(part) if part.isdigit() else part for part in re.split(r"[.\-+]", version))


def harness_pins():
    """(registry id, pinned version, where) for each pin we can map."""
    specs = ACP_SPECS.read_text()
    pins = []
    npm_to_registry = {"@xai-official/grok": "grok-build", "pi-acp": "pi-acp"}
    for package, version in re.findall(r'npm_package: Some\("(@?[^@"]+)@([^"]+)"\)', specs):
        if package in npm_to_registry:
            pins.append((npm_to_registry[package], version, f"npm_package {package}"))
    archive = re.search(r'ArchivePin \{[^}]*?version: "([^"]+)"', specs, re.S)
    if archive:
        pins.append(("antigravity-acp", archive.group(1), "antigravity ArchivePin"))
    cursor = re.search(r'CURSOR_SDK_PIN: &str = "@cursor/sdk@([^"]+)"', CURSOR.read_text())
    if cursor:
        pins.append(("cursor-sdk", cursor.group(1), "CURSOR_SDK_PIN (not in the ACP registry)"))
    return pins


def distribution(agent):
    dist = agent["distribution"]
    for kind in ("npx", "uvx"):
        if kind in dist:
            spec = dist[kind]
            return f"{kind} {spec['package']} {' '.join(spec.get('args', []))}".strip()
    if "binary" in dist:
        platforms = sorted(dist["binary"])
        return f"binary archive ({len(platforms)} platforms: {', '.join(platforms)})"
    return "unknown"


def main():
    registry = load_registry()
    agents = {agent["id"]: agent for agent in registry["agents"]}
    print(f"# ACP registry report\n\nRegistry {registry.get('version')}, {len(agents)} agents.\n")

    print("## Adapter pins\n")
    print("| Agent | Harness pin | Registry | Where |")
    print("| --- | --- | --- | --- |")
    for agent_id, pinned, where in harness_pins():
        current = agents.get(agent_id, {}).get("version", "—")
        behind = current != "—" and version_key(pinned) < version_key(current)
        flag = " **behind**" if behind else ""
        print(f"| {agent_id} | {pinned} | {current}{flag} | {where} |")

    print("\n## Already driven by Harness\n")
    for agent_id, how in COVERED.items():
        state = "listed" if agent_id in agents else "not in registry"
        print(f"- `{agent_id}` ({state}): {how}")

    missing = [agent for agent_id, agent in sorted(agents.items()) if agent_id not in COVERED]
    print(f"\n## In the registry, no Harness adapter ({len(missing)})\n")
    print("| Id | Name | Version | Distribution |")
    print("| --- | --- | --- | --- |")
    for agent in missing:
        print(f"| {agent['id']} | {agent['name']} | {agent['version']} | {distribution(agent)} |")


if __name__ == "__main__":
    main()
