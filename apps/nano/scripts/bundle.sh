#!/bin/sh
# Builds harness-nano for release and wraps it as zig-out/Harness Nano.app.
set -eu
cd "$(dirname "$0")/.."
# ReleaseSafe: a bug panics with a stack trace in the crash log instead of
# corrupting memory, for 0.1 MB and no CPU measurable in bench/resource.py's
# replay (8.9% streaming against ReleaseFast's 9.7%, the same within noise).
zig build -Doptimize=ReleaseSafe "$@"
app="zig-out/Harness Nano.app/Contents"
mkdir -p "$app/MacOS" "$app/Resources"
cp zig-out/bin/harness-nano "$app/MacOS/"
icon=/Applications/Harness.app/Contents/Resources/harness.icns
[ -f "$icon" ] && cp "$icon" "$app/Resources/AppIcon.icns"
cat > "$app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Harness Nano</string>
<key>CFBundleIdentifier</key><string>com.justrach.harness-nano</string>
<key>CFBundleExecutable</key><string>harness-nano</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.0.1</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST
echo "zig-out/Harness Nano.app"
