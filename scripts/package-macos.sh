#!/usr/bin/env bash
# macOS packaging: build the release binary for the host arch and produce
#   target/package/harness-<version>-macos-<arch>.dmg          (user download)
#   target/package/harness-<version>-macos-<arch>-app.tar.gz   (auto-updater)
# containing Harness.app (unsigned unless CODESIGN_IDENTITY is set).
#
# Usage: scripts/package-macos.sh
# Env:   CODESIGN_IDENTITY="Developer ID Application: …" to sign the bundle.
#        GRAFF_BINARY=/absolute/path/to/graff to bundle an exact CLI build.
#        HARNESS_BINARY=/absolute/path/to/harness to package a tested build
#        without invoking a second Cargo profile (for local preview DMGs).
#        NOTARY_KEY_PATH + NOTARY_KEY_ID + NOTARY_ISSUER_ID — App Store Connect
#        API key (.p8) for notarization; all three set → notarize + staple the
#        app and the dmg, which removes the Gatekeeper warning entirely.
#        NOTARYTOOL_PROFILE — alternatively, a keychain profile saved with
#        `xcrun notarytool store-credentials` (local builds).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v cargo >/dev/null 2>&1 || PATH="$HOME/.cargo/bin:$PATH"
VERSION="$(grep -m1 '^version' "$ROOT/Cargo.toml" | sed 's/.*"\(.*\)".*/\1/')"
ARCH="$(uname -m)" # arm64 on Apple silicon runners
OUT_DIR="$ROOT/target/package"
APP="$OUT_DIR/Harness.app"
DMG="$OUT_DIR/harness-$VERSION-macos-$ARCH.dmg"
APP_TARBALL="$OUT_DIR/harness-$VERSION-macos-$ARCH-app.tar.gz"
if [[ -n "${GRAFF_BINARY:-}" ]]; then
  [[ -x "$GRAFF_BINARY" ]] || { echo "GRAFF_BINARY is not executable" >&2; exit 1; }
fi

cd "$ROOT"
if [[ -n "${HARNESS_BINARY:-}" ]]; then
  [[ -x "$HARNESS_BINARY" ]] || { echo "HARNESS_BINARY is not executable" >&2; exit 1; }
  BUILD_BINARY="$HARNESS_BINARY"
