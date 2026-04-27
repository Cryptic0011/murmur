#!/bin/bash
# Builds Murmur and installs it to /Applications with a stable ad-hoc signature
# so TCC permissions (Mic, Accessibility) survive across rebuilds.
#
# Without this, Xcode's DerivedData rebuild generates a fresh cdhash on every
# build, which TCC treats as a brand-new app — meaning permissions get re-prompted
# every launch and your existing toggle in System Settings → Accessibility points
# at a stale binary.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "→ Regenerating Xcode project"
xcodegen generate >/dev/null

echo "→ Building Murmur"
xcodebuild -scheme Murmur -destination 'platform=macOS' -configuration Debug build >/dev/null

BUILT=$(find ~/Library/Developer/Xcode/DerivedData -type d -name "Murmur.app" -path "*Build/Products/Debug/*" -not -path "*Index.noindex*" | head -1)
if [ -z "$BUILT" ]; then
  echo "✗ Could not locate built Murmur.app"
  exit 1
fi
echo "→ Built at: $BUILT"

DEST="/Applications/Murmur.app"

# Quit any running Murmur first
osascript -e 'tell application "Murmur" to quit' 2>/dev/null || true
sleep 1
pkill -x Murmur 2>/dev/null || true

echo "→ Installing to $DEST"
rm -rf "$DEST"
cp -R "$BUILT" "$DEST"

# Re-sign with stable identifier so the cdhash is keyed off the bundle ID
echo "→ Re-signing with stable identifier"
codesign --force --deep --sign - --identifier com.murmur.Murmur "$DEST"

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
copy when prompted.

To rebuild after code changes: run this script again. It will quit
the running app, re-install, reset TCC, and relaunch — so you only
re-grant once per script run, not once per launch.
────────────────────────────────────────────────────────────────────
EOF
