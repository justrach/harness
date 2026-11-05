#!/usr/bin/env bash
# Run a heavy build or test command, one at a time across every process on
# this machine: scripts/heavy-build.sh cargo test -p harness-ui --lib
# Several agents can work in parallel worktrees; only their builds queue.

set -uo pipefail

lock="${HARNESS_HEAVY_BUILD_LOCK:-${TMPDIR:-/tmp}/harness-heavy-build.lock}"
# The engine supplies a per-run directory; marker names are wrapper PIDs and
# contents are Unix seconds of the first failed lock attempt, not the last poll.
wait_marker=""
lock_owned=false
poll_pid=""
cleanup() {
  if [[ -n "$poll_pid" ]]; then
    kill "$poll_pid" 2>/dev/null || true
    wait "$poll_pid" 2>/dev/null || true
  fi
  if [[ -n "$wait_marker" ]]; then
    rm -f "$wait_marker"
  fi
  # In particular, a cancelled waiter must never remove the active owner's lock.
  if "$lock_owned"; then
    rm -rf "$lock"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

until mkdir "$lock" 2>/dev/null; do
  if [[ -z "$wait_marker" && -n "${HARNESS_BUILD_WAIT_DIR:-}" ]]; then
    wait_marker="$HARNESS_BUILD_WAIT_DIR/$$"
    # Optional status reporting must not prevent the command from running.
    # Only the engine creates this directory; do not resurrect a retired run.
    (date +%s >"$wait_marker") 2>/dev/null || true
  fi
  # A lock whose owner has exited is stale.
  owner="$(cat "$lock/pid" 2>/dev/null || true)"
  if [[ -n "$owner" ]] && ! kill -0 "$owner" 2>/dev/null; then
    rm -rf "$lock"
    continue
  fi
  # Override only for synthetic tests. Background sleep makes queued signal
  # handling prompt even with the normal five-second polling interval.
  sleep "${HARNESS_HEAVY_BUILD_POLL_INTERVAL:-5}" &
  poll_pid=$!
  wait "$poll_pid"
  poll_pid=""
done
lock_owned=true
if [[ -n "$wait_marker" ]]; then
  rm -f "$wait_marker"
  wait_marker=""
fi
echo $$ >"$lock/pid"
"$@"
