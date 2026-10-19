#!/bin/bash
# Packs a built .app into a .dmg with the Applications shortcut beside it — the
# same image each app's scripts/dist.sh makes, without bumping the version or
# installing it on this Mac.
#   scripts/release/dmg-mac.sh <App.app> <out.dmg> "<volume name>"
set -euo pipefail

APP="$1"
DMG="$2"
VOLUME="$3"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "$VOLUME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
echo "$(basename "$APP") → $DMG"
