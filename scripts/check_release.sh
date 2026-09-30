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

# The licences ship inside the app, byte for byte what the tree says: the GPL
# and lwext4's BSD clause 2 both require the notices with the binary, and a
# stale copy is a wrong notice.
for f in LICENSE:LICENSE.txt THIRD_PARTY_NOTICES.md:THIRD_PARTY_NOTICES.txt; do
  src="$ROOT/${f%%:*}"; dst="$APP/Contents/Resources/${f##*:}"
  cmp -s "$src" "$dst" && ok "the app carries ${f##*:}, current" \
                       || bad "the app carries ${f##*:}, current" "missing or different from ${f%%:*}"
done
# One minimum OS, the Makefile's, in both bundles -- it said 15.4, where this
# was never built or tested, and nothing compared it with anything.
floor=$(sed -nE 's/^DEPLOY_TARGET \?= *([0-9.]+).*/\1/p' "$ROOT/Makefile")
for b in "$APP" "$APPEX"; do
  m=$(plutil -extract LSMinimumSystemVersion raw -o - "$b/Contents/Info.plist" 2>/dev/null)
  [ -n "$floor" ] && [ "$m" = "$floor" ] && ok "$(basename "$b") requires macOS $floor, as the build targets" \
    || bad "$(basename "$b") requires macOS ${floor:-?}, as the build targets" "LSMinimumSystemVersion is '${m:-?}'"
done
# The Disk Utility bundle inside the app says the release it came with.
fsv=$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Resources/ext4.fs/Contents/Info.plist" 2>/dev/null)
[ "$fsv" = "$want" ] && ok "the bundled ext4.fs says $want" \
                     || bad "the bundled ext4.fs says $want" "it says '${fsv:-?}'"
bn=$(plutil -extract CFBundleVersion raw -o - "$APP/Contents/Info.plist" 2>/dev/null)
[ -n "$bn" ] && [ "$bn" != "0" ] && ok "the build number is stamped ($bn)" \
                                  || bad "the build number is stamped" "CFBundleVersion is '${bn:-?}' -- a placeholder"

grep -q "^## \[$want\]" "$ROOT/CHANGELOG.md" \
  && ok "CHANGELOG.md has a [$want] section" \
  || bad "CHANGELOG.md has a [$want] section" "a release is not allowed to exist without one"

# The release notes, built here from what the tag will publish. A relative
# link that works in CHANGELOG.md leads nowhere from a release page, and the
# notes once named a macOS floor two major versions behind the build's.
# Judged when this version's DMG is there, as it is in `make release` and the
# release workflow; `make app` alone has none.
DMGF="$ROOT/build/Ext4Mac-$want.dmg"
if [ -f "$DMGF" ]; then
  if notes=$(bash "$ROOT/scripts/release_notes.sh" "$want" "$DMGF" 2>&1); then
    ok "the release notes build"
    rel=$(grep -oE ']\([^)]*\)' <<<"$notes" | grep -vE '^]\((https://|#)' | head -1)
    [ -z "$rel" ] && ok "every link in the release notes leads somewhere" \
                  || bad "every link in the release notes leads somewhere" "$rel resolves against the release page"
    stale=$(grep -oE 'macOS [0-9.]+ or later' <<<"$notes" | grep -v "^macOS ${floor%.0} or later" | head -1)
    [ -z "$stale" ] && ok "the release notes name no floor but macOS ${floor%.0}" \
                    || bad "the release notes name no floor but macOS ${floor%.0}" "they say '$stale'"
  else
    bad "the release notes build" "$notes"
  fi
else
  echo "  (no $(basename "$DMGF") here; the release-notes cells apply once it is built)"
fi

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

# The DMG has to carry a signature of its own. Notarization accepts a disk
# image whose app is signed, the ticket staples, and then `spctl -t open`
# assesses the IMAGE and answers "rejected, source=no usable signature" --
# which is what the first tagged release did (v0.1.0's first run,
# 2026-09-06), after notarization had said Accepted. Judged only when a DMG
# is there and the app is Developer-ID signed; `make app` alone has neither.
# This version's DMG, by name: the first of build/Ext4Mac-*.dmg is whichever
# sorts first, and 0.10.0 sorts before 0.2.0.
if [ -f "$DMGF" ] && grep -q "Authority=Developer ID Application" <<<"$sig"; then
  dsig=$(codesign -dvv "$DMGF" 2>&1 || true)
  if grep -q "Authority=Developer ID Application" <<<"$dsig"; then
    ok "the DMG carries its own Developer ID signature"
  else
    bad "the DMG carries its own Developer ID signature" \
        "$(basename "$DMGF"): $(head -1 <<<"$dsig") -- spctl will answer 'no usable signature'"
  fi
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
