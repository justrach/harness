#!/bin/sh
# Harness (native) headless installer.
#
#   curl -fsSL https://edge.codegraff.com/install.sh | sh
#
# Installs the self-contained native binary (no runtime deps) to
# ~/.harness/app, puts `harness` on PATH, and runs it as a local-only
# systemd user service that survives reboots. Signing in is optional and
# enables sync after a restart. Re-running
# upgrades in place; ~/.harness state is preserved.
#
# The binary ships with production endpoints baked in: no HARNESS_EDGE_URL or
# client-id configuration needed. Overrides (if any) go in ~/.harness/env.
set -eu

# The same feed `harness update` reads: the latest stable GitHub release, whose
# manifest.json carries the version and a sha256 for every artifact.
RELEASES="${HARNESS_RELEASES_URL:-https://github.com/justrach/harness/releases/latest/download}"
RELEASES="${RELEASES%/}"

# --- platform ---------------------------------------------------------------
os="$(uname -s)"
arch="$(uname -m)"
case "$os" in
  Linux) plat=linux ;;
  Darwin)
    echo "harness install: on macOS, download the desktop app instead:" >&2
    echo "  $RELEASES/Harness-macos-arm64.dmg" >&2
    exit 1
    ;;
  *)
    echo "harness install: unsupported OS '$os' — only Linux for now." >&2
    exit 1
    ;;
esac
case "$arch" in
  x86_64 | amd64) arch=x86_64 ;;
  aarch64 | arm64) arch=aarch64 ;;
  *)
    echo "harness install: unsupported architecture '$arch'." >&2
    exit 1
    ;;
esac

# --- download ----------------------------------------------------------------
manifest="$(curl -fsSL "$RELEASES/manifest.json" | tr -d ' \t\r\n')"
ver="$(printf '%s' "$manifest" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')"
[ -n "$ver" ] || { echo "harness install: could not resolve latest version" >&2; exit 1; }
file="harness-$ver-$plat-$arch.tar.gz"
sum="$(printf '%s' "$manifest" | sed -n "s/.*\"$file\":{\"sha256\":\"\([0-9a-f]*\)\".*/\1/p")"
[ -n "$sum" ] || { echo "harness install: release $ver has no checksum for $file" >&2; exit 1; }
data_root="$HOME/.harness"
app_root="$data_root/app"
dest="$app_root/$ver"

if [ -x "$dest/harness" ]; then
  echo "harness $ver already downloaded — relinking."
else
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  echo "downloading harness $ver ($plat-$arch)…"
  curl -fSL --progress-bar "$RELEASES/$file" -o "$tmp/$file"
  if command -v sha256sum >/dev/null 2>&1; then
    got="$(sha256sum "$tmp/$file" | cut -d' ' -f1)"
  else
    got="$(shasum -a 256 "$tmp/$file" | cut -d' ' -f1)"
  fi
  [ "$got" = "$sum" ] || { echo "harness install: $file does not match the release checksum" >&2; exit 1; }
  mkdir -p "$dest"
  tar -xzf "$tmp/$file" -C "$dest" --strip-components=1
fi

ln -sfn "$dest" "$app_root/current"
mkdir -p "$HOME/.local/bin"
ln -sf "$app_root/current/harness" "$HOME/.local/bin/harness"

# --- service -----------------------------------------------------------------
# The daemon is useful before auth: without a saved session it serves the local
# profile. Login only changes which profile the next daemon start selects.

service=manual
if command -v systemctl >/dev/null 2>&1 && [ -n "${XDG_RUNTIME_DIR:-}" ]; then
  mkdir -p "$HOME/.config/systemd/user"
  cat >"$HOME/.config/systemd/user/harness.service" <<'UNIT'
[Unit]
Description=Harness native headless engine
After=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
ExecStart=%h/.harness/app/current/harness headless
Restart=on-failure
RestartSec=5
EnvironmentFile=-%h/.harness/env

[Install]
WantedBy=default.target
UNIT
  systemctl --user daemon-reload
  systemctl --user enable harness
  systemctl --user restart harness
  service=running
  # Keep the user manager (and the engine) running without an active login.
  loginctl enable-linger "$USER" 2>/dev/null \
    || sudo -n loginctl enable-linger "$USER" 2>/dev/null \
    || echo "warn: could not enable linger — the engine stops when you log out (run: sudo loginctl enable-linger $USER)"
else
  echo "warn: systemd user session not available — run the engine manually with: harness headless"
fi

# --- agent CLIs ---------------------------------------------------------------
command -v claude >/dev/null 2>&1 || \
  echo "note: Claude Code CLI not found — install it with: curl -fsSL https://claude.ai/install.sh | bash"

case ":$PATH:" in
  *":$HOME/.local/bin:"*) path_hint="" ;;
  *) path_hint=' (add ~/.local/bin to your PATH)' ;;
esac

echo ""
echo "✓ harness $ver installed$path_hint"
echo ""
case "$service" in
  running)
    echo "the engine is running with the new version (local-only unless sync is enabled)."
    echo "  systemctl --user status harness    check the service"
    echo "  harness update                     install the latest release and restart"
    echo "it also updates itself while no chat or terminal is running"
    echo "(set HARNESS_AUTO_UPDATE=0 in ~/.harness/env to turn that off)."
    echo ""
    echo "optional sync (local sessions stay local):"
    echo "  systemctl --user stop harness"
    echo "  harness login"
    echo "  systemctl --user restart harness"
    ;;
  manual)
    echo "next: run the local-only engine with \`harness headless\`."
    echo "optional sync: run \`harness login\` before starting the engine."
    echo "it updates itself while no chat or terminal is running, and"
    echo "\`harness update\` installs the latest release on demand."
    ;;
esac
