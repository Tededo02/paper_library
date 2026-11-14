#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source_image="$PWD/Branding/AppIcon.png"
icon_output="$PWD/PaperLibrary/Resources/AppIcon.icns"
staging_directory="$(mktemp -d "${TMPDIR:-/tmp}/paperlibrary-icon.XXXXXX")"
trap 'rm -rf "$staging_directory"' EXIT
iconset_path="$staging_directory/AppIcon.iconset"
mkdir -p "$iconset_path" "$(dirname "$icon_output")"
for points in 16 32 128 256 512; do
    sips -z "$points" "$points" "$source_image" --out "$iconset_path/icon_${points}x${points}.png" > /dev/null
    pixels=$((points * 2))
    sips -z "$pixels" "$pixels" "$source_image" --out "$iconset_path/icon_${points}x${points}@2x.png" > /dev/null
done
iconutil --convert icns --output "$icon_output" "$iconset_path"
printf '%s\n' "$icon_output"
