#!/bin/bash
# Builds dist/Screenshots.app with swiftc (no Xcode needed: Command Line Tools are enough).
#   scripts/build.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(cat "$ROOT/VERSION")"
APP="$ROOT/dist/Screenshots.app"

# With only the Command Line Tools, the macOS 27 SDK turns @State into a macro whose plugin
# ships with Xcode alone; the 26.x SDK builds the same app for macOS 14 and later.
SDK_ARGS=()
# Asked as "only the Command Line Tools?": Xcode is not always Xcode.app (Xcode_26.0.app on
# the Actions runners), and an ls that finds nothing must not stop the script under pipefail.
if xcode-select -p | grep -q CommandLineTools; then
    SDK="$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.*.sdk 2>/dev/null | sort -V | tail -1 || true)"
    # An if, not `[ … ] && …`: bash 3.2 (macOS) exits under set -e when that is the
    # last command of the block and the test is false.
    if [ -n "$SDK" ]; then SDK_ARGS=(-sdk "$SDK"); fi
fi
mkdir -p "$ROOT/.build"
swiftc -O ${SDK_ARGS[@]+"${SDK_ARGS[@]}"} -target arm64-apple-macosx14.0 -parse-as-library -swift-version 5 \
    -module-name Screenshots $(find "$ROOT/Sources" -name '*.swift') -o "$ROOT/.build/Screenshots"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/Screenshots" "$APP/Contents/MacOS/Screenshots"
# The symbols out of the shipped binary: half its size. Crash reports still locate each frame.
strip -rSTx "$APP"/Contents/MacOS/*
sed "s/__VERSION__/$VERSION/g" "$ROOT/scripts/Info.plist" > "$APP/Contents/Info.plist"
cp -R "$ROOT/Resources/." "$APP/Contents/Resources/"

# Three ways to sign, best first:
#   1. Developer ID Application (the official build), with hardened runtime and a secure
#      timestamp, which notarization requires.
#   2. "Screenshots Local Signing" (scripts/signing-identity.sh): a fixed certificate for a clone.
#   3. Ad hoc, when neither exists.
# The same certificate on every build keeps the Screen Recording permission granted across
# updates; ad hoc ties it to each build's hash, so macOS asks again every time.
# `|| true`: without a certificate (a fresh clone) security exits 44, and pipefail would stop
# the build instead of falling back.
# Screen Recording and Accessibility need no entitlement; under the hardened runtime the
# microphone does (scripts/Screenshots.entitlements). There is no camera capture.
DEVELOPER_ID="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application: .*([A-Z0-9]*)\)"/\1/p' | head -1 || true)"
LOCAL_IDENTITY="Screenshots Local Signing"
if [ -n "$DEVELOPER_ID" ]; then
    SIGN="$DEVELOPER_ID"
elif security find-certificate -c "$LOCAL_IDENTITY" >/dev/null 2>&1; then
    SIGN="$LOCAL_IDENTITY"
else
    echo "warning: no Developer ID nor '$LOCAL_IDENTITY' certificate (scripts/signing-identity.sh); signing ad hoc" >&2
    SIGN="-"
fi
TIMESTAMP=(); if [ "$SIGN" != "-" ]; then TIMESTAMP=(--timestamp); fi
codesign --force --options runtime ${TIMESTAMP[@]+"${TIMESTAMP[@]}"} \
    --entitlements "$ROOT/scripts/Screenshots.entitlements" --sign "$SIGN" "$APP"
echo "signed with: $([ "$SIGN" = "-" ] && echo "ad hoc" || echo "$SIGN")"
echo "Screenshots $VERSION → $APP"
