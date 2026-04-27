#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SCHEME="Murmur"
CONFIGURATION="Release"
DIST_DIR="$ROOT/dist"
STAGE_DIR="$DIST_DIR/dmg-root"
DMG_NAME="Murmur.dmg"
VOL_NAME="Murmur"
APP_PATH=""

MARKETING_VERSION="$(sed -nE 's/^[[:space:]]*MARKETING_VERSION: "?([^"]+)"?/\1/p' project.yml | head -1)"
BUILD_NUMBER="$(sed -nE 's/^[[:space:]]*CURRENT_PROJECT_VERSION: "?([^"]+)"?/\1/p' project.yml | head -1)"

if [ -z "$MARKETING_VERSION" ] || [ -z "$BUILD_NUMBER" ]; then
  echo "✗ Could not read version info from project.yml"
  exit 1
fi

echo "→ Regenerating Xcode project"
xcodegen generate >/dev/null

echo "→ Building $SCHEME ($CONFIGURATION)"
xcodebuild \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination 'platform=macOS' \
  build >/dev/null

APP_PATH="$(find "$HOME/Library/Developer/Xcode/DerivedData" \
  -type d \
  -path "*Build/Products/$CONFIGURATION/Murmur.app" \
  -not -path "*Index.noindex*" \
  | head -1)"

if [ -z "$APP_PATH" ]; then
  echo "✗ Could not locate built Murmur.app"
  exit 1
fi

echo "→ Built app: $APP_PATH"

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
cp -R "$APP_PATH" "$STAGE_DIR/Murmur.app"
ln -s /Applications "$STAGE_DIR/Applications"

if [ -n "${MURMUR_CODESIGN_IDENTITY:-}" ]; then
  echo "→ Re-signing app with Developer ID identity"
  codesign \
    --force \
    --deep \
    --options runtime \
    --sign "$MURMUR_CODESIGN_IDENTITY" \
    "$STAGE_DIR/Murmur.app"
fi

mkdir -p "$DIST_DIR"
rm -f "$DIST_DIR/$DMG_NAME" "$DIST_DIR/Murmur-v$MARKETING_VERSION.dmg"

echo "→ Creating DMG"
hdiutil create \
  -volname "$VOL_NAME" \
  -srcfolder "$STAGE_DIR" \
  -ov \
  -format UDZO \
  "$DIST_DIR/$DMG_NAME" >/dev/null

cp "$DIST_DIR/$DMG_NAME" "$DIST_DIR/Murmur-v$MARKETING_VERSION.dmg"

if [ -n "${MURMUR_NOTARY_PROFILE:-}" ]; then
  echo "→ Submitting DMG for notarization"
  xcrun notarytool submit "$DIST_DIR/$DMG_NAME" --keychain-profile "$MURMUR_NOTARY_PROFILE" --wait
  echo "→ Stapling notarization ticket"
  xcrun stapler staple "$DIST_DIR/$DMG_NAME"
fi

echo ""
echo "✓ Release artifacts ready"
echo "  Version: v$MARKETING_VERSION ($BUILD_NUMBER)"
echo "  DMG: $DIST_DIR/$DMG_NAME"
echo "  Versioned copy: $DIST_DIR/Murmur-v$MARKETING_VERSION.dmg"
echo ""
echo "Upload \`Murmur.dmg\` to your GitHub release so this stable website link keeps working:"
echo "https://github.com/Cryptic0011/murmur/releases/latest/download/Murmur.dmg"
