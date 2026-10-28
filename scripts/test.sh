#!/bin/bash
# The end-to-end and memory tests on an invisible display, so the person keeps working:
# windows, overlays and thumbnails go to a virtual display beside the main one, nothing takes
# the keyboard focus, and copies go to a clipboard of the tests.
#   scripts/test.sh e2e [evidence-dir]
#   scripts/test.sh memtest
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-e2e}"
mkdir -p "$ROOT/.build"
clang -fobjc-arc -framework Foundation -framework CoreGraphics "$ROOT/scripts/virtual-display.m" -o "$ROOT/.build/virtual-display" 2>/dev/null
FIFO="$(mktemp -u)"; mkfifo "$FIFO"
"$ROOT/.build/virtual-display" > "$FIFO" &
VD=$!
APP=""
# Whatever ends this script ends the test app and the display together.
# Each step tolerates "already gone": under set -e a failing kill in the trap would end the
# script with 1 after a green run.
trap '[ -n "$APP" ] && kill -9 $APP 2>/dev/null || true; kill $VD 2>/dev/null || true; sleep 0.5; pkill -9 -x virtual-display || true; rm -f "$FIFO"' EXIT INT TERM HUP
read -r DISPLAY_ID < "$FIFO"
sleep 2   # let AppKit see the new screen
echo "virtual display $DISPLAY_ID"
# MallocSpaceEfficient as the app's Info.plist sets it (LSEnvironment) when macOS opens it.
MallocSpaceEfficient=1 SCREENSHOTS_TEST_DISPLAY="$DISPLAY_ID" "$ROOT/dist/Screenshots.app/Contents/MacOS/Screenshots" "--$MODE" "${@:2}" &
APP=$!
wait $APP
