#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
set +e
pgrep -x EchoGuide >/dev/null
process_status=$?
set -e
if [[ $process_status == 0 ]]; then
    echo 'EchoGuide is already running. Finish any active operation and quit the app before rebuilding; no process was stopped.' >&2
    exit 1
elif [[ $process_status != 1 ]]; then
    echo 'Cannot inspect running apps. No existing app bundle was changed; run from a permitted local terminal.' >&2
    exit 1
fi
scratch="${TMPDIR:-/private/tmp}/EchoGuideBuild"
export CLANG_MODULE_CACHE_PATH="$scratch/ModuleCache"
export SWIFT_MODULECACHE_PATH="$scratch/ModuleCache"
build_options=(--disable-sandbox --scratch-path "$scratch")
swift build "${build_options[@]}"
products="$(swift build "${build_options[@]}" --show-bin-path)"
binary="$products/EchoGuide"
bundle="${TMPDIR:-/private/tmp}/EchoGuidePreview/EchoGuide.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$binary" "$bundle/Contents/MacOS/EchoGuide"
cp Assets/EchoGuide.icns "$bundle/Contents/Resources/EchoGuide.icns"
# SwiftPM's generated accessor searches Bundle.main.resourceURL in an app.
# Use the conventional layout required by strict bundle signing.
shopt -s nullglob
for resources in "$products"/*.bundle; do
    resource_name="$(basename "$resources")"
    rm -rf "$bundle/$resource_name" "$bundle/Contents/Resources/$resource_name"
    cp -R "$resources" "$bundle/Contents/Resources/$resource_name"
done
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>EchoGuide</string>
<key>CFBundleIdentifier</key><string>org.echoguide.preflight</string>
<key>CFBundleName</key><string>EchoGuide</string>
<key>CFBundleIconFile</key><string>EchoGuide</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSAppleEventsUsageDescription</key><string>EchoGuide creates and manages its isolated UTM Linux workspace.</string>
<key>NSLocalNetworkUsageDescription</key><string>EchoGuide connects only to your managed Linux workspace for authenticated setup and installation checks.</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
/usr/bin/open -n "$bundle"
if [[ ${1:-} == --verify ]]; then
    sleep 1
    pgrep -x EchoGuide >/dev/null
fi
