#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/xcode-environment.sh
mkdir -p build
verification_directory="$(mktemp -d "$PWD/build/.verification.XXXXXX")"
cleanup() {
    if [ -d "$verification_directory/Products/Paper Library.app" ]; then
        /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$verification_directory/Products/Paper Library.app" > /dev/null 2>&1 || true
    fi
    rm -rf "$verification_directory"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
python3 Scripts/check_project.py
swift run --scratch-path .build --cache-path .build/cache StorageChecks
if ! xcodebuild -version; then
    printf '%s\n' 'BLOCKED: Full Xcode is required for SwiftData macros, application builds, and migration tests.'
    exit 2
fi
swift test --scratch-path .build --cache-path .build/cache
xcodebuild -project PaperLibrary.xcodeproj -scheme PaperLibrary -configuration Debug -destination 'platform=macOS' -derivedDataPath build/DerivedData build test CODE_SIGNING_ALLOWED=NO "PAPERLIBRARY_APP_OUTPUT_DIR=$verification_directory/Products"
xcodebuild -project PaperLibrary.xcodeproj -scheme PaperLibrary -configuration Release -destination 'platform=macOS' -derivedDataPath build/DerivedData build CODE_SIGNING_ALLOWED=NO "PAPERLIBRARY_APP_OUTPUT_DIR=$verification_directory/Products"
cleanup
trap - EXIT
python3 Scripts/check_single_app.py --allow-missing
