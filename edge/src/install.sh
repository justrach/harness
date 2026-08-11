#!/bin/sh
# Comet (native) headless installer.
#
#   curl -fsSL https://comet.zeron.sh/install.sh | sh
#
# Installs the self-contained native binary (no runtime deps) to
# ~/.comet-native/app, puts `comet` on PATH, and runs it as a local-only
# systemd user service that survives reboots. Signing in is optional and
# enables sync after a restart. Re-running
# upgrades in place; ~/.comet-native state is preserved.
#
# The binary ships with production endpoints baked in: no COMET_EDGE_URL or
# client-id configuration needed. Overrides (if any) go in ~/.comet-native/env.
set -eu

BASE="${COMET_BASE_URL:-https://comet.zeron.sh}"

# --- platform ---------------------------------------------------------------
os="$(uname -s)"
arch="$(uname -m)"
case "$os" in
  Linux) plat=linux ;;
  Darwin)
    echo "comet install: on macOS, download the desktop app instead:" >&2
    echo "  $BASE/releases/latest.txt → $BASE/releases/comet-<version>-macos-arm64.dmg" >&2
    exit 1
    ;;
  *)
    echo "comet install: unsupported OS '$os' — only Linux for now." >&2
    exit 1
    ;;
esac
case "$arch" in
  x86_64 | amd64) arch=x86_64 ;;
  aarch64 | arm64) arch=aarch64 ;;
  *)
    echo "comet install: unsupported architecture '$arch'." >&2
    exit 1
    ;;
esac

# --- download ----------------------------------------------------------------
ver="$(curl -fsSL "$BASE/releases/latest.txt" | tr -d '[:space:]')"
[ -n "$ver" ] || { echo "comet install: could not resolve latest version" >&2; exit 1; }
file="comet-$ver-$plat-$arch.tar.gz"
data_root="$HOME/.comet-native"
app_root="$data_root/app"
dest="$app_root/$ver"

if [ -x "$dest/comet" ]; then
  echo "comet $ver already downloaded — relinking."
else
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  echo "downloading comet $ver ($plat-$arch)…"
  curl -fSL --progress-bar "$BASE/releases/$file" -o "$tmp/$file"
  mkdir -p "$dest"
  tar -xzf "$tmp/$file" -C "$dest" --strip-components=1
fi

ln -sfn "$dest" "$app_root/current"
mkdir -p "$HOME/.local/bin"
ln -sf "$app_root/current/comet" "$HOME/.local/bin/comet"

# --- service -----------------------------------------------------------------
# The daemon is useful before auth: without a saved session it serves the local
# profile. Login only changes which profile the next daemon start selects.

service=manual
if command -v systemctl >/dev/null 2>&1 && [ -n "${XDG_RUNTIME_DIR:-}" ]; then
  mkdir -p "$HOME/.config/systemd/user"
  cat >"$HOME/.config/systemd/user/comet-native.service" <<'UNIT'
[Unit]
Description=Comet native headless engine
After=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
ExecStart=%h/.comet-native/app/current/comet headless
Restart=on-failure
RestartSec=5
EnvironmentFile=-%h/.comet-native/env

[Install]
WantedBy=default.target
UNIT
  systemctl --user daemon-reload
  systemctl --user enable comet-native
  systemctl --user restart comet-native
  service=running
  # Keep the user manager (and the engine) running without an active login.
  loginctl enable-linger "$USER" 2>/dev/null \
    || sudo -n loginctl enable-linger "$USER" 2>/dev/null \
    || echo "warn: could not enable linger — the engine stops when you log out (run: sudo loginctl enable-linger $USER)"
else
  echo "warn: systemd user session not available — run the engine manually with: comet headless"
fi

# --- agent CLIs ---------------------------------------------------------------
command -v claude >/dev/null 2>&1 || \
  echo "note: Claude Code CLI not found — install it with: curl -fsSL https://claude.ai/install.sh | bash"

case ":$PATH:" in
  *":$HOME/.local/bin:"*) path_hint="" ;;
  *) path_hint=' (add ~/.local/bin to your PATH)' ;;
esac

echo ""
echo "✓ comet $ver installed$path_hint"
echo ""
case "$service" in
  running)
    echo "the engine is running with the new version (local-only unless sync is enabled)."
    echo "  systemctl --user status comet-native    check the service"
    echo ""
    echo "optional sync (local sessions stay local):"
    echo "  systemctl --user stop comet-native"
    echo "  comet login"
    echo "  systemctl --user restart comet-native"
    ;;
  manual)
    echo "next: run the local-only engine with \`comet headless\`."
    echo "optional sync: run \`comet login\` before starting the engine."
    ;;
esac
