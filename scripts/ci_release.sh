#!/usr/bin/env bash
# The remote half of a release: sign, notarize, staple, verify, publish.
#
# Runs on a macOS runner from .github/workflows/release.yml, on a v* tag or a
# manual dispatch. `make release VERSION=x.y.z` is the local half -- it wrote
# VERSION, checked the changelog, built and signed here, committed and tagged;
# pushing the tag is what starts this.
#
# Everything secret arrives in the environment and is used once:
#
#   DEVELOPER_ID_P12            base64 of the Developer ID Application .p12
#   DEVELOPER_ID_P12_PASSWORD   its password
#   EXT_PROVISIONING_PROFILE    base64 of Extension/Ext4FS.provisionprofile
#   APP_PROVISIONING_PROFILE    base64 of App/Ext4Mac.provisionprofile
#   NOTARY_KEY                  base64 of the App Store Connect API key (.p8)
#   NOTARY_KEY_ID, NOTARY_ISSUER   its id and issuer
#   GITHUB_TOKEN                to create the release (gh)
#
# The certificate goes into a temporary keychain that the workflow deletes in
# an always() step whether this succeeds or not; nothing is written to the
# login keychain. DRY_RUN=1 stops after the signed, checked DMG: it proves the
# signing path without notarizing or publishing anything, which is how the
# workflow is tested on a branch.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DRY_RUN="${DRY_RUN:-}"
KEYCHAIN="${RUNNER_TEMP:-/tmp}/ext4-release.keychain-db"
KEYCHAIN_PASSWORD="$(uuidgen)"

need() { [ -n "${!1:-}" ] || { echo "release: missing $1"; exit 1; }; }
for v in DEVELOPER_ID_P12 DEVELOPER_ID_P12_PASSWORD EXT_PROVISIONING_PROFILE APP_PROVISIONING_PROFILE; do need "$v"; done
[ -n "$DRY_RUN" ] || for v in NOTARY_KEY NOTARY_KEY_ID NOTARY_ISSUER GITHUB_TOKEN; do need "$v"; done

echo "release: $(cat VERSION) at $(git rev-parse --short HEAD)${DRY_RUN:+ (dry run)}"

# ---------------------------------------------------------------- keychain --
# A fresh keychain, unlocked, first in the search list, so codesign finds the
# identity and nothing else on the runner can. The password is random and
# never printed; the keychain file is removed by the workflow afterwards.
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 3600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
P12="$(mktemp)"; printf '%s' "$DEVELOPER_ID_P12" | base64 --decode > "$P12"
security import "$P12" -k "$KEYCHAIN" -P "$DEVELOPER_ID_P12_PASSWORD" \
  -T /usr/bin/codesign -T /usr/bin/security >/dev/null
rm -f "$P12"
security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')
identity="$(security find-identity -v -p codesigning "$KEYCHAIN" | awk -F'"' '/Developer ID Application/{print $2; exit}')"
[ -n "$identity" ] || { echo "release: no Developer ID Application identity in the imported .p12"; exit 1; }
echo "release: signing as $identity"

# ---------------------------------------------------------------- profiles --
printf '%s' "$EXT_PROVISIONING_PROFILE" | base64 --decode > Extension/Ext4FS.provisionprofile
printf '%s' "$APP_PROVISIONING_PROFILE" | base64 --decode > App/Ext4Mac.provisionprofile

# ------------------------------------------------------------------- build --
make patch >/dev/null
make app sign check-signing dmg SIGN_ID="$identity" SIGN_KEYCHAIN="$KEYCHAIN"
bash scripts/check_release.sh
DMG="$(ls build/Ext4Mac-*.dmg | head -1)"
echo "release: built $DMG"

if [ -n "$DRY_RUN" ]; then
  echo "release: dry run -- signed and checked, not notarized, not published"
  exit 0
fi

# ---------------------------------------------------------------- notarize --
KEY="$(mktemp -d)/AuthKey.p8"; printf '%s' "$NOTARY_KEY" | base64 --decode > "$KEY"
xcrun notarytool submit "$DMG" --key "$KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait
rm -f "$KEY"
xcrun stapler staple "$DMG"
spctl -a -vvv -t open --context context:primary-signature "$DMG"

# ----------------------------------------------------------------- publish --
version="$(cat VERSION)"
notes="$(mktemp)"
# The changelog section for this version, verbatim, as the release notes.
awk -v v="$version" '$0 ~ "^## \\["v"\\]"{p=1; next} /^## \[/{p=0} p' CHANGELOG.md > "$notes"
gh release create "v$version" "$DMG" --title "v$version" --notes-file "$notes"
echo "release: published v$version"
