#!/bin/bash
# Builds "Open Assistant.app". Usage:
#   ./build.sh            build into ./build
#   ./build.sh --install  build, copy to /Applications and launch
set -euo pipefail
cd "$(dirname "$0")"

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "Swift compiler not found. Install Apple's command line tools first:"
  echo "  xcode-select --install"
  exit 1
fi

APP="build/Open Assistant.app"
ARCH="$(uname -m)"

echo "-> Compiling for ${ARCH}..."
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

xcrun swiftc -O \
  -parse-as-library \
  -swift-version 5 \
  -target "${ARCH}-apple-macos13.0" \
  -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/OpenAssistant"

cp Info.plist "$APP/Contents/Info.plist"
# A stable self-signed identity keeps Accessibility/Input Monitoring grants across rebuilds.
# (See README "Troubleshooting" for how to create "Open Assistant Dev".)
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Open Assistant Dev"; then
  codesign --force --sign "Open Assistant Dev" "$APP" >/dev/null && echo "Signed with Open Assistant Dev (permissions will persist)"
else
  codesign --force --sign - "$APP" >/dev/null
  echo "Signed ad hoc: re-add the app under Accessibility after this install (see README)"
fi
echo "Built: ${APP}"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x OpenAssistant 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x OpenAssistant >/dev/null || break; sleep 0.3; done
  rm -rf "/Applications/Open Assistant.app"
  cp -R "$APP" /Applications/
  echo "Installed to /Applications. Launching..."
  sleep 1
  open -a "/Applications/Open Assistant.app" || { sleep 2; open -a "/Applications/Open Assistant.app"; }
fi
