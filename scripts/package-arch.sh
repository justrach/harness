#!/usr/bin/env bash
# Arch Linux packaging: produce
#   target/package/harness-<version>-linux-<arch>.pkg.tar.zst
# via a pinned nfpm (scripts/install-nfpm.sh).
#
# Reuses the binary package-linux.sh already built; builds only if missing.
#
# Usage: scripts/package-arch.sh
# Env:   PROFILE=debug to package target/debug/harness; default release.
#        BIN=<path> override the binary (dry-run/testing).
#        NFPM_ARCH=amd64|arm64 override the package arch (default: uname -m).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v cargo >/dev/null 2>&1 || PATH="$HOME/.cargo/bin:$PATH"
PROFILE="${PROFILE:-release}"
VERSION="$(grep -m1 '^version' "$ROOT/Cargo.toml" | sed 's/.*"\(.*\)".*/\1/')"
OUT_DIR="$ROOT/target/package"
PKG="$OUT_DIR/harness-$VERSION-linux-$(uname -m).pkg.tar.zst"

cd "$ROOT"
BIN="${BIN:-$ROOT/target/$PROFILE/harness}"
if [[ ! -x "$BIN" ]]; then
  if [[ "$PROFILE" == "release" ]]; then
    cargo build --release -p harness
  else
    cargo build -p harness
  fi
  BIN="$ROOT/target/$PROFILE/harness"
fi

# pacman arch names: x86_64 / aarch64. nfpm takes amd64 / arm64.
case "$(uname -m)" in
  x86_64)  NFPM_ARCH="${NFPM_ARCH:-amd64}" ;;
  aarch64|arm64) NFPM_ARCH="${NFPM_ARCH:-arm64}" ;;
  *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;;
esac

TOOLS="$OUT_DIR/.tools"
if [[ ! -x "$TOOLS/nfpm" ]]; then
  "$ROOT/scripts/install-nfpm.sh" "$TOOLS" >/dev/null
fi

# nfpm does not expand env vars inside contents entries — render the config.
config="$(mktemp)"
trap 'rm -f "$config"' EXIT
cat >"$config" <<YAML
name: harness
arch: $NFPM_ARCH
platform: linux
version: "$VERSION"
release: "1"
maintainer: Harness maintainers
homepage: https://github.com/justrach/harness
description: One native workspace for your coding agents
license: custom

depends:
  - glibc
  - gcc-libs
  - libxcb
  - libxkbcommon
  - libxkbcommon-x11
  - wayland
  - libglvnd
  - vulkan-icd-loader
  - gtk3
  - webkit2gtk-4.1
  - json-glib

contents:
  - src: $BIN
    dst: /usr/bin/harness
    file_info:
      mode: 0755
  - src: $ROOT/dist/harness.desktop
    dst: /usr/share/applications/harness.desktop
  - src: $ROOT/dist/harness.png
    dst: /usr/share/icons/hicolor/1024x1024/apps/harness.png
  - src: $ROOT/dist/harness.svg
    dst: /usr/share/icons/hicolor/scalable/apps/harness.svg
  - src: $ROOT/LICENSE
    dst: /usr/share/licenses/harness/LICENSE
  - src: $ROOT/THIRD_PARTY_NOTICES.md
    dst: /usr/share/licenses/harness/THIRD_PARTY_NOTICES.md
  - src: $ROOT/third_party/licenses/Zeron-MIT.txt
    dst: /usr/share/licenses/harness/Zeron-MIT.txt
  - src: $ROOT/third_party/licenses/CodeGraff-LICENSE.txt
    dst: /usr/share/licenses/harness/CodeGraff-LICENSE.txt
YAML
for f in "$ROOT"/crates/ui/assets/fonts/licenses/*; do
  printf '  - src: %s\n    dst: /usr/share/licenses/harness/fonts/%s\n' \
    "$f" "$(basename "$f")" >>"$config"
done

mkdir -p "$OUT_DIR"
rm -f "$PKG"
"$TOOLS/nfpm" package --config "$config" \
  --packager archlinux --target "$PKG"

echo "packaged: $PKG"
