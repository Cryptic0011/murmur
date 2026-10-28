#!/bin/bash
# Builds a Debug Murmur and installs it to /Applications.
#
# Debug builds are ad-hoc signed by Xcode (hardened runtime and entitlements as
# set in project.yml). An ad-hoc signature's identity is its cdhash, which
# changes on every build, so macOS treats each build as a new app: Mic and
# Accessibility grants and Keychain access don't carry over. This script resets
# Murmur's TCC entries so you re-grant once per run instead of chasing stale
# entries in System Settings.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DERIVED="$ROOT/build/DerivedData"
BUILT="$DERIVED/Build/Products/Debug/Murmur.app"
DEST="/Applications/Murmur.app"

# Don't silently replace a notarized release install with a dev build.
if [ -d "$DEST" ] && [ "${FORCE:-0}" != "1" ] &&
   [[ "$(codesign -dvv "$DEST" 2>&1 || true)" == *"Authority=Developer ID Application"* ]]; then
  echo "✗ $DEST is a Developer ID release build. Re-run with FORCE=1 to replace it."
  exit 1
fi

echo "→ Regenerating Xcode project"
xcodegen generate >/dev/null

echo "→ Building Murmur"
# A fixed DerivedData path means we install exactly what this run built, never
# a stale product from another checkout. -quiet still prints errors.
rm -rf "$BUILT"
xcodebuild -quiet -scheme Murmur -destination 'platform=macOS' -configuration Debug \
  -derivedDataPath "$DERIVED" build

if [ ! -d "$BUILT" ]; then
  echo "✗ Build finished but $BUILT is missing"
  exit 1
fi
echo "→ Built at: $BUILT"

# Quit any running Murmur first
osascript -e 'tell application "Murmur" to quit' 2>/dev/null || true
sleep 1
pkill -x Murmur 2>/dev/null || true

echo "→ Installing to $DEST"
rm -rf "$DEST"
cp -R "$BUILT" "$DEST"

echo "→ Resetting TCC for com.murmur.Murmur (so System Settings shows the fresh build)"
tccutil reset Microphone com.murmur.Murmur 2>/dev/null || true
tccutil reset Accessibility com.murmur.Murmur 2>/dev/null || true

echo ""
echo "✓ Installed. Launching..."
open "$DEST"

cat <<EOF

────────────────────────────────────────────────────────────────────
Murmur is now at /Applications/Murmur.app.

The onboarding wizard will ask for Mic + Accessibility. Grant both.
Because TCC was reset, any stale "Murmur" entry in System Settings →
Accessibility has been cleared — you'll add the fresh /Applications
copy when prompted. macOS may also ask once per saved API key to let
this build read it from the Keychain.

To rebuild after code changes: run this script again. It will quit
the running app, re-install, reset TCC, and relaunch — so you
re-grant once per script run, not once per launch.
────────────────────────────────────────────────────────────────────
EOF
