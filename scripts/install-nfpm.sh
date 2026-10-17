#!/usr/bin/env bash
# Install a pinned nfpm (v2.47.0) into DEST_DIR for Arch package builds.
#
# Usage: scripts/install-nfpm.sh DEST_DIR
# Prints the installed binary path on stdout.

set -euo pipefail

DEST_DIR="${1:?usage: install-nfpm.sh DEST_DIR}"
NFPM_VERSION="2.47.0"

os="$(uname -s)"
machine="$(uname -m)"
case "$machine" in
  x86_64|amd64) arch="x86_64" ;;
  arm64|aarch64) arch="arm64" ;;
  *) echo "unsupported arch: $machine" >&2; exit 1 ;;
esac

asset="nfpm_${NFPM_VERSION}_${os}_${arch}.tar.gz"
case "${os}_${arch}" in
  Linux_x86_64)  want="0660ca602b2d2d2ae4781a06c692b3eeb9d437ffea05b831d76e41f4a3188783" ;;
  Linux_arm64)   want="1c0f5f2999b9a974bfb04fdb0cc3306096de530ac5dbb25d739cc5f5219c919c" ;;
  Darwin_arm64)  want="e8c9d1d9ac218eeed479375143dc46b8d51a2b8dbba8e2f9f15ecc8faa2e404b" ;;
  Darwin_x86_64) want="2b04108f8757313dde92ed729560845aadfb7782887eb6988a5dd96f9c146861" ;;
  *) echo "unsupported platform: ${os}_${arch}" >&2; exit 1 ;;
esac

if command -v sha256sum >/dev/null 2>&1; then
  digest() { sha256sum "$1" | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then
  digest() { shasum -a 256 "$1" | cut -d' ' -f1; }
else
  echo "need sha256sum or shasum" >&2; exit 1
fi

mkdir -p "$DEST_DIR"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

url="https://github.com/goreleaser/nfpm/releases/download/v${NFPM_VERSION}/${asset}"
curl -fsSL "$url" -o "$tmp/nfpm.tar.gz"
got="$(digest "$tmp/nfpm.tar.gz")"
if [[ "$got" != "$want" ]]; then
  echo "sha256 mismatch for $asset: got $got, want $want" >&2
  exit 1
fi

tar -xzf "$tmp/nfpm.tar.gz" -C "$tmp" nfpm
install -m 755 "$tmp/nfpm" "$DEST_DIR/nfpm"

"$DEST_DIR/nfpm" --version | grep -q "$NFPM_VERSION" \
  || { echo "nfpm --version does not report $NFPM_VERSION" >&2; exit 1; }
echo "$DEST_DIR/nfpm"
