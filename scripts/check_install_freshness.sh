#!/usr/bin/env bash
# Does the installed extension match the tree being tested?
#
# The mounted suites measure whatever lives in /Applications, not what was
# just built -- and a suite that silently measures last week's build is worse
# than one that refuses to run. This compares code-signature CDHashes, which
# identify the exact binaries: same CDHash, same code.
#
# Warns by default (a deliberate old-build red run is a legitimate step of
# red-first testing); EXT4_REQUIRE_FRESH=1 turns the warning into a failure.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILT="$ROOT/build/Ext4Mac.app/Contents/Extensions/Ext4FS.appex"
INSTALLED="/Applications/Ext4Mac.app/Contents/Extensions/Ext4FS.appex"

cdhash() { codesign -dvvv "$1" 2>&1 | awk -F= '/^CDHash=/{print $2; exit}'; }

[ -d "$INSTALLED" ] || { echo "freshness: nothing installed at $INSTALLED"; exit 1; }

if [ ! -d "$BUILT" ]; then
  # Nothing local to compare against -- common right after `make clean`.
  # Say so rather than pretending to have checked anything. Under
  # EXT4_REQUIRE_FRESH (the hardware-day gate) an uncheckable install is a
  # failed check, not a pass: "could not verify" and "verified" must not
  # be the same green.
  echo "freshness: no built appex in build/ to compare against"
  [ "${EXT4_REQUIRE_FRESH:-0}" = "1" ] && exit 1
  exit 0
fi

built=$(cdhash "$BUILT")
installed=$(cdhash "$INSTALLED")

if [ -z "$built" ] || [ -z "$installed" ]; then
  echo "freshness: could not read a CDHash (built='$built' installed='$installed')"
  [ "${EXT4_REQUIRE_FRESH:-0}" = "1" ] && exit 1
  exit 0
fi

if [ "$built" = "$installed" ]; then
  echo "freshness: installed extension matches the built tree ($installed)"
  exit 0
fi

echo "freshness: INSTALLED EXTENSION IS NOT THIS BUILD"
echo "  built:     $built"
echo "  installed: $installed"
echo "  the mounted suites will measure the installed build; run 'make install'"
[ "${EXT4_REQUIRE_FRESH:-0}" = "1" ] && exit 1
exit 0
