#!/usr/bin/env bash
# Is the built app the release it claims to be?
#
# Three facts, each from its own source, that have to agree before a tag is
# pushed: the VERSION file, the version stamped into the built bundles, and
# the CHANGELOG section a release is not allowed to exist without. And when
# HEAD is tagged, the tag has to be this version -- a v0.2.0 tag on a tree
# whose VERSION says 0.1.0 is the kind of mismatch that ships.
#
#   bash scripts/check_release.sh              # against the tree's VERSION
#   VERSION=9.9.9 bash scripts/check_release.sh  # must FAIL: the red-first
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/Tests/lib.sh"

APP="$ROOT/build/Ext4Mac.app"
APPEX="$APP/Contents/Extensions/Ext4FS.appex"
want="${VERSION:-$(tr -d '[:space:]' < "$ROOT/VERSION")}"

echo "release check for $want"
echo ""

[ -d "$APP" ] || { echo "no built app at $APP; run 'make app' first"; exit 1; }

got=$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist" 2>/dev/null)
[ "$got" = "$want" ] && ok "the app's CFBundleShortVersionString is $want" \
                     || bad "the app's CFBundleShortVersionString is $want" "it is '${got:-?}'"

if [ -d "$APPEX" ]; then
  gotx=$(plutil -extract CFBundleShortVersionString raw -o - "$APPEX/Contents/Info.plist" 2>/dev/null)
  [ "$gotx" = "$want" ] && ok "and the extension's is the same" \
                        || bad "and the extension's is the same" "it is '${gotx:-?}'"
else
  bad "the extension is inside the app" "no $APPEX"
fi

bn=$(plutil -extract CFBundleVersion raw -o - "$APP/Contents/Info.plist" 2>/dev/null)
[ -n "$bn" ] && [ "$bn" != "0" ] && ok "the build number is stamped ($bn)" \
                                  || bad "the build number is stamped" "CFBundleVersion is '${bn:-?}' -- a placeholder"

grep -q "^## \[$want\]" "$ROOT/CHANGELOG.md" \
  && ok "CHANGELOG.md has a [$want] section" \
  || bad "CHANGELOG.md has a [$want] section" "a release is not allowed to exist without one"

# A signed app has to carry the shared keychain group, or `Ext4Mac forget`
# and `list` cannot reach the keys the extension stored -- a security gap,
# not a cosmetic one. This went wrong silently once: the release workflow
# exported the profile secret under the name sign.sh used as a path override,
# and every CI build signed the app without the entitlement while the log
# said the profile was missing. Only a Developer ID signature is judged; an
# unsigned or ad-hoc build from `make app` has nothing to check yet.
# -dvv, not -dv: the Authority= lines that name the signer appear only at the
# second verbosity. And captured, not piped into grep -q: under pipefail a
# grep that quits on its first match hands codesign a SIGPIPE, the pipeline
# reports failure, and a Developer-ID build was judged "not signed here".
sig=$(codesign -dvv "$APP" 2>&1 || true)
if grep -q "Authority=Developer ID Application" <<<"$sig"; then
  ents=$(codesign -d --entitlements :- "$APP" 2>/dev/null)
  if grep -q "keychain-access-groups" <<<"$ents" && grep -q "\.dev\.h3ct0r\.ext4mac\.shared" <<<"$ents"; then
    ok "the signed app carries the shared keychain group"
  else
    bad "the signed app carries the shared keychain group" \
        "no keychain-access-groups entitlement: forget/list cannot reach the extension's keys on this build"
  fi
else
  echo "  (app is not Developer-ID signed here; the keychain-group cell applies to a signed build)"
fi

tag=$(git -C "$ROOT" describe --tags --exact-match 2>/dev/null || true)
if [ -n "$tag" ]; then
  [ "$tag" = "v$want" ] && ok "HEAD is tagged $tag, which is this version" \
                        || bad "HEAD's tag matches the version" "tagged $tag, VERSION says $want"
else
  ok "HEAD is not tagged (fine before 'make release')"
fi

echo ""
finish
