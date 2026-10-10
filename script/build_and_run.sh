#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
pkill -x EchoGuide >/dev/null 2>&1 || true
scratch="${TMPDIR:-/private/tmp}/EchoGuideBuild"
swift build --scratch-path "$scratch"
binary="$(swift build --scratch-path "$scratch" --show-bin-path)/EchoGuide"
bundle="${TMPDIR:-/private/tmp}/EchoGuidePreview/EchoGuide.app"
mkdir -p "$bundle/Contents/MacOS"
cp "$binary" "$bundle/Contents/MacOS/EchoGuide"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>EchoGuide</string>
<key>CFBundleIdentifier</key><string>org.echoguide.preflight</string>
<key>CFBundleName</key><string>EchoGuide</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
/usr/bin/open -n "$bundle"
if [[ ${1:-} == --verify ]]; then
    sleep 1
    pgrep -x EchoGuide >/dev/null
fi
