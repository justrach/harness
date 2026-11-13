#!/bin/sh
# Builds harness-nano for release and wraps it as zig-out/Harness Nano.app.
set -eu
cd "$(dirname "$0")/.."
# ReleaseSafe: a bug panics with a stack trace in the crash log instead of
# corrupting memory, for 0.1 MB and no CPU measurable in bench/resource.py's
# replay (8.9% streaming against ReleaseFast's 9.7%, the same within noise).
zig build --release=safe -j1 "$@"
# Use the same workspace version embedded in the executable (build.zig).
# Refuse a placeholder bundle when the manifest is missing or malformed.
version=$(awk '
    /^\[workspace\.package\][[:space:]]*$/ { workspace = 1; next }
    workspace && /^\[/ { exit }
    workspace && /^[[:space:]]*version[[:space:]]*=[[:space:]]*"/ {
        sub(/^[^"]*"/, ""); sub(/".*$/, ""); print; exit
    }
' ../../Cargo.toml)
if [ -z "$version" ]; then
    echo "Cannot package Harness Nano: missing workspace version in Cargo.toml" >&2
    exit 1
fi
app="zig-out/Harness Nano.app/Contents"
mkdir -p "$app/MacOS" "$app/Resources"
cp zig-out/bin/harness-nano "$app/MacOS/"
icon=/Applications/Harness.app/Contents/Resources/harness.icns
[ -f "$icon" ] && cp "$icon" "$app/Resources/AppIcon.icns"
cat > "$app/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Harness Nano</string>
<key>CFBundleIdentifier</key><string>com.justrach.harness-nano</string>
<key>CFBundleExecutable</key><string>harness-nano</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$version</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST
# Copying over a linker-signed executable can invalidate its mapped pages.
# Re-seal the complete bundle after the executable, icon and plist are final.
codesign --force --sign - "zig-out/Harness Nano.app"
echo "zig-out/Harness Nano.app"
