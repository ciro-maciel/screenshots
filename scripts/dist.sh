#!/bin/bash
# Every installer bumps the patch version, builds, packs a .dmg and installs it in /Applications.
#   scripts/dist.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IFS=. read -r MAJOR MINOR PATCH < "$ROOT/VERSION"
VERSION="$MAJOR.$MINOR.$((PATCH + 1))"
echo "$VERSION" > "$ROOT/VERSION"

"$ROOT/scripts/build.sh"

STAGE="$(mktemp -d)"
cp -R "$ROOT/dist/Screenshots.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="$ROOT/dist/Screenshots-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Screenshots by Ciro Cesar Maciel $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

# Install from the packed image, the same bytes a tester gets.
MOUNT="$(mktemp -d)"
hdiutil attach "$DMG" -nobrowse -mountpoint "$MOUNT" >/dev/null
osascript -e 'tell application id "click.ciromaciel.screenshots" to quit' >/dev/null 2>&1 || true
rm -rf /Applications/Screenshots.app
cp -R "$MOUNT/Screenshots.app" /Applications/
hdiutil detach "$MOUNT" >/dev/null
echo "Installed /Applications/Screenshots.app ($VERSION) from $DMG"
