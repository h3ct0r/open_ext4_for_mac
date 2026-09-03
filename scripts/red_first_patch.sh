#!/usr/bin/env bash
# Does this patch actually fix anything?
#
#   bash scripts/red_first_patch.sh 0048
#   bash scripts/red_first_patch.sh 0048 --suite Tests/run_bounds_tests.sh
#
# Reverse-applies one lwext4 patch, rebuilds, runs the hostile-image
# regressions (or a suite you name), and requires them to FAIL. Then it
# repatches, rebuilds, and requires them to PASS. A patch that passes both
# ways is a patch whose test does not test it, and that is a very easy thing
# to write by accident: a fixture that only crashes under a sanitizer, run
# against a release build, is green either way and looks like a regression
# test forever.
#
# THE TRAP THIS SCRIPT EXISTS TO AVOID, which cost an hour before it was
# understood: the build's patch stamp, build/.lwext4-patched, is a prerequisite
# of every object file and depends on the patch FILES. A freshly written patch
# is newer than the stamp, so the stamp rule re-runs -- and that rule re-applies
# every patch that still applies, including the one just reverted. The build
# undoes the revert, silently, and the green that comes back means nothing.
# Touching the stamp after reverting is what pins it.
#
# Destructive to Core/lwext4's working tree, and it puts it back: the EXIT trap
# repatches whatever happens, including on Ctrl-C.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

NUM="${1:-}"
SUITE="Tests/run_fuzz_regressions_tests.sh"
CONFIG_ARG=""
shift || true
while [ $# -gt 0 ]; do
  case "$1" in
    --suite) SUITE="$2"; shift 2 ;;
    --asan)  CONFIG_ARG="CONFIG=debug"; shift ;;
    *) echo "usage: red_first_patch.sh NNNN [--suite PATH] [--asan]"; exit 2 ;;
  esac
done

if [ -z "$NUM" ]; then
  echo "usage: red_first_patch.sh NNNN [--suite PATH] [--asan]"
  exit 2
fi

shopt -s nullglob
matches=(patches/lwext4/"$NUM"-*.patch)
shopt -u nullglob
if [ ${#matches[@]} -ne 1 ]; then
  echo "red-first: expected exactly one patch matching $NUM, found ${#matches[@]}"
  printf '  %s\n' "${matches[@]}"
  exit 2
fi
PATCH="${matches[0]}"

# Restore the submodule AND relink the binaries.
#
# Repatching the source alone is not enough, and the difference is not
# cosmetic: an early exit leaves build/bin/ext4dump built from the REVERTED
# source while Core/lwext4 says otherwise, and the next suite anyone runs
# reports the bug this script just reverted as a live finding. That happened,
# and twenty minutes went into chasing a heap-buffer-overflow in
# ext4_ext_binsearch that had been fixed a hundred commits earlier.
restore() {
  echo ""
  echo "── restoring the submodule and relinking"
  make repatch 2>&1 | tail -2
  make tools $CONFIG_ARG >/dev/null 2>&1 \
    || echo "  WARNING: the rebuild failed; build/bin/ is stale, run 'make tools'"
}
trap restore EXIT

echo "red-first: $PATCH"
echo "  suite: $SUITE${CONFIG_ARG:+  ($CONFIG_ARG)}"
echo ""

echo "── reversing the patch"
if ! git -C Core/lwext4 apply --reverse "$ROOT/$PATCH" 2>&1; then
  echo "red-first: could not reverse-apply $PATCH."
  echo "  The submodule may already differ from pinned-plus-patches;"
  echo "  'make repatch' first, then try again."
  exit 1
fi

# Pin the stamp. See the note at the top: without this the build re-applies
# what was just reverted and the run is meaningless.
touch build/.lwext4-patched 2>/dev/null || true

echo "── rebuilding without it"
if ! ALLOW_UNAPPLIED_PATCHES=1 make tools $CONFIG_ARG > build/red-first-build.log 2>&1; then
  echo "red-first: the build failed without $PATCH:"
  tail -15 build/red-first-build.log | sed 's/^/    /'
  exit 1
fi

# And check the revert actually survived the build, rather than trusting it.
if bash scripts/check_patches.sh >/dev/null 2>&1; then
  echo "red-first: the tree still matches the full patch set after reverting."
  echo "  The build put the patch back -- the stamp was not pinned, or the"
  echo "  patch does not change anything the tree keeps. Nothing was proven."
  exit 1
fi

echo ""
echo "── the suite, which MUST fail"
set +e
ALLOW_UNAPPLIED_PATCHES=1 bash "$SUITE" > build/red-first-red.log 2>&1
red_rc=$?
set -e
grep -E '^  (ok|FAIL)|^passed:' build/red-first-red.log | tail -12 | sed 's/^/    /'
if [ "$red_rc" -eq 0 ]; then
  echo ""
  echo "red-first: THE SUITE PASSED WITHOUT THE PATCH."
  echo "  Whatever it is testing, it is not this fix. Common causes: the"
  echo "  fixture only fails under a sanitizer and this is a release build"
  echo "  (try --asan), or the row's verbs do not reach the changed code."
  exit 1
fi
echo "    -> failed as required (rc=$red_rc)"

echo ""
echo "── repatching and rebuilding"
make repatch > build/red-first-repatch.log 2>&1
if ! make tools $CONFIG_ARG > build/red-first-build.log 2>&1; then
  echo "red-first: the build failed WITH $PATCH, which is a separate problem:"
  tail -15 build/red-first-build.log | sed 's/^/    /'
  exit 1
fi

echo ""
echo "── the suite, which MUST pass"
set +e
bash "$SUITE" > build/red-first-green.log 2>&1
green_rc=$?
set -e
grep -E '^  (ok|FAIL)|^passed:' build/red-first-green.log | tail -12 | sed 's/^/    /'
if [ "$green_rc" -ne 0 ]; then
  echo ""
  echo "red-first: the suite still fails WITH the patch applied (rc=$green_rc)."
  exit 1
fi

echo ""
echo "red-first: $PATCH is proven -- red without it, green with it."
trap - EXIT
bash scripts/check_patches.sh
