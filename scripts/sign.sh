#!/usr/bin/env bash
# Code-sign the app bundle and its FSKit extension.
#
# FSKit modules need the restricted entitlement com.apple.developer.fskit.fsmodule,
# which the system only honours when it is authorised by an embedded provisioning
# profile from a paid Apple Developer account. See docs/SIGNING.md.
set -euo pipefail

APP="${1:?usage: sign.sh <App.app> <signing-identity>}"
IDENTITY="${2:--}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APPEX="$APP/Contents/Extensions/Ext4FS.appex"
ENTITLEMENTS="$ROOT/Extension/Ext4FS.entitlements"
PROFILE="${PROVISIONING_PROFILE:-$ROOT/Extension/Ext4FS.provisionprofile}"

[ -d "$APP" ]   || { echo "error: $APP not found — run 'make app' first"; exit 1; }
[ -d "$APPEX" ] || { echo "error: extension missing from $APP"; exit 1; }

if [ "$IDENTITY" = "-" ]; then
  cat >&2 <<'WARN'
warning: signing ad-hoc (identity "-").

  An ad-hoc signature CANNOT carry the com.apple.developer.fskit.fsmodule
  entitlement, so macOS will refuse to load the extension. This is only useful
  for checking that the bundle is well-formed.

  For a working build, pass a Developer ID identity:
      make sign SIGN_ID="Developer ID Application: Your Name (TEAMID)"

WARN
fi

# The provisioning profile is what authorises the restricted entitlement.
if [ -f "$PROFILE" ]; then
  cp "$PROFILE" "$APPEX/Contents/embedded.provisionprofile"
  echo "embedded provisioning profile"
elif [ "$IDENTITY" != "-" ]; then
  echo "warning: no provisioning profile at $PROFILE" >&2
  echo "         the extension will likely fail to load; see docs/SIGNING.md" >&2
fi

# Sign inside-out: the extension first, then the app that contains it.
echo "signing extension..."
codesign --force --timestamp --options runtime \
         --entitlements "$ENTITLEMENTS" \
         --sign "$IDENTITY" \
         "$APPEX"

echo "signing app..."
codesign --force --timestamp --options runtime \
         --sign "$IDENTITY" \
         "$APP"

echo
echo "verifying..."
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/  /'
echo
echo "entitlements on the extension:"
codesign -d --entitlements - --xml "$APPEX" 2>/dev/null | plutil -p - | sed 's/^/  /'
