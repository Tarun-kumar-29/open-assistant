#!/bin/bash
# Installs Open Assistant from the latest GitHub release. Usage:
#   curl -fsSL https://raw.githubusercontent.com/Tarun-kumar-29/open-assistant/main/install.sh | bash
set -euo pipefail
REPO="${OPEN_ASSISTANT_REPO:-Tarun-kumar-29/open-assistant}"
TMP="$(mktemp -d)"
echo "→ Fetching latest release of $REPO…"
URL="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" | grep -o '"browser_download_url": *"[^"]*\.zip"' | head -1 | sed 's/.*"\(https[^"]*\)"/\1/')"
[ -n "$URL" ] || { echo "No release zip found for $REPO"; exit 1; }
curl -fsSL "$URL" -o "$TMP/app.zip"
echo "→ Installing to /Applications…"
ditto -x -k "$TMP/app.zip" "$TMP"
pkill -x OpenAssistant 2>/dev/null || true
rm -rf "/Applications/Open Assistant.app"
mv "$TMP/Open Assistant.app" /Applications/
# The app isn't notarized by Apple, so clear the quarantine flag Gatekeeper would otherwise block on.
xattr -dr com.apple.quarantine "/Applications/Open Assistant.app" 2>/dev/null || true
rm -rf "$TMP"
open -a "/Applications/Open Assistant.app"
cat <<'MSG'

✓ Open Assistant is running (waveform icon in the menu bar).

Next, when it asks:
  1. Paste your Anthropic API key   → console.anthropic.com → API Keys
  2. Allow Microphone, Speech Recognition, Accessibility and Input Monitoring
  3. Menu bar icon → Set Groq API Key… (free, console.groq.com) for much better transcription

Hold Right ⌘ to talk · hold Right ⌥ to dictate into any app.
MSG
