#!/usr/bin/env bash
# Does this fix actually fix anything?
#
#   bash scripts/red_first.sh --id 0048
#   bash scripts/red_first.sh --id 0048 --suite Tests/run_bounds_tests.sh
#   bash scripts/red_first.sh <commit> --asan
#
# Takes one commit, reverts only what it changed under Core/ (lwext4, the
# shim, crypto) -- keeping its tests, fixtures and ledger row -- rebuilds, and
# requires the suite to FAIL. Then puts the code back, rebuilds, and requires
# it to PASS. A fix that passes both ways is a fix whose test does not test
# it, and that is a very easy thing to write by accident: a fixture that only
# crashes under a sanitizer, run against a release build, is green either way
# and looks like a regression test forever.
#
# All of it happens in a throwaway `git worktree` at HEAD. This checkout, its
# Core/ and its build/ are never touched. That is the point: the script this
# replaces reverted patches in place, and twice its traps cost real time --
# the build's patch stamp silently re-applied the patch it had just
# reverted, and an early exit left build/bin/ext4dump built from the reverted
# source, so the next suite anyone ran reported a long-fixed bug as live.
#
# --id NNNN finds the commit by its `Lwext4-Change: NNNN` trailer
# (docs/lwext4-changes.md). The default suite is the hostile-fixture
# regressions; --asan builds the sanitizer configuration.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

usage() { echo "usage: red_first.sh <commit> | --id NNNN  [--suite PATH] [--asan]"; exit 2; }

COMMIT="" SUITE="Tests/run_fuzz_regressions_tests.sh" CONFIG_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --id)    [ -n "${2:-}" ] || usage
             COMMIT=$(git log -1 --format=%H --grep="^Lwext4-Change: $2\$")
             [ -n "$COMMIT" ] || { echo "red-first: no commit carries Lwext4-Change: $2"; exit 2; }
             shift 2 ;;
    --suite) [ -n "${2:-}" ] || usage; SUITE="$2"; shift 2 ;;
    --asan)  CONFIG_ARG="CONFIG=debug"; shift ;;
    -*)      usage ;;
    *)       [ -z "$COMMIT" ] || usage
             COMMIT=$(git rev-parse --verify -q "$1^{commit}") \
               || { echo "red-first: not a commit: $1"; exit 2; }
             shift ;;
  esac
done
[ -n "$COMMIT" ] || usage
[ -f "$SUITE" ] || { echo "red-first: no such suite: $SUITE"; exit 2; }
git merge-base --is-ancestor "$COMMIT" HEAD \
  || { echo "red-first: $(git rev-parse --short "$COMMIT") is not in HEAD's history"; exit 2; }
[ -n "$(git diff --name-only "$COMMIT^" "$COMMIT" -- Core)" ] \
  || { echo "red-first: $(git rev-parse --short "$COMMIT") changes nothing under Core/"; exit 2; }

WT="$(mktemp -d "${TMPDIR:-/tmp}/red-first.XXXXXX")"
LOGS="$ROOT/build/red-first"
mkdir -p "$LOGS"
cleanup() { git -C "$ROOT" worktree remove --force "$WT" >/dev/null 2>&1 || rm -rf "$WT"; }
trap cleanup EXIT
git worktree add -q --detach "$WT" HEAD

# Generated fixtures are ~1 GB and minutes of mke2fs. Clone this checkout's
# (cp -c: an APFS copy-on-write clone, instant and private to the worktree)
# rather than regenerate them; a suite that finds one missing still builds it.
for img in "$ROOT"/Tests/fixtures/*.img; do
  [ -e "$img" ] && cp -c "$img" "$WT/Tests/fixtures/" 2>/dev/null || true
done

build() {  # build <label>
  if ! make -C "$WT" tools $CONFIG_ARG > "$LOGS/build-$1.log" 2>&1; then
    echo "red-first: the build failed ($1):"
    tail -15 "$LOGS/build-$1.log" | sed 's/^/    /'
    exit 1
  fi
}
suite() {  # suite <label> -> sets rc
  set +e
  (cd "$WT" && bash "$SUITE") > "$LOGS/suite-$1.log" 2>&1
  rc=$?
  set -e
  grep -E '^  (ok|FAIL)|^passed:' "$LOGS/suite-$1.log" | tail -12 | sed 's/^/    /'
}

echo "red-first: $(git log -1 --format='%h %s' "$COMMIT")"
echo "  suite: $SUITE${CONFIG_ARG:+  ($CONFIG_ARG)}"
echo ""

echo "── reverting its code (Core/ only; tests and fixtures stay)"
if ! git -C "$WT" revert --no-commit "$COMMIT" > "$LOGS/revert.log" 2>&1; then
  echo "red-first: the commit does not revert cleanly at HEAD -- a later"
  echo "  change touches the same lines. Revert by hand in a worktree:"
  sed 's/^/    /' "$LOGS/revert.log" | head -10
  exit 1
fi
git -C "$WT" restore --source=HEAD --staged --worktree -- ':(exclude)Core'
git -C "$WT" diff --stat HEAD -- Core | tail -1 | sed 's/^/   /'

echo "── rebuilding without it"
build red
echo ""
echo "── the suite, which MUST fail"
suite red
if [ "$rc" -eq 0 ]; then
  echo ""
  echo "red-first: THE SUITE PASSED WITHOUT THE FIX."
  echo "  Whatever it is testing, it is not this change. Common causes: the"
  echo "  fixture only fails under a sanitizer and this is a release build"
  echo "  (try --asan), or the row's verbs do not reach the changed code."
  exit 1
fi
echo "    -> failed as required (rc=$rc)"

echo ""
echo "── putting the code back and rebuilding"
git -C "$WT" checkout HEAD -- Core
build green
echo ""
echo "── the suite, which MUST pass"
suite green
if [ "$rc" -ne 0 ]; then
  echo ""
  echo "red-first: the suite still fails WITH the fix (rc=$rc)."
  exit 1
fi

echo ""
echo "red-first: proven -- red without $(git rev-parse --short "$COMMIT"), green with it."
echo "  logs: $LOGS/"
