#!/bin/sh
# Run the Codex TUI on Harness's agents: start the bridge, run the TUI, stop the bridge.
#
#   tui/run.sh [codex-tui flags…]
#
# Builds the two binaries on first use (slow: one heavy build at a time).
# Bridge log: one file per run, ${TMPDIR:-/tmp}/harness-tui-bridge.XXXXXX (newest: ls -t)
set -eu

here=$(cd "$(dirname "$0")" && pwd)

# The TUI saves its defaults (chosen model, effort) to config.toml in CODEX_HOME. Keep that apart
# from ~/.codex: the model ids saved here are Harness ids, which a real `codex` CLI cannot run.
export CODEX_HOME=${CODEX_HOME:-$HOME/.harness/tui/codex-home}
mkdir -p "$CODEX_HOME"
bridge_bin=$here/bridge/target/debug/harness-tui-bridge
tui_bin=$here/launcher/target/debug/harness-tui

[ -d "$here/codex/.git" ] || "$here/setup.sh"

if [ ! -x "$bridge_bin" ]; then
  echo "building the bridge (first run)…" >&2
  (cd "$here/bridge" && cargo build)
fi
if [ ! -x "$tui_bin" ]; then
  echo "building the TUI (first run, several minutes)…" >&2
  (cd "$here/launcher" && CARGO_PROFILE_DEV_DEBUG=line-tables-only cargo build --bin harness-tui)
fi

port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
log=$(mktemp "${TMPDIR:-/tmp}/harness-tui-bridge.XXXXXX")
"$bridge_bin" "127.0.0.1:$port" >"$log" 2>&1 &
bridge_pid=$!
trap 'kill "$bridge_pid" 2>/dev/null || true' EXIT INT TERM

i=0
until nc -z 127.0.0.1 "$port" </dev/null >/dev/null 2>&1; do
  i=$((i + 1))
  if [ "$i" -gt 100 ] || ! kill -0 "$bridge_pid" 2>/dev/null; then
    echo "bridge did not start; see $log" >&2
    exit 1
  fi
  sleep 0.1
done

HARNESS_TUI_BRIDGE="ws://127.0.0.1:$port" "$tui_bin" "$@"
