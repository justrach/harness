#!/usr/bin/env bash
# Build and run an isolated macOS development bundle. It shares the product
# bundle id (harness.codegraff.app) and keeps its own data directory and
# engine IPC port.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v cargo >/dev/null 2>&1 || PATH="$HOME/.cargo/bin:$PATH"
VERSION="$(grep -m1 '^version' "$ROOT/Cargo.toml" | sed 's/.*"\(.*\)".*/\1/')"
DEV_ROOT="$ROOT/target/macos-dev"
APP="$DEV_ROOT/Harness.app"
CONTENTS="$APP/Contents"
DATA_DIR="${HARNESS_DEV_DATA_DIR:-${ZERON_DEV_DATA_DIR:-$DEV_ROOT/data}}"
IPC_PORT="${HARNESS_DEV_IPC_PORT:-${ZERON_DEV_IPC_PORT:-49777}}"

if pgrep -f -x "$CONTENTS/MacOS/harness" >/dev/null 2>&1; then
  echo "Harness is already running. Quit it before rebuilding the signed bundle." >&2
  exit 1
fi

cd "$ROOT"
# `app-dev` optimizes the workspace crates so the bundle renders at release-
# like cost; HARNESS_DEV_PROFILE=dev trades that for the fastest rebuilds.
PROFILE="${HARNESS_DEV_PROFILE:-app-dev}"
cargo build -p harness --profile "$PROFILE"
TARGET_DIR="$(cargo metadata --format-version 1 --no-deps | sed -n 's/.*"target_directory":"\([^"]*\)".*/\1/p')"
[[ "$PROFILE" == "dev" ]] && PROFILE_DIR=debug || PROFILE_DIR="$PROFILE"

mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$DATA_DIR"
install -m 755 "$TARGET_DIR/$PROFILE_DIR/harness" "$CONTENTS/MacOS/harness"
sed "s/__VERSION__/$VERSION/g" "$ROOT/dist/macos/Info-dev.plist" >"$CONTENTS/Info.plist"
plutil -replace LSEnvironment.HARNESS_DATA_DIR -string "$DATA_DIR" "$CONTENTS/Info.plist"
plutil -replace LSEnvironment.HARNESS_IPC_PORT -string "$IPC_PORT" "$CONTENTS/Info.plist"
plutil -replace LSEnvironment.ZERON_DATA_DIR -string "$DATA_DIR" "$CONTENTS/Info.plist"
plutil -replace LSEnvironment.ZERON_IPC_PORT -string "$IPC_PORT" "$CONTENTS/Info.plist"

if [[ ! -f "$CONTENTS/Resources/zeron.icns" || "$ROOT/dist/macos/icon-1024.png" -nt "$CONTENTS/Resources/zeron.icns" ]]; then
  ICONSET="$DEV_ROOT/zeron-dev.iconset"
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ROOT/dist/macos/icon-1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    retina=$((size * 2))
    sips -z "$retina" "$retina" "$ROOT/dist/macos/icon-1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  rm -f "$CONTENTS/Resources/zeron.icns"
  iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/zeron.icns"
fi

# A real Apple Development identity gives TCC a stable signing requirement
# across rebuilds. Set ZERON_DEV_CODESIGN_IDENTITY explicitly when more than
# one identity is installed; otherwise fall back to an ad-hoc signature.
IDENTITY="${HARNESS_DEV_CODESIGN_IDENTITY:-${ZERON_DEV_CODESIGN_IDENTITY:-}}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -1)"
fi
if [[ -n "$IDENTITY" ]]; then
  codesign --force --sign "$IDENTITY" --identifier harness.codegraff.app "$APP"
else
  codesign --force --sign - --identifier harness.codegraff.app "$APP"
  echo "warning: no Apple Development signing identity found; macOS may ask for permissions again after a rebuild" >&2
fi

echo "running Harness (bundle harness.codegraff.app, data $DATA_DIR, IPC $IPC_PORT)" >&2
# LaunchServices must own the process. Launching Contents/MacOS/harness directly
# makes TCC attribute Screen Recording to the terminal (Warp, Terminal, etc.).
# -W keeps the script attached until the app exits. Runtime logs remain in the
# isolated data directory (`target/macos-dev/data/logs/zeron-headed.log`).
OPEN_ENV=(
  --env "HARNESS_DATA_DIR=$DATA_DIR"
  --env "HARNESS_IPC_PORT=$IPC_PORT"
  --env "ZERON_DATA_DIR=$DATA_DIR"
  --env "ZERON_IPC_PORT=$IPC_PORT"
)
if [[ -n "${HARNESS_OPEN_ROUTE:-${ZERON_OPEN_ROUTE:-}}" ]]; then
  OPEN_ENV+=(--env "HARNESS_OPEN_ROUTE=${HARNESS_OPEN_ROUTE:-$ZERON_OPEN_ROUTE}")
fi
exec open -W "${OPEN_ENV[@]}" "$APP" --args "$@"
