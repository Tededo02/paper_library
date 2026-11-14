#!/bin/bash
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    selected_developer_directory="$(xcode-select -p)"
    if [ ! -d "$selected_developer_directory/Platforms/MacOSX.platform" ]; then
        export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    fi
fi
