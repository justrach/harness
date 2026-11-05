#!/usr/bin/env bash
# Private reconciliation preview. Does not replace/register the normal Dev app,
# claim harness:// links, copy existing settings, or update shared agent tools.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: GRAFF_BINARY=/absolute/path/to/graff scripts/run-macos-reconciliation.sh [--no-build] [--package-only]

Builds a debug Harness Reconciliation.app with its own bundle ID, data and IPC.
--no-build      Package the candidate's existing target binary.
--package-only  Prepare and verify the bundle without registering or launching it.

HARNESS_RECONCILIATION_PROFILE=dev|app-dev (default dev)
HARNESS_RECONCILIATION_IPC_PORT=49779 (default; checked before launch)
HARNESS_MODEL_PICKER_PREVIEW=1 enables the optional picker feature.
HARNESS_DEV_CODESIGN_IDENTITY may select a signing identity; default is ad-hoc.
USAGE
}

BUILD=true
LAUNCH=true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-build) BUILD=false ;;
    --package-only) LAUNCH=false ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done
[[ "$(uname -s)" == Darwin ]] || { echo "This preview launcher requires macOS." >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
BUILD_DIR="$REPO_ROOT/target"
PREVIEW_ROOT="$BUILD_DIR/macos-reconciliation"
# Keep the signed bundle outside synced Documents: File Provider re-adds
# FinderInfo there while codesign runs. Source, build cache and data stay isolated.
APP="$HOME/Applications/Harness Reconciliation.app"
CONTENTS="$APP/Contents"
# Runtime state must stay outside synced Documents too: a newly signed app can
# block in OS file access before its first window while loading that profile.
DATA_DIR="$HOME/Library/Application Support/Harness Reconciliation Preview/data"
# The existing updater classifies IDs ending in .dev as unmanaged, so even a
# manual release install cannot replace this isolated build.
BUNDLE_ID="harness.codegraff.app.reconciliation.20261101.dev"
IPC_PORT="${HARNESS_RECONCILIATION_IPC_PORT:-49779}"
PROFILE="${HARNESS_RECONCILIATION_PROFILE:-dev}"
case "$PROFILE" in
  dev) PROFILE_DIR=debug ;;
  app-dev) PROFILE_DIR=app-dev ;;
  *) echo "Use dev or app-dev: the isolation guard requires debug assertions." >&2; exit 2 ;;
esac

# Even an inherited target variable cannot redirect this candidate to a shared
# reference build tree. Reject symlinked output/data paths as well.
python3 - "$REPO_ROOT" "$BUILD_DIR" "$PREVIEW_ROOT" "$DATA_DIR" "$APP" "$CONTENTS" "$IPC_PORT" "$BUNDLE_ID" <<'PY'
import pathlib, plistlib, sys
root = pathlib.Path(sys.argv[1]).resolve()
for value in sys.argv[2:4]:
    path = pathlib.Path(value)
    if path.resolve() != path or root not in path.resolve().parents:
        raise SystemExit(f"Preview path must be an unlinked directory inside this checkout: {path}")
data = pathlib.Path(sys.argv[4])
expected_data = pathlib.Path.home()/'Library'/'Application Support'/'Harness Reconciliation Preview'/'data'
if data != expected_data or data.resolve() != data:
    raise SystemExit('Preview data must use its dedicated, unlinked local Application Support path')
app, contents = map(pathlib.Path, sys.argv[5:7])
expected = pathlib.Path.home()/'Applications'/'Harness Reconciliation.app'
if app != expected or app.resolve() != app or contents != app/'Contents':
    raise SystemExit('The preview bundle must use its dedicated, unlinked local Applications path')
if app.exists():
    info_path = contents/'Info.plist'
    if not info_path.is_file() or plistlib.loads(info_path.read_bytes()).get('CFBundleIdentifier') != sys.argv[8]:
        raise SystemExit('Refusing to replace an existing app with a different or unknown identity')
try:
    port = int(sys.argv[7])
