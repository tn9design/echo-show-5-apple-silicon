#!/bin/bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/.." && pwd)
stage_root=$(mktemp -d "${TMPDIR:-/private/tmp}/EchoGuideRelease.XXXXXX")
trap 'rm -rf "$stage_root"' EXIT
output_dir=${1:-"$repo_root/dist"}
mkdir -p "$output_dir" "$stage_root/EchoGuide-source"
output_dir=$(cd "$output_dir" && pwd)
# Explicit source allowlist: never include sessions, backups, guest keys, or images.
for item in Package.swift README.md LICENSE hashes.json Assets Sources Tests docs skills script tools .github; do
    if [ -e "$repo_root/$item" ]; then COPYFILE_DISABLE=1 cp -R "$repo_root/$item" "$stage_root/EchoGuide-source/"; fi
done
# Strip external-drive metadata only from the disposable copy, never the checkout.
/usr/bin/xattr -cr "$stage_root/EchoGuide-source"
python3 - "$stage_root/EchoGuide-source" <<'PY'
import pathlib
import shutil
import sys
root = pathlib.Path(sys.argv[1])
for path in root.rglob('__pycache__'):
    if path.is_dir() and not path.is_symlink():
        shutil.rmtree(path)
for path in root.rglob('._*'):
    if path.is_file() or path.is_symlink():
        path.unlink()
PY
(cd "$stage_root" && /usr/bin/zip -qr "$stage_root/EchoGuide-source-preview.zip" EchoGuide-source)
mv "$stage_root/EchoGuide-source-preview.zip" "$output_dir/EchoGuide-source-preview.zip"
if [ -z "${ECHOGUIDE_SIGNING_IDENTITY:-}" ] || [ -z "${ECHOGUIDE_NOTARY_PROFILE:-}" ]; then
    echo 'Source preview packaged. Signed app requires ECHOGUIDE_SIGNING_IDENTITY and ECHOGUIDE_NOTARY_PROFILE.'
    (cd "$output_dir" && /usr/bin/shasum -a 256 EchoGuide-source-preview.zip > SHA256SUMS)
    exit 0
fi
cd "$stage_root/EchoGuide-source"
swift build --disable-sandbox -c release --scratch-path "$stage_root/build"
bin_dir=$(swift build --disable-sandbox -c release --scratch-path "$stage_root/build" --show-bin-path)
app="$stage_root/EchoGuide.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/EchoGuide" "$app/Contents/MacOS/"
cp Assets/EchoGuide.icns "$app/Contents/Resources/EchoGuide.icns"
cp "$bin_dir/echo-guide" "$bin_dir/echo-guide-mcp" "$app/Contents/MacOS/"
# SwiftPM-generated resource bundles accompany the executable.
for bundle in "$bin_dir"/*.bundle; do
    [ -e "$bundle" ] && cp -R "$bundle" "$app/Contents/Resources/"
done
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.echoguide.preflight</string>
<key>CFBundleName</key><string>EchoGuide</string>
<key>CFBundleIconFile</key><string>EchoGuide</string>
<key>CFBundleExecutable</key><string>EchoGuide</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>NSAppleEventsUsageDescription</key><string>EchoGuide creates and manages its isolated UTM Linux workspace.</string>
<key>NSLocalNetworkUsageDescription</key><string>EchoGuide connects only to your managed Linux workspace for authenticated setup and installation checks.</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
/usr/bin/xattr -cr "$app"
entitlements="$stage_root/EchoGuide-source/script/automation.entitlements"
for executable in EchoGuide echo-guide echo-guide-mcp; do
    /usr/bin/codesign --force --options runtime --timestamp --entitlements "$entitlements" --sign "$ECHOGUIDE_SIGNING_IDENTITY" "$app/Contents/MacOS/$executable"
done
/usr/bin/codesign --force --options runtime --timestamp --entitlements "$entitlements" --sign "$ECHOGUIDE_SIGNING_IDENTITY" "$app"
/usr/bin/codesign --verify --deep --strict "$app"
/usr/bin/ditto -c -k --keepParent "$app" "$stage_root/EchoGuide-submission.zip"
xcrun notarytool submit "$stage_root/EchoGuide-submission.zip" --keychain-profile "$ECHOGUIDE_NOTARY_PROFILE" --wait
xcrun stapler staple "$app"
xcrun stapler validate "$app"
/usr/bin/ditto -c -k --keepParent "$app" "$output_dir/EchoGuide-macOS-preview.zip"
(cd "$output_dir" && /usr/bin/shasum -a 256 EchoGuide-source-preview.zip EchoGuide-macOS-preview.zip > SHA256SUMS)
echo "Verified preview packages in $output_dir"
