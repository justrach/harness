#!/usr/bin/env bash
# Build and run an isolated macOS development bundle ("Harness Dev"). It has
# its own bundle id (harness.codegraff.app.dev), data directory and engine IPC
# port. The id must differ from the release's: macOS privacy keeps one grant
# per bundle id pinned to one signature, so a shared id made a Screen Recording
# grant for this build deny the installed Developer ID app, and vice versa.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v cargo >/dev/null 2>&1 || PATH="$HOME/.cargo/bin:$PATH"
VERSION="$(grep -m1 '^version' "$ROOT/Cargo.toml" | sed 's/.*"\(.*\)".*/\1/')"
BUNDLE_ID="harness.codegraff.app.dev"
DEV_ROOT="$ROOT/target/macos-dev"
APP="$DEV_ROOT/Harness.app"
CONTENTS="$APP/Contents"
DATA_DIR="${HARNESS_DEV_DATA_DIR:-$DEV_ROOT/data}"
IPC_PORT="${HARNESS_DEV_IPC_PORT:-49777}"

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
# Bundle graff like the release does (scripts/package-macos.sh), from
# GRAFF_BINARY or the graff on PATH, so the bundled/managed path is exercised.
GRAFF_SRC="${GRAFF_BINARY:-$(command -v graff || true)}"
if [[ -n "$GRAFF_SRC" ]]; then
  mkdir -p "$CONTENTS/Resources/bin"
  install -m 755 "$GRAFF_SRC" "$CONTENTS/Resources/bin/graff"
fi
sed "s/__VERSION__/$VERSION/g" "$ROOT/dist/macos/Info-dev.plist" >"$CONTENTS/Info.plist"
plutil -replace LSEnvironment.HARNESS_DATA_DIR -string "$DATA_DIR" "$CONTENTS/Info.plist"
plutil -replace LSEnvironment.HARNESS_IPC_PORT -string "$IPC_PORT" "$CONTENTS/Info.plist"

if [[ ! -f "$CONTENTS/Resources/harness.icns" || "$ROOT/dist/macos/icon-1024.png" -nt "$CONTENTS/Resources/harness.icns" ]]; then
  ICONSET="$DEV_ROOT/harness-dev.iconset"
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ROOT/dist/macos/icon-1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    retina=$((size * 2))
    sips -z "$retina" "$retina" "$ROOT/dist/macos/icon-1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  rm -f "$CONTENTS/Resources/harness.icns"
  iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/harness.icns"
  rm -rf "$ICONSET"
fi

# A real Apple Development identity gives TCC a stable signing requirement
# across rebuilds. Set HARNESS_DEV_CODESIGN_IDENTITY explicitly when more than
# one identity is installed; otherwise fall back to an ad-hoc signature.
IDENTITY="${HARNESS_DEV_CODESIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -1)"
fi
if [[ -n "$IDENTITY" ]]; then
  codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
else
  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
  echo "warning: no Apple Development signing identity found; macOS may ask for permissions again after a rebuild" >&2
fi

# Refresh Launch Services after replacing the signed bundle or its icon.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -f "$APP"

echo "running Harness Dev (bundle $BUNDLE_ID, data $DATA_DIR, IPC $IPC_PORT)" >&2
# LaunchServices must own the process. Launching Contents/MacOS/harness directly
# makes TCC attribute Screen Recording to the terminal (Warp, Terminal, etc.).
# -W keeps the script attached until the app exits. Runtime logs remain in the
# isolated data directory (`target/macos-dev/data/logs/harness-headed.log`).
OPEN_ENV=(
  --env "HARNESS_DATA_DIR=$DATA_DIR"
  --env "HARNESS_IPC_PORT=$IPC_PORT"
)
if [[ -n "${HARNESS_OPEN_ROUTE:-}" ]]; then
  OPEN_ENV+=(--env "HARNESS_OPEN_ROUTE=$HARNESS_OPEN_ROUTE")
fi
exec open -W "${OPEN_ENV[@]}" "$APP" --args "$@"
