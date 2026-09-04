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

tag=$(git -C "$ROOT" describe --tags --exact-match 2>/dev/null || true)
if [ -n "$tag" ]; then
  [ "$tag" = "v$want" ] && ok "HEAD is tagged $tag, which is this version" \
                        || bad "HEAD's tag matches the version" "tagged $tag, VERSION says $want"
else
  ok "HEAD is not tagged (fine before 'make release')"
fi

echo ""
finish
