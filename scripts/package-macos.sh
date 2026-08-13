#!/usr/bin/env bash
# macOS packaging: build the release binary for the host arch and produce
#   target/package/comet-<version>-macos-<arch>.dmg          (user download)
#   target/package/comet-<version>-macos-<arch>-app.tar.gz   (auto-updater)
# containing Zeron.app (unsigned unless CODESIGN_IDENTITY is set).
#
# Usage: scripts/package-macos.sh
# Env:   CODESIGN_IDENTITY="Developer ID Application: …" to sign the bundle.
#        NOTARY_KEY_PATH + NOTARY_KEY_ID + NOTARY_ISSUER_ID — App Store Connect
#        API key (.p8) for notarization; all three set → notarize + staple the
#        app and the dmg, which removes the Gatekeeper warning entirely.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v cargo >/dev/null 2>&1 || PATH="$HOME/.cargo/bin:$PATH"
VERSION="$(grep -m1 '^version' "$ROOT/Cargo.toml" | sed 's/.*"\(.*\)".*/\1/')"
ARCH="$(uname -m)" # arm64 on Apple silicon runners
OUT_DIR="$ROOT/target/package"
APP="$OUT_DIR/Zeron.app"
DMG="$OUT_DIR/comet-$VERSION-macos-$ARCH.dmg"
APP_TARBALL="$OUT_DIR/comet-$VERSION-macos-$ARCH-app.tar.gz"

cd "$ROOT"
cargo build --release -p comet

rm -rf "$APP" "$DMG" "$APP_TARBALL"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
install -m 755 "$ROOT/target/release/comet" "$APP/Contents/MacOS/comet"
sed "s/__VERSION__/$VERSION/" "$ROOT/dist/macos/Info.plist" >"$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources/licenses/fonts"
cp "$ROOT/crates/ui/assets/fonts/licenses/"* "$APP/Contents/Resources/licenses/fonts/"

# Icon: iconset from the shared 1024×1024 Zeron artwork in dist/comet.png.
ICONSET="$OUT_DIR/zeron.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$ROOT/dist/comet.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  retina=$((size * 2))
  sips -z "$retina" "$retina" "$ROOT/dist/comet.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/zeron.icns"
rm -rf "$ICONSET"

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  # Hardened runtime + secure timestamp are both notarization requirements.
  # (No --deep: Apple deprecated it; the bundle is a single Mach-O anyway.)
  codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$APP"
else
  # Ad-hoc signature so the app launches on Apple silicon (Gatekeeper still
  # requires right-click → Open on first launch without notarization).
  codesign --deep --force --sign - "$APP"
fi

# notarize <path>: submit to Apple and wait for the verdict. A rejection may
# still exit 0 depending on the notarytool version — the `stapler staple` that
# follows each call has no ticket to attach then, and fails the build for us.
notarize() {
  xcrun notarytool submit "$1" \
    --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" \
    --issuer "$NOTARY_ISSUER_ID" --wait
}
NOTARIZE=false
[[ -n "${NOTARY_KEY_PATH:-}" && -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER_ID:-}" ]] && NOTARIZE=true

if $NOTARIZE; then
  # Staple the bundle BEFORE tarring it: the auto-updater swaps the .app with
  # no dmg involved, so the tarball copy must carry its own ticket to pass
  # Gatekeeper offline. The ticket lives inside the bundle, so the tarball's
  # Zeron.app → Comet.app rename below doesn't disturb it.
  ZIP="$OUT_DIR/zeron-notarize.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
  notarize "$ZIP"
  rm -f "$ZIP"
  xcrun stapler staple "$APP"
fi

# The auto-updater artifact: keep the historical Comet.app path inside the
# tarball so already-installed Comet builds can consume the first Zeron
# release. The DMG still presents Zeron.app to new installs.
tar -czf "$APP_TARBALL" -s '/^Zeron\.app/Comet.app/' -C "$OUT_DIR" Zeron.app
echo "packaged: $APP_TARBALL"

hdiutil create -volname Zeron -srcfolder "$APP" -ov -format UDZO "$DMG"
if $NOTARIZE; then
  notarize "$DMG"
  xcrun stapler staple "$DMG"
fi
echo "packaged: $DMG"
