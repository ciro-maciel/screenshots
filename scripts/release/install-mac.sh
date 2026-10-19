#!/bin/bash
#
# Installs __NAME__ with one line, on a Mac with Apple Silicon:
#
#   curl -fsSL __BASE__/install.sh | bash
#
# Downloads the latest .dmg, copies the app to /Applications and opens it. A
# file fetched by curl carries no quarantine flag, so macOS opens the app
# without the "Apple could not verify" block a browser download gets; the flag
# is cleared anyway in case the app came from elsewhere before.
#
# This file is a template: publish-mac.sh fills the __NAME__-style fields and
# uploads it next to the .dmg.

set -euo pipefail

NAME="__NAME__"
BASE="__BASE__"
PAGE="__PAGE__"
APP="${NAME}.app"

WORK="$(mktemp -d)"
cleanup() {
    hdiutil detach "$WORK/volume" -quiet 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

[ "$(uname -s)" = Darwin ] || { echo "${NAME} is a Mac app. More at $PAGE"; exit 1; }
[ "$(uname -m)" = arm64 ] || { echo "${NAME} needs a Mac with Apple Silicon (M1 or newer)."; exit 1; }
MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
[ "$MAJOR" -ge __MIN_MACOS__ ] || { echo "${NAME} needs macOS __MIN_MACOS__ or newer. This Mac runs $(sw_vers -productVersion)."; exit 1; }

TARGET="/Applications"
[ -w "${TARGET}" ] || { TARGET="$HOME/Applications"; mkdir -p "${TARGET}"; }

# latest.json names the immutable file of the newest version; the fixed
# latest/ link can be served from a cache for a few minutes after a release.
URL="$(curl -fsSL "$BASE/latest.json" | sed -n 's/.*"url": *"\([^"]*\)".*/\1/p')"
[ -n "$URL" ] || URL="$BASE/latest/__FILE__-macos.dmg"

echo "Downloading ${NAME}…"
curl -fL --progress-bar -o "$WORK/app.dmg" "$URL"
hdiutil attach -nobrowse -readonly -quiet -mountpoint "$WORK/volume" "$WORK/app.dmg"

# An open copy would keep running the old version. Some of these apps only hide
# to the menu bar on Quit, so the process is stopped by its path.
pkill -f "/$APP/Contents/MacOS/" >/dev/null 2>&1 || true
sleep 1

rm -rf "${TARGET:?}/$APP"
cp -R "$WORK/volume/$APP" "${TARGET}/"
xattr -dr com.apple.quarantine "${TARGET}/$APP" 2>/dev/null || true

echo "Installed in ${TARGET}. Opening…"
open "${TARGET}/$APP"