else
  cargo build --release -p harness
  TARGET_DIR="$(cargo metadata --format-version 1 --no-deps | sed -n 's/.*"target_directory":"\([^"]*\)".*/\1/p')"
  BUILD_BINARY="$TARGET_DIR/release/harness"
fi

rm -rf "$APP" "$DMG" "$APP_TARBALL"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
install -m 755 "$BUILD_BINARY" "$APP/Contents/MacOS/harness"
sed "s/__VERSION__/$VERSION/" "$ROOT/dist/macos/Info.plist" >"$APP/Contents/Info.plist"
# graff ships inside the bundle (Contents/Resources/bin/graff): the app seeds
# ~/.harness/bin/graff from it and links `graff` onto the PATH. GRAFF_BINARY
# overrides; otherwise the latest codegraff release, checked against its
# SHA256SUMS. Release builds are already Developer ID signed and notarized.
GRAFF_ARCH="$ARCH"
[[ "$GRAFF_ARCH" == "arm64" ]] && GRAFF_ARCH=aarch64
mkdir -p "$APP/Contents/Resources/bin"
if [[ -n "${GRAFF_BINARY:-}" ]]; then
  install -m 755 "$GRAFF_BINARY" "$APP/Contents/Resources/bin/graff"
else
  GRAFF_ASSET="graff-$GRAFF_ARCH-macos.tar.gz"
  GRAFF_URL="${GRAFF_RELEASES_URL:-https://github.com/justrach/codegraff/releases/latest/download}"
  GRAFF_TMP="$(mktemp -d)"
  curl -fsSL "$GRAFF_URL/$GRAFF_ASSET" -o "$GRAFF_TMP/$GRAFF_ASSET"
  curl -fsSL "$GRAFF_URL/SHA256SUMS" -o "$GRAFF_TMP/SHA256SUMS"
  (cd "$GRAFF_TMP" && grep " $GRAFF_ASSET\$" SHA256SUMS | shasum -a 256 -c -)
  tar -xzf "$GRAFF_TMP/$GRAFF_ASSET" -C "$GRAFF_TMP"
  GRAFF_SRC="$GRAFF_TMP/graff-$GRAFF_ARCH-macos/graff"
  [[ -f "$GRAFF_SRC" ]] || GRAFF_SRC="$GRAFF_TMP/graff"
  install -m 755 "$GRAFF_SRC" "$APP/Contents/Resources/bin/graff"
  rm -rf "$GRAFF_TMP"
fi
echo "bundled $("$APP/Contents/Resources/bin/graff" --version | head -1)"
mkdir -p "$APP/Contents/Resources/licenses/fonts"
cp "$ROOT/crates/ui/assets/fonts/licenses/"* "$APP/Contents/Resources/licenses/fonts/"
cp "$ROOT/LICENSE" "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/"

# Icon: iconset from the pre-masked macOS icon (squircle + margins + shadow
# baked into dist/macos/icon-1024.png — sips can't alpha-mask, so the mask is
# applied ahead of time; dist/harness.png stays the full-bleed shared artwork).
ICONSET="$OUT_DIR/harness.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$ROOT/dist/macos/icon-1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  retina=$((size * 2))
  sips -z "$retina" "$retina" "$ROOT/dist/macos/icon-1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/harness.icns"
rm -rf "$ICONSET"

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  # Hardened runtime + secure timestamp are both notarization requirements.
  # (No --deep: Apple deprecated it; the bundle is a single Mach-O anyway.)
  # graff keeps codegraff's notarized signature unless it isn't Developer ID
  # signed yet (a local GRAFF_BINARY build).
  codesign --verify --strict "$APP/Contents/Resources/bin/graff" 2>/dev/null &&
    codesign -dv "$APP/Contents/Resources/bin/graff" 2>&1 | grep -q "Authority=Developer ID Application" ||
    codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$APP/Contents/Resources/bin/graff"
  codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$APP"
else
  # Ad-hoc signature so the app launches on Apple silicon (Gatekeeper still
  # requires right-click → Open on first launch without notarization).
  codesign --deep --force --sign - "$APP"
fi

# notarize <path>: submit to Apple and wait for the verdict. A rejection may
# still exit 0 depending on the notarytool version — the `stapler staple` that
# follows each call has no ticket to attach then, and fails the build for us.
NOTARY_AUTH=()
if [[ -n "${NOTARY_KEY_PATH:-}" && -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER_ID:-}" ]]; then
  NOTARY_AUTH=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
elif [[ -n "${NOTARYTOOL_PROFILE:-}" ]]; then
  NOTARY_AUTH=(--keychain-profile "$NOTARYTOOL_PROFILE")
fi
notarize() {
  xcrun notarytool submit "$1" "${NOTARY_AUTH[@]}" --wait
}
NOTARIZE=false
[[ ${#NOTARY_AUTH[@]} -gt 0 ]] && NOTARIZE=true
if $NOTARIZE && [[ -z "${CODESIGN_IDENTITY:-}" ]]; then
  echo "notarization requires CODESIGN_IDENTITY (Developer ID Application)" >&2
  exit 1
fi

if $NOTARIZE; then
  # Staple the bundle BEFORE tarring it: the auto-updater swaps the .app with
  # no dmg involved, so the tarball copy must carry its own ticket to pass
  # Gatekeeper offline.
  ZIP="$OUT_DIR/harness-notarize.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
  notarize "$ZIP"
  rm -f "$ZIP"
  xcrun stapler staple "$APP"
fi

# The auto-updater artifact.
tar -czf "$APP_TARBALL" -C "$OUT_DIR" Harness.app
echo "packaged: $APP_TARBALL"

# The dmg presents the classic drag-into-Applications layout over the
# Codegraff workshop artwork (committed renders from scripts/dmg-background.swift).
# dmgbuild writes the .DS_Store (background, icon view, icon positions)
# directly — no Finder scripting, so it also works on headless CI runners.
PY_BIN=python3
if ! python3 -c 'import dmgbuild' 2>/dev/null &&
  ! python3 -m pip install --quiet --user dmgbuild 2>/dev/null &&
  ! python3 -m pip install --quiet --user --break-system-packages dmgbuild 2>/dev/null; then
  # An active virtualenv refuses --user installs; use a throwaway venv.
  python3 -m venv "$OUT_DIR/dmgbuild-venv"
  "$OUT_DIR/dmgbuild-venv/bin/pip" install --quiet dmgbuild
  PY_BIN="$OUT_DIR/dmgbuild-venv/bin/python"
fi

# Pair the 1x/2x background renders into a hidpi tiff so the artwork stays
# crisp on retina displays.
BG_TIFF="$OUT_DIR/dmg-background.tiff"
tiffutil -cathidpicheck "$ROOT/dist/macos/dmg-background.png" \
  "$ROOT/dist/macos/dmg-background@2x.png" -out "$BG_TIFF" >/dev/null 2>&1

APP="$APP" DMG="$DMG" BG_TIFF="$BG_TIFF" "$PY_BIN" - <<'PY'
import os
import dmgbuild

app = os.environ["APP"]
dmgbuild.build_dmg(
    filename=os.environ["DMG"],
    volume_name="Harness",
    settings={
        "format": "UDZO",
        "files": [app],
        "symlinks": {"Applications": "/Applications"},
        "icon": os.path.join(app, "Contents/Resources/harness.icns"),
        "background": os.environ["BG_TIFF"],
        "show_status_bar": False,
        "show_tab_view": False,
        "show_toolbar": False,
        "show_pathbar": False,
        "show_sidebar": False,
        "default_view": "icon-view",
        # Window and icon geometry must match scripts/dmg-background.swift.
        "window_rect": ((200, 120), (660, 400)),
        "icon_size": 104,
        "text_size": 12,
        "icon_locations": {"Harness.app": (165, 195), "Applications": (495, 195)},
    },
)
PY
rm -f "$BG_TIFF"
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  # Gatekeeper assesses the dmg's own signature too, not just the app inside.
  codesign --force --timestamp --sign "$CODESIGN_IDENTITY" "$DMG"
fi
if $NOTARIZE; then
  notarize "$DMG"
  xcrun stapler staple "$DMG"
fi
echo "packaged: $DMG"
