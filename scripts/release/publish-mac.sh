#!/usr/bin/env bash
#
# publish-mac.sh — puts a Mac app's .dmg on blob.ciromaciel.click.
#
#   scripts/release/publish-mac.sh <id> "<App Name>" <dmg> <version> <min macOS major>
#
# Run by .github/workflows/release.yml after the build, only when VERSION is newer
# than the published one.
#
# In the R2 bucket (blob.ciromaciel.click), under tools/<id>/:
#
#   <version>/<File>-<version>-macos.dmg   every release, kept, immutable
#   latest/<File>-macos.dmg                the fixed link the site points to
#   install.sh                             the one-line installer (install-mac.sh, filled in)
#   latest.json                            {version, pub_date, url} — last
#
# <File> is the name with dashes ("Text to Speech" → Text-to-Speech).
# latest.json goes up last, after everything it names. A version not greater
# than the published one is refused: bump the app's version first.
#
# Needs aws (CLI), R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY and
# CLOUDFLARE_ACCOUNT_ID (repository secrets). PREFIX overrides the folder, for a
# dry run (tools/<id>-test).

set -euo pipefail

ID="$1"
NAME="$2"
DMG="$3"
VERSION="$4"
MIN_MACOS="$5"

BUCKET="${BUCKET:-ciromaciel-blob}"
PREFIX="${PREFIX:-tools/$ID}"
PUBLIC="https://blob.ciromaciel.click"
BASE="$PUBLIC/$PREFIX"
PAGE="https://ciromaciel.click/tools/$ID"
FILE="${NAME// /-}"
HERE="$(cd "$(dirname "$0")" && pwd)"

fail() { echo "✗ $1" >&2; exit 1; }

[ -f "$DMG" ] || fail "no .dmg at $DMG — build it first"
hdiutil imageinfo "$DMG" >/dev/null 2>&1 || fail "$DMG is not a disk image"

PUBLISHED="$(curl -sf "$BASE/latest.json" | sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' || true)"
if [ -n "$PUBLISHED" ]; then
    HIGHEST="$(printf '%s\n%s\n' "$PUBLISHED" "$VERSION" | sort -V | tail -1)"
    if [ "$VERSION" = "$PUBLISHED" ] || [ "$HIGHEST" != "$VERSION" ]; then
        fail "version $VERSION is not greater than the published $PUBLISHED — bump the version"
    fi
fi
echo "Publishing $NAME $VERSION (published: ${PUBLISHED:-none}) to $BASE"

export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION=auto AWS_REQUEST_CHECKSUM_CALCULATION=when_required AWS_RESPONSE_CHECKSUM_VALIDATION=when_required
ENDPOINT="https://$CLOUDFLARE_ACCOUNT_ID.r2.cloudflarestorage.com"
put() { # put <file> <key> <content-type> <cache-control>
    aws s3 cp "$1" "s3://$BUCKET/$PREFIX/$2" --endpoint-url "$ENDPOINT" --only-show-errors \
        --content-type "$3" --cache-control "$4"
    echo "  ↑ $PREFIX/$2"
}
KEEP="public, max-age=31536000, immutable"
FRESH="public, max-age=300"

INSTALL="$(mktemp)"
MANIFEST="$(mktemp)"
trap 'rm -f "$INSTALL" "$MANIFEST"' EXIT

sed -e "s|__NAME__|$NAME|g" -e "s|__BASE__|$BASE|g" -e "s|__PAGE__|$PAGE|g" \
    -e "s|__FILE__|$FILE|g" -e "s|__MIN_MACOS__|$MIN_MACOS|g" "$HERE/install-mac.sh" >"$INSTALL"
grep -q '__[A-Z_]*__' "$INSTALL" && fail "install.sh still has a field to fill"
bash -n "$INSTALL" || fail "install.sh does not parse"

printf '{\n  "version": "%s",\n  "pub_date": "%s",\n  "url": "%s"\n}\n' \
    "$VERSION" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$BASE/$VERSION/$FILE-$VERSION-macos.dmg" >"$MANIFEST"

put "$DMG"      "$VERSION/$FILE-$VERSION-macos.dmg" application/x-apple-diskimage "$KEEP"
put "$DMG"      "latest/$FILE-macos.dmg"            application/x-apple-diskimage "$FRESH"
put "$INSTALL"  "install.sh"                        "text/plain; charset=utf-8"   "$FRESH"
put "$MANIFEST" "latest.json"                       application/json              "public, max-age=60"

# What a person gets is what was built: the fixed link serves these bytes.
WANT="$(stat -f %z "$DMG")"
GOT="$(curl -sfI "$BASE/latest/$FILE-macos.dmg?v=$VERSION" | awk 'tolower($1)=="content-length:"{print $2}' | tr -d '\r')"
[ "$GOT" = "$WANT" ] || fail "latest/$FILE-macos.dmg has $GOT bytes online, $WANT here"

echo "✓ $NAME $VERSION published — $BASE/latest.json"
echo "  curl -fsSL $BASE/install.sh | bash"
