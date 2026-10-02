#!/bin/sh
# Run the Codex TUI on Harness's agents: start the bridge, run the TUI, stop the bridge.
#
#   tui/run.sh [codex-tui flags…]
#
# Builds the two binaries on first use (slow: one heavy build at a time).
# Bridge log: one file per run, ${TMPDIR:-/tmp}/harness-tui-bridge.XXXXXX (newest: ls -t)
set -eu

here=$(cd "$(dirname "$0")" && pwd)

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

HARNESS_TUI_BRIDGE_BIN=$bridge_bin HARNESS_TUI_BIN=$tui_bin exec "$here/bin/harness-tui" "$@"
