#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/xcode-environment.sh
configuration="${1:-release}"
case "$configuration" in debug|release) ;; *) exit 2 ;; esac
swift build --product PaperLibrary -c "$configuration" --scratch-path .build --cache-path .build/cache
binary_path="$(swift build -c "$configuration" --scratch-path .build --cache-path .build/cache --show-bin-path)"
destination_path="$PWD/build/release/Paper Library.app"
mkdir -p "$PWD/build/release"
staging_directory="$(mktemp -d "$PWD/build/release/.paperlibrary-bundle.XXXXXX")"
trap 'rm -rf "$staging_directory"' EXIT
app_path="$staging_directory/Paper Library.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$binary_path/PaperLibrary" "$app_path/Contents/MacOS/PaperLibrary"
cp PaperLibrary/Info.plist "$app_path/Contents/Info.plist"
cp PaperLibrary/Resources/AppIcon.icns "$app_path/Contents/Resources/AppIcon.icns"
for bundle in "$binary_path"/*.bundle; do
    if [ -d "$bundle" ]; then
        ditto "$bundle" "$app_path/Contents/Resources/$(basename "$bundle")"
    fi
done
codesign --force --sign - "$app_path"
codesign --verify --deep --strict "$app_path"
if [ -e "$destination_path" ]; then
    rm -rf "$destination_path"
fi
mv "$app_path" "$destination_path"
python3 Scripts/check_single_app.py
printf '%s\n' "$destination_path"