except ValueError:
    raise SystemExit("Preview IPC port must be an integer")
if not 1024 <= port <= 65535 or port in (27664, 49777):
    raise SystemExit("Choose a separate preview IPC port, not the release or reference Dev port")
PY

if pgrep -f -x "$CONTENTS/MacOS/harness" >/dev/null 2>&1; then
  echo "Quit Harness Reconciliation before replacing its signed bundle." >&2
  exit 1
fi

# One-time copy of the previous preview profile, retaining its original intact.
# Never overwrite a profile already created at the new location.
python3 - "$PREVIEW_ROOT/data" "$DATA_DIR" <<'PYDATA'
import hashlib, pathlib, shutil, sys, tempfile
source, target = map(pathlib.Path, sys.argv[1:])
if not target.exists() and source.is_dir():
    if source.resolve() != source or any(p.is_symlink() for p in source.rglob('*')):
        raise SystemExit('Refusing to copy a preview profile containing symlinks')
    target.parent.mkdir(parents=True, exist_ok=True)
    staging = pathlib.Path(tempfile.mkdtemp(prefix='.profile-copy-', dir=target.parent))/'data'
    shutil.copytree(source, staging)
    for path in source.rglob('*'):
        if path.is_file():
            copied = staging/path.relative_to(source)
            if hashlib.sha256(path.read_bytes()).digest() != hashlib.sha256(copied.read_bytes()).digest():
                raise SystemExit('Preview profile copy failed verification; original is untouched')
    staging.rename(target)
    staging.parent.rmdir()
PYDATA

