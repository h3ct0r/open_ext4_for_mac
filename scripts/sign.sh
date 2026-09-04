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

# The app shares a keychain access group with the extension, so the two can
# hand a master key across without the passphrase ever entering the sandboxed
# process. That entitlement needs a profile issued for the *app's* bundle ID --
# the one we have is for the extension's, and a Developer ID binary that claims
# a keychain group it cannot prove is killed by AMFI the instant it launches,
# with no crash report and nothing in the log.
#
# So the app is signed with the entitlement only when its own profile is
# present. Without one it still works; it just leaves the key in the
# extension's container instead of the keychain. See docs/SIGNING.md.
APP_ENTITLEMENTS="$ROOT/App/Ext4Mac.entitlements"
APP_PROFILE="${APP_PROVISIONING_PROFILE:-$ROOT/App/Ext4Mac.provisionprofile}"

# Optional: sign from a specific keychain.
#
# A login keychain that has accumulated duplicate key entries or unrelated PKI
# (national eID certificates and their chains are a common source) can make
# codesign fail with "unable to build chain to self-signed root" followed by
# errSecInternalComponent, even when the Developer ID chain itself is complete
# and verifies. Pointing at a keychain containing only the signing identity
# avoids that entirely. See docs/SIGNING.md.
KEYCHAIN_ARG=()
if [ -n "${SIGN_KEYCHAIN:-}" ]; then
  KEYCHAIN_ARG=(--keychain "$SIGN_KEYCHAIN")
  echo "using keychain: $SIGN_KEYCHAIN"
fi

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
         ${KEYCHAIN_ARG[@]+"${KEYCHAIN_ARG[@]}"} \
         --sign "$IDENTITY" \
         "$APPEX"

echo "signing app..."
APP_ENTITLEMENT_ARG=()
if [ -f "$APP_PROFILE" ] && [ -f "$APP_ENTITLEMENTS" ]; then
  cp "$APP_PROFILE" "$APP/Contents/embedded.provisionprofile"
  APP_ENTITLEMENT_ARG=(--entitlements "$APP_ENTITLEMENTS")
  echo "  with the shared keychain group (app profile found)"
else
  rm -f "$APP/Contents/embedded.provisionprofile"
  echo "  without the shared keychain group (no App/Ext4Mac.provisionprofile)"
  # Spelling out the consequence, because it is a security one and the line
  # above reads like a detail. The extension keeps master keys in the shared
  # group; an app outside that group cannot see or delete them. So `list`
  # reports no unlocked volumes even when there are some, and `forget`
  # deletes nothing while reporting success -- SecItemDelete answers
  # "no such item", which is indistinguishable from having removed one.
  # A container unlocked once then goes on mounting without a passphrase
  # until the key is removed from the extension's own keychain.
  echo "    NOTE: 'Ext4Mac forget' cannot remove keys the extension stored,"
  echo "          and 'Ext4Mac list' cannot see them. A volume unlocked once"
  echo "          keeps mounting without its passphrase on this build."
fi
# ${arr[@]+"${arr[@]}"}, not "${arr[@]}": under `set -u`, bash 3.2 -- which
# is what macOS ships and the runner uses -- treats the expansion of an EMPTY
# array as an unbound variable and aborts. APP_ENTITLEMENT_ARG is empty
# whenever there is no App/Ext4Mac.provisionprofile (the usual case), so the
# app-signing step died there after the extension signed fine. The guarded
# form expands to nothing when empty and to the elements otherwise.
codesign --force --timestamp --options runtime \
         ${APP_ENTITLEMENT_ARG[@]+"${APP_ENTITLEMENT_ARG[@]}"} \
         ${KEYCHAIN_ARG[@]+"${KEYCHAIN_ARG[@]}"} \
         --sign "$IDENTITY" \
         "$APP"

echo
echo "verifying..."
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/  /'
echo

# codesign only proves the signature is intact. This proves the entitlements
# inside it are authorised, which is the failure that has no symptom.
bash "$ROOT/scripts/verify_signing.sh" "$APP" | sed 's/^/  /'
echo
echo "entitlements on the extension:"
codesign -d --entitlements - --xml "$APPEX" 2>/dev/null | plutil -p - | sed 's/^/  /'
