#!/bin/bash
# Builds the app and packages it for sharing: dist/OpenAssistant-<version>.zip
set -euo pipefail
cd "$(dirname "$0")"
VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)}"
./build.sh
mkdir -p dist
rm -f "dist/OpenAssistant-$VERSION.zip"
# ditto keeps the .app bundle's structure and signature intact (zip does not)
ditto -c -k --sequesterRsrc --keepParent "build/Open Assistant.app" "dist/OpenAssistant-$VERSION.zip"
echo "Release: dist/OpenAssistant-$VERSION.zip ($(du -h "dist/OpenAssistant-$VERSION.zip" | cut -f1))"