GRAFF_SRC="${GRAFF_BINARY:-}"
[[ "$GRAFF_SRC" == /* && -f "$GRAFF_SRC" && -x "$GRAFF_SRC" ]] || {
  echo "Set GRAFF_BINARY to the exact existing graff executable to pin in this preview." >&2
  exit 2
}

cd "$REPO_ROOT"
if "$BUILD"; then
  BUILD_ARGS=(build -p harness --profile "$PROFILE")
  if [[ "${HARNESS_MODEL_PICKER_PREVIEW:-0}" == 1 ]]; then
    BUILD_ARGS+=(--features harness-ui/model-picker-preview)
  fi
  CARGO_TARGET_DIR="$BUILD_DIR" "$REPO_ROOT/scripts/heavy-build.sh" cargo "${BUILD_ARGS[@]}"
fi
BINARY="$BUILD_DIR/$PROFILE_DIR/harness"
[[ -x "$BINARY" ]] || { echo "Build the candidate binary first: $BINARY" >&2; exit 1; }
# --no-build must not package an older binary without the explicit preview guard.
if ! /usr/bin/strings -a "$BINARY" | /usr/bin/grep -F 'HARNESS_RECONCILIATION_PREVIEW' >/dev/null; then
  echo "Candidate binary lacks the preview isolation guard; rebuild it first." >&2
  exit 1
fi

mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources/bin" "$DATA_DIR"
install -m 755 "$BINARY" "$CONTENTS/MacOS/harness"
install -m 755 "$GRAFF_SRC" "$CONTENTS/Resources/bin/graff"
mkdir -p "$CONTENTS/Resources/licenses"
cp "$REPO_ROOT/crates/ui/assets/session-emoji/LICENSE" "$CONTENTS/Resources/licenses/emoji-datasource.LICENSE"
for chime in done request attention; do
  cp "$REPO_ROOT/crates/ui/assets/sounds/$chime.wav" "$CONTENTS/Resources/harness-$chime.wav"
done

python3 - "$REPO_ROOT" "$CONTENTS" "$DATA_DIR" "$IPC_PORT" "$BUNDLE_ID" "${HARNESS_MODEL_PICKER_PREVIEW:-0}" <<'PY'
import pathlib, plistlib, re, sys
root, contents, data = map(pathlib.Path, sys.argv[1:4])
version = re.search(r'^version\s*=\s*"([^"]+)"', (root/'Cargo.toml').read_text(), re.M).group(1)
info = plistlib.loads((root/'dist/macos/Info-dev.plist').read_bytes())
info.update(CFBundleIdentifier=sys.argv[5], CFBundleDisplayName='Harness Reconciliation',
            CFBundleName='Harness Reconciliation', CFBundleShortVersionString=version,
            CFBundleVersion=version)
# The normal harness:// handler stays with the installed/reference app.
info.pop('CFBundleURLTypes', None)
info['LSEnvironment'] = {
    'HARNESS_RECONCILIATION_PREVIEW':'1', 'HARNESS_AUTO_UPDATE':'0',
    'HARNESS_GRAFF_AUTO_UPDATE':'0', 'HARNESS_DATA_DIR':str(data),
    'HARNESS_IPC_PORT':sys.argv[4],
    'GRAFF_EXECUTABLE':str(contents/'Resources/bin/graff'),
}
if sys.argv[6] == '1':
    info['LSEnvironment']['HARNESS_MODEL_PICKER_PREVIEW'] = '1'
(contents/'Info.plist').write_bytes(plistlib.dumps(info, sort_keys=False))
PY

if [[ ! -f "$CONTENTS/Resources/harness.icns" || "$REPO_ROOT/dist/macos/icon-1024.png" -nt "$CONTENTS/Resources/harness.icns" ]]; then
  ICONSET="$PREVIEW_ROOT/reconciliation.iconset"
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$REPO_ROOT/dist/macos/icon-1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    retina=$((size * 2))
    sips -z "$retina" "$retina" "$REPO_ROOT/dist/macos/icon-1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/harness.icns"
fi

# Finder/File Provider can attach bundle metadata while the directory is built.
# Remove only the two attributes codesign rejects, and only on this generated app.
python3 - "$APP" <<'PYATTR'
import pathlib, subprocess, sys
app = pathlib.Path(sys.argv[1])
for path in [app, *app.rglob('*')]:
    present = subprocess.check_output(['/usr/bin/xattr', '-s', str(path)], text=True).splitlines()
    for name in ('com.apple.FinderInfo', 'com.apple.ResourceFork'):
        if name in present:
            subprocess.run(['/usr/bin/xattr', '-s', '-d', name, str(path)], check=True)
PYATTR

codesign --force --sign "${HARNESS_DEV_CODESIGN_IDENTITY:--}" --identifier "$BUNDLE_ID" "$APP"
codesign --verify --strict "$APP"
plutil -lint "$CONTENTS/Info.plist"
echo "Prepared $APP (data $DATA_DIR, IPC $IPC_PORT)" >&2
"$LAUNCH" || exit 0

python3 - "$IPC_PORT" <<'PY'
import socket, sys
with socket.socket() as sock:
    try:
        sock.bind(('127.0.0.1', int(sys.argv[1])))
    except OSError as error:
        raise SystemExit(f"Preview IPC port is already occupied: {error}")
PY
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -f "$APP"
OPEN_ENV=(
  --env "HARNESS_RECONCILIATION_PREVIEW=1"
  --env "HARNESS_AUTO_UPDATE=0"
  --env "HARNESS_GRAFF_AUTO_UPDATE=0"
  --env "HARNESS_DATA_DIR=$DATA_DIR"
  --env "HARNESS_IPC_PORT=$IPC_PORT"
  --env "GRAFF_EXECUTABLE=$CONTENTS/Resources/bin/graff"
)
if [[ "${HARNESS_MODEL_PICKER_PREVIEW:-0}" == 1 ]]; then
  OPEN_ENV+=(--env "HARNESS_MODEL_PICKER_PREVIEW=1")
fi
# Fresh local app data is intentional. Do not inherit an explicit sync bearer,
# organization or source-app route from the invoking shell.
exec env -u HARNESS_EDGE_TOKEN -u HARNESS_ORG_ID -u HARNESS_CODEGRAFF_CLIENT_ID \
  -u HARNESS_OPEN_ROUTE /usr/bin/open -W "${OPEN_ENV[@]}" "$APP"
