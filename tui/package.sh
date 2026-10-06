#!/bin/sh
# Build the TUI and bridge and pack them as a tarball: tui/dist/harness-tui-<version>-<os>-<arch>.tar.gz
#
#   tui/package.sh            # release build (slow: one heavy build at a time)
#   PROFILE=debug tui/package.sh   # pack the debug binaries, for checking the layout
#
# Layout: bin/harness-tui (the wrapper) plus bin/graff-tui -> harness-tui (the name `graff tui`
# looks up beside graff or on PATH), libexec/harness-tui, libexec/harness-tui-bridge.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
profile=${PROFILE:-release}
version=$(python3 - "$here/../Cargo.toml" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
section = text.split("[workspace.package]", 1)[1]
print(re.search(r'^version\s*=\s*"([^"]+)"', section, re.M).group(1))
PY
)
os=$(uname -s | tr '[:upper:]' '[:lower:]')
case "$os" in darwin) os=macos ;; esac
arch=$(uname -m)
case "$arch" in arm64) arch=aarch64 ;; esac
name=harness-tui-$version-$os-$arch

[ -d "$here/codex/.git" ] || "$here/setup.sh"

flag=--release
[ "$profile" = release ] || flag=
(cd "$here/bridge" && cargo build $flag)
(cd "$here/launcher" && cargo build $flag --bin harness-tui)

stage=$here/dist/$name
rm -rf "$stage"
mkdir -p "$stage/bin" "$stage/libexec"
cp "$here/bin/harness-tui" "$stage/bin/"
ln -s harness-tui "$stage/bin/graff-tui"
cp "$here/bridge/target/$profile/harness-tui-bridge" "$here/launcher/target/$profile/harness-tui" "$stage/libexec/"
cp "$here/../LICENSE"* "$stage/" 2>/dev/null || true
tar -C "$here/dist" -czf "$here/dist/$name.tar.gz" "$name"
rm -rf "$stage"
echo "$here/dist/$name.tar.gz"
