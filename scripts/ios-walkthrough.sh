#!/usr/bin/env bash
# Walk through the iOS app as a new install meets it, offline, and collect a
# numbered screenshot per step plus notes on what got in the way.
#
#   scripts/ios-walkthrough.sh                     # fresh install on an iPhone 17 Pro simulator
#   scripts/ios-walkthrough.sh --device "iPhone 17"
#   scripts/ios-walkthrough.sh --args "-phoneSplit sideBySide"
#   scripts/ios-walkthrough.sh --keep-install      # keep the app's settings from the last run
#   scripts/ios-walkthrough.sh --open              # open the contact sheet when done
#
# The walk itself is HarnessUITests/WalkthroughUITests. The app is removed from
# the simulator first so it starts as a new install would. Builds are
# incremental (derived data under apps/ios/build/walkthrough), so after a
# change the next run only rebuilds what moved.
#
# Output: apps/ios/build/walkthrough/<time>/ with the screenshots, notes.txt,
# index.html and the full xcodebuild.log. A simulator this script booted is
# shut down at the end.
set -euo pipefail
cd "$(dirname "$0")/../apps/ios"

DEVICE="iPhone 17 Pro"
EXTRA_ARGS=""
KEEP_INSTALL=""
OPEN=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --device) DEVICE="$2"; shift 2 ;;
    --args) EXTRA_ARGS="$2"; shift 2 ;;
    --keep-install) KEEP_INSTALL=1; shift ;;
    --open) OPEN=1; shift ;;
    *) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
  esac
done

# Command Line Tools alone have no simctl or xcodebuild; use Xcode if it is installed.
if ! xcrun --find simctl >/dev/null 2>&1 && [ -d /Applications/Xcode.app ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

BUNDLE_ID="harness.codegraff.ios"
BUILD="build/walkthrough"
OUT="$BUILD/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"

UDID="$(xcrun simctl list devices available --json | python3 -c '
import json, sys
name = sys.argv[1]
for runtime, devices in json.load(sys.stdin)["devices"].items():
    if "iOS" in runtime:
        for d in devices:
            if d["name"] == name:
                print(d["udid"]); sys.exit()
' "$DEVICE")"
[ -n "$UDID" ] || { echo "no available simulator named \"$DEVICE\"" >&2; exit 1; }

BOOTED_HERE=""
if ! xcrun simctl list devices booted | grep -q "$UDID"; then
  xcrun simctl boot "$UDID"
  BOOTED_HERE=1
fi
trap '[ -n "$BOOTED_HERE" ] && xcrun simctl shutdown "$UDID" 2>/dev/null || true' EXIT

[ -n "$KEEP_INSTALL" ] || xcrun simctl uninstall "$UDID" "$BUNDLE_ID" 2>/dev/null || true

echo "▸ walking through on $DEVICE (first build takes a few minutes)…"
status=0
TEST_RUNNER_WALKTHROUGH_ARGS="$EXTRA_ARGS" xcodebuild -project Harness.xcodeproj -scheme Harness \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath "$BUILD/derived" \
  -resultBundlePath "$OUT/run.xcresult" \
  -only-testing:HarnessUITests/WalkthroughUITests \
  CODE_SIGNING_ALLOWED=NO test >"$OUT/xcodebuild.log" 2>&1 || status=$?
grep -E "error:|Test Case .*(passed|failed)|\*\* TEST" "$OUT/xcodebuild.log" | grep -v "^ *[0-9]* |" || true

xcrun xcresulttool export attachments --path "$OUT/run.xcresult" --output-path "$OUT/raw" >/dev/null
python3 - "$OUT" <<'PYTHON'
import html, json, os, re, shutil, sys
out = sys.argv[1]
raw = os.path.join(out, "raw")
shots, notes = [], ""
for test in json.load(open(os.path.join(raw, "manifest.json"))):
    for a in test["attachments"]:
        src = os.path.join(raw, a["exportedFileName"])
        # Xcode appends "_<index>_<uuid>" to the name the test gave.
        name = re.sub(r"_\d+_[0-9A-Fa-f-]{36}$", "", os.path.splitext(a.get("suggestedHumanReadableName", ""))[0])
        if name == "notes":
            notes = open(src).read()
        elif src.endswith((".png", ".jpeg", ".jpg")):
            dest = name + os.path.splitext(src)[1]
            shutil.copy(src, os.path.join(out, dest))
            shots.append((name, dest))
shots.sort()
open(os.path.join(out, "notes.txt"), "w").write(notes)
cards = "\n".join(
    f'<figure><img src="{html.escape(f)}"><figcaption>{html.escape(n)}</figcaption></figure>' for n, f in shots)
open(os.path.join(out, "index.html"), "w").write(f"""<!doctype html><meta charset="utf-8"><title>iOS walkthrough</title>
<style>body{{font:14px -apple-system,sans-serif;margin:24px;background:#111;color:#ddd}}
pre{{background:#1c1c1c;padding:12px;white-space:pre-wrap}}
main{{display:grid;grid-template-columns:repeat(auto-fill,minmax(220px,1fr));gap:16px}}
img{{width:100%;border-radius:12px}}figure{{margin:0}}figcaption{{padding:4px 2px}}</style>
<h1>iOS walkthrough</h1><h2>What got in the way</h2><pre>{html.escape(notes)}</pre><main>{cards}</main>""")
print(f"{len(shots)} screenshots")
PYTHON
rm -rf "$OUT/raw"

echo "▸ $(pwd)/$OUT"
echo "── what got in the way ──"
cat "$OUT/notes.txt"
[ -z "$OPEN" ] || open "$OUT/index.html"
exit "$status"
