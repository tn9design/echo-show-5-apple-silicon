#!/bin/bash
# Convert the original icon artwork into the standard macOS icon family.
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/.." && pwd)
output=${1:-"$repo_root/Assets/EchoGuide.icns"}
working=$(mktemp -d "${TMPDIR:-/private/tmp}/EchoGuideIcon.XXXXXX")
trap 'rm -rf "$working"' EXIT
mkdir -p "$working/EchoGuide.iconset"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$repo_root/Assets/EchoGuide-icon.png" --out "$working/EchoGuide.iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$repo_root/Assets/EchoGuide-icon.png" --out "$working/EchoGuide.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$working/EchoGuide.iconset" -o "$output"
