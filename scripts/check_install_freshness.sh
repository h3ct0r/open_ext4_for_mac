#!/usr/bin/env bash
# Does the installed extension match the tree being tested?
#
# The mounted suites measure whatever lives in /Applications, not what was
# just built -- and a suite that silently measures last week's build is worse
# than one that refuses to run. This compares code-signature CDHashes, which
# identify the exact binaries: same CDHash, same code.
#
# Same code as WHAT, though. Comparing the install against build/ answers only
# half the question, and the half that goes stale quietly: skip `make app` and
# both sides are equally old, so the check goes green on an install that is
# several commits behind. That is how this stood while the tree moved from
# 469167f to d927d77 with preflight reporting the extension current. So the
# tree's own revision is the second comparison, against the Ext4BuildID the
# Makefile stamps into the bundle -- the same fact preflight already checks for
# ext4dump, and for the same reason.
#
# Warns by default (a deliberate old-build red run is a legitimate step of
# red-first testing); EXT4_REQUIRE_FRESH=1 turns the warning into a failure.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILT="$ROOT/build/Ext4Mac.app/Contents/Extensions/Ext4FS.appex"
INSTALLED="/Applications/Ext4Mac.app/Contents/Extensions/Ext4FS.appex"

cdhash() { codesign -dvvv "$1" 2>&1 | awk -F= '/^CDHash=/{print $2; exit}'; }
buildid() { plutil -extract Ext4BuildID raw "$1/Contents/Info.plist" 2>/dev/null; }

# A CDHash says which binary is on disk. It does not say which binary is
# RUNNING: a mounted volume is served by the extension process that started
# with it, so a fresh install sits unused until the volume is ejected and
# re-attached. That gap cost a session -- a field log line was read as
# evidence about the new build when the old process was still answering.
running_note() {
  pgrep -x Ext4FS >/dev/null 2>&1 || return 0
  echo "  note: an Ext4FS process is running; if a volume is mounted it is"
  echo "        still served by the binary it started with. Eject and replug"
  echo "        before believing any log line about this build."
}

[ -d "$INSTALLED" ] || { echo "freshness: nothing installed at $INSTALLED"; exit 1; }

# The question is "is the installed extension the code in this tree?", and
# neither of the two comparisons below asks it directly. The CDHash match asks
# whether make install ran after make app; the stamp asks whether it ran at
# HEAD. Both are proxies, and both need build/, which every validation run
# deletes -- so after any soak the gate could only say "cannot be checked".
#
# What goes into the appex is a fixed set of paths. If none of them changed
# between the stamped commit and HEAD, and none is edited uncommitted, the
# installed binary IS this code and only its label is older. That is asked
# first, from git alone. It matters because the alternative -- reinstall to
# fix the label -- registers a new bundle, which can drop the extension's
# user approval, and did, three times in one day, for a byte-identical
# binary each time.
#
# Conservative on purpose: a dirty stamp was built from edits that no commit
# records and cannot be compared to anything, so it falls through.
APPEX_SOURCES="Extension Core Shared App patches Makefile scripts/sign.sh"
stamped=$(buildid "$INSTALLED" || echo unstamped)
head=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null)
if [ -n "$head" ] && [ "$stamped" != "unstamped" ]; then
  case "$stamped" in
    *-dirty) ;;
    *)
      if git -C "$ROOT" rev-parse --verify -q "$stamped^{commit}" >/dev/null 2>&1 \
         && git -C "$ROOT" diff --quiet "$stamped" HEAD -- $APPEX_SOURCES \
         && git -C "$ROOT" diff --quiet HEAD -- $APPEX_SOURCES; then
        if [ "$stamped" = "$head" ]; then
          echo "freshness: installed extension is this tree ($stamped)"
        else
          echo "freshness: installed extension is this code (stamped $stamped, tree $head;"
          echo "           nothing that goes into the appex changed between them)"
          echo "  note: log lines will carry [build $stamped]. Reinstall only if that"
          echo "        matters for a hardware session's evidence."
        fi
        running_note
        exit 0
      fi ;;
  esac
fi

if [ ! -d "$BUILT" ]; then
  # Nothing local to compare against -- common right after `make clean`.
  # Say so rather than pretending to have checked anything. Under
  # EXT4_REQUIRE_FRESH (the hardware-day gate) an uncheckable install is a
  # failed check, not a pass: "could not verify" and "verified" must not
  # be the same green.
  echo "freshness: no built appex in build/ to compare against"
  # Naming the likely cause, because the caller's remedy line says "run make
  # install" and that is the wrong move for the common one. A validation run
  # -- and therefore every soak round -- begins with `make clean`, so asking
  # this question while one is in flight always lands here. Reinstalling then
  # rebuilds and reinstalls underneath the run.
  if pgrep -f "run_full_validation.sh" >/dev/null 2>&1; then
    echo "  a validation run is in flight and has just cleaned build/."
    echo "  Nothing is wrong with the install; wait for it rather than"
    echo "  rebuilding underneath it."
  else
    echo "  (usual cause: make clean. 'make app' rebuilds it.)"
  fi
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
  # The Makefile stamps the revision the same way for every artifact, `-dirty`
  # included, so a dirty tree legitimately never matches an install: an edited
  # tree is not what is running, and saying so is the point.
  stamped=$(buildid "$INSTALLED" || echo unstamped)
  head=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null)
  [ -n "$head" ] && { git -C "$ROOT" diff --quiet 2>/dev/null || head="$head-dirty"; }

  if [ -z "$head" ]; then
    # No git to ask -- a tarball, or a detached checkout. The CDHash match is
    # all there is, and it is worth having; say what was not checked.
    echo "freshness: installed extension matches the built tree ($installed)"
    echo "  build:     $stamped  (no git revision to compare against)"
    running_note
    exit 0
  fi

  if [ "$stamped" = "$head" ]; then
    echo "freshness: installed extension matches this tree ($stamped)"
    running_note
    exit 0
  fi

  echo "freshness: THE BUILT TREE ITSELF IS STALE"
  echo "  installed: $stamped  (and build/ agrees, which is why the"
  echo "             CDHash comparison alone reports this as current)"
  echo "  tree:      $head"
  echo "  something that goes into the appex changed between them:"
  git -C "$ROOT" diff --name-only "${stamped%-dirty}" HEAD -- $APPEX_SOURCES 2>/dev/null | sed 's/^/    /' | head -8
  echo "  run 'make app && make install'"
  running_note
  [ "${EXT4_REQUIRE_FRESH:-0}" = "1" ] && exit 1
  exit 0
fi

echo "freshness: INSTALLED EXTENSION IS NOT THIS BUILD"
echo "  built:     $built  (build $(buildid "$BUILT" || echo unstamped))"
echo "  installed: $installed  (build $(buildid "$INSTALLED" || echo unstamped))"
echo "  the mounted suites will measure the installed build; run 'make install'"
running_note
[ "${EXT4_REQUIRE_FRESH:-0}" = "1" ] && exit 1
exit 0
