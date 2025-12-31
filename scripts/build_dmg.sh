#!/usr/bin/env bash
set -euo pipefail

# Builds StudyBuddy.app (Release) and packages it into a DMG.
#
# Usage:
#   chmod +x scripts/build_dmg.sh
#   ./scripts/build_dmg.sh
#
# Output:
#   dist/StudyBuddy.dmg

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/StudyBuddy.xcodeproj"
SCHEME="StudyBuddy"
CONFIG="Release"

DIST_DIR="$ROOT_DIR/dist"
BUILD_DIR="$DIST_DIR/build"
APP_PATH="$BUILD_DIR/Build/Products/$CONFIG/StudyBuddy.app"
DMG_PATH="$DIST_DIR/StudyBuddy.dmg"

mkdir -p "$DIST_DIR"

# Clean build into an isolated derived data folder under dist/
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -destination 'platform=macOS' \
  -derivedDataPath "$BUILD_DIR" \
  clean build | cat

if [[ ! -d "$APP_PATH" ]]; then
  echo "ERROR: App not found at: $APP_PATH" >&2
  exit 1
fi

# Stage into a temp folder that becomes the DMG volume.
STAGE_DIR="$DIST_DIR/dmg-stage"
rm -rf "$STAGE_DIR" "$DMG_PATH"
mkdir -p "$STAGE_DIR"

cp -R "$APP_PATH" "$STAGE_DIR/"

# Create Applications symlink for convenience.
ln -s /Applications "$STAGE_DIR/Applications"

# Create DMG.
hdiutil create \
  -volname "$SCHEME" \
  -srcfolder "$STAGE_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH" | cat

echo "✅ DMG created: $DMG_PATH"
