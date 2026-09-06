#!/usr/bin/env bash
# Build a distributable disk image: the signed app, an Applications symlink to
# drag it onto, and the first-run guide.
#
# The DMG carries only the app. The optional Disk Utility bundle installs
# with sudo, which a drag-install cannot do -- the guide covers it.
#
# Usage: make_dmg.sh <app-path> <out.dmg> [volname]
set -euo pipefail

APP="${1:?usage: make_dmg.sh <app> <out.dmg> [volname]}"
OUT="${2:?usage: make_dmg.sh <app> <out.dmg> [volname]}"
VOLNAME="${3:-open_ext4 for Mac}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GUIDE="$ROOT/Packaging/dmg/First-Run Guide.txt"

[ -d "$APP" ]    || { echo "no app at $APP (run: make sign)"; exit 1; }
[ -f "$GUIDE" ]  || { echo "missing $GUIDE"; exit 1; }

# The app must be signed and sealed before it goes in, or notarization has
# nothing valid to attest. Fail loudly rather than shipping an unsigned bundle.
if ! codesign --verify --deep --strict "$APP" 2>/dev/null; then
    echo "$APP does not pass codesign --verify; run 'make sign' first"
    exit 1
fi

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/ext4-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

# Preserve the app's signature: ditto keeps extended attributes and the seal,
# which a plain cp can strip.
ditto "$APP" "$STAGE/$(basename "$APP")"
cp "$GUIDE" "$STAGE/First-Run Guide.txt"
# GPL distribution carries its license with the binary, sold or given away.
cp "$ROOT/LICENSE" "$STAGE/LICENSE.txt"
ln -s /Applications "$STAGE/Applications"

rm -f "$OUT"
mkdir -p "$(dirname "$OUT")"

# UDZO: compressed and read-only, the format for distribution. A larger
# --format has no benefit for a 1 MB app.
hdiutil create \
    -volname "$VOLNAME" \
    -srcfolder "$STAGE" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "$OUT" >/dev/null

# The image itself gets a signature, with the identity the app was signed
# with. Without it notarization still says Accepted and the ticket still
# staples -- the app inside is signed -- but Gatekeeper's assessment of the
# disk image (`spctl -a -t open --context context:primary-signature`) answers
# "rejected, source=no usable signature", which is how the first tagged
# release failed after its notarization had succeeded (2026-09-06).
if [ -n "${SIGN_ID:-}" ]; then
    codesign --sign "$SIGN_ID" --timestamp \
        ${SIGN_KEYCHAIN:+--keychain "$SIGN_KEYCHAIN"} "$OUT"
    codesign --verify "$OUT" || { echo "the DMG did not sign"; exit 1; }
    echo "signed $OUT as $SIGN_ID"
else
    echo "note: SIGN_ID not set; the DMG is unsigned and Gatekeeper will reject it"
fi
echo "built $OUT ($(du -h "$OUT" | cut -f1))"
