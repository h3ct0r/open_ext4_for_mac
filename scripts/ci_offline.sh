#!/usr/bin/env bash
# The offline half of the test set: everything that needs nothing but this
# checkout, a compiler and e2fsprogs.
#
# This is the script the CI workflow runs. The YAML holds no logic at all --
# it installs e2fsprogs and calls this -- so "green locally" and "green in CI"
# are the same claim, checkable before pushing with:
#
#     make ci-offline
#
# What is deliberately NOT here, and why:
#
#   * anything that needs Docker (LUKS containers, crash consistency,
#     reordered writes, the Linux differential, replay speed). GitHub's macOS
#     runners have no Docker. Those suites move to an ubuntu runner in F1.
#   * anything that needs a signed, installed, user-approved FSKit extension
#     (mounted driver, mounted LUKS, newfs, kill-recovery, scale) or hands on
#     a USB stick (pull). No runner can grant an extension approval.
#   * anything that needs Homebrew LLVM (the libFuzzer harness). It gets its
#     own job, so a runner without the runtime cannot turn the whole matrix
#     red.
#
# So this is not "the test suite". It is the part of it that can be made
# un-forgettable, which is a different and smaller thing -- `make validate`
# on the developer's Mac stays the full claim, and docs/ENVELOPE.md says so.
#
# Exit status: 0 if every stage passed, 1 if any failed or timed out. A stage
# that exits 77 is a SKIP -- a missing prerequisite, not a pass -- and is
# reported as such but does not fail the run, except that the summary says
# plainly how many did not run. In CI, a skip is usually a mis-provisioned
# runner, so REQUIRE_ALL=1 turns any skip into a failure; the workflow sets it.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

OUT="$ROOT/build/ci"
mkdir -p "$OUT"

# No stage may run forever. macOS has no timeout(1), so this is the same
# backgrounded-with-a-deadline shape run_full_validation.sh uses, and for the
# same reason: a stage that stops answering must be named, not waited on.
# Generous -- the slowest offline stage here is the write suite at ~70s.
STAGE_TIMEOUT="${CI_STAGE_TIMEOUT:-900}"
REQUIRE_ALL="${REQUIRE_ALL:-0}"

NAMES=(); RESULTS=(); TALLIES=(); TIMES=()
FAILED=0; SKIPPED=0
TOT_PASS=0; TOT_FAIL=0

# Suites end with a line of the form "passed: N   failed: M" (some add more
# after it, like the write suite's e2fsck count). Extract the last one: that
# is the suite's own count of assertions, and printing it is the difference
# between "the suite exited 0" and "the suite ran 114 checks and exited 0".
# A suite that silently stopped testing anything shows up here as passed: 0.
#
# Prints "<passed> <failed>", or "- -" when the stage has no tally (a build, a
# typecheck). It must not accumulate the running totals itself: it is called
# in a command substitution, so anything it adds is added inside a subshell
# and thrown away -- which is how the first version of this script reported
# "assertions: 0 passed, 0 failed" under sixteen green suites.
tally_of() {
  local log="$1" line p f
  line=$(grep -oE 'passed:[[:space:]]*[0-9]+[[:space:]]+failed:[[:space:]]*[0-9]+' "$log" 2>/dev/null | tail -1)
  [ -n "$line" ] || { printf -- '- -'; return 0; }
  p=$(printf '%s' "$line" | sed -nE 's/.*passed:[[:space:]]*([0-9]+).*/\1/p')
  f=$(printf '%s' "$line" | sed -nE 's/.*failed:[[:space:]]*([0-9]+).*/\1/p')
  printf '%s %s' "${p:--}" "${f:--}"
}

# Say what went wrong, in the job log, without pasting the whole suite.
# Match the suites' own vocabulary first ("  FAIL  <what>"), then fall back to
# the tail, which is where a compiler or a make failure explains itself.
excerpt() {
  local log="$1"
  echo "      ── $log"
  # Strip the colour first. The suites print their verdicts as
  # "  <esc>[31mFAIL<esc>[0m the thing", so a pattern anchored on FAIL after
  # leading space matches nothing at all against the raw file -- the excerpt
  # then falls back to the tail and the failing assertion, which is the one
  # line anybody wants, scrolls off.
  local plain; plain=$(mktemp)
  sed -e $'s/\033\\[[0-9;]*[a-zA-Z]//g' "$log" > "$plain" 2>/dev/null
  local hits
  hits=$(grep -nE '^[[:space:]]*(FAIL|bad)[[:space:]]|FAIL:|error:|Assertion|AddressSanitizer|runtime error:' "$plain" 2>/dev/null | head -12)
  if [ -n "$hits" ]; then
    printf '%s\n' "$hits" | sed 's/^/      /'
  else
    tail -12 "$plain" 2>/dev/null | sed 's/^/      /'
  fi
  rm -f "$plain"
  echo ""
}

stage() {  # stage <name> <command...>
  local name="$1"; shift
  local log="$OUT/$name.log"
  local start=$SECONDS
  printf '  %-16s ' "$name"

  # Output to a file, not the terminal: one line per stage is the whole point
  # of this summary, and sixteen suites' worth of green ok-lines is the wall
  # of noise it exists instead of. The file is uploaded as a CI artifact.
  #
  # Job control so the deadline can take the process group down. Killing just
  # the subshell leaves the suite running and printing after it was declared
  # dead -- run_full_validation.sh learned that the expensive way.
  local rcfile; rcfile=$(mktemp)
  set -m
  ( "$@" >"$log" 2>&1; echo "${PIPESTATUS[0]}" >"$rcfile" ) &
  local pid=$! waited=0 rc=0
  set +m

  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$STAGE_TIMEOUT" ]; then
      kill -9 -- "-$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      rm -f "$rcfile"
      NAMES+=("$name"); RESULTS+=("TIMEOUT"); TALLIES+=("-"); TIMES+=("${STAGE_TIMEOUT}s")
      printf 'TIMEOUT  %-9s %ss\n' "-" "$STAGE_TIMEOUT"
      excerpt "$log"
      FAILED=1
      return 0
    fi
    sleep 2; waited=$(( waited + 2 ))
  done

  wait "$pid" 2>/dev/null
  rc=$(cat "$rcfile" 2>/dev/null || echo 1); rm -f "$rcfile"
  local elapsed=$(( SECONDS - start ))
  local p f t
  read -r p f <<<"$(tally_of "$log")"
  if [ "$p" = "-" ]; then
    t="-"
  else
    t="$p/$f"
    TOT_PASS=$(( TOT_PASS + p ))
    TOT_FAIL=$(( TOT_FAIL + f ))
  fi

  NAMES+=("$name"); TALLIES+=("$t"); TIMES+=("${elapsed}s")
  case "$rc" in
    0)
      RESULTS+=("PASS")
      printf 'PASS     %-9s %ss\n' "$t" "$elapsed"
      ;;
    77)
      RESULTS+=("SKIP"); SKIPPED=$(( SKIPPED + 1 ))
      printf 'SKIP     %-9s %ss\n' "$t" "$elapsed"
      head -3 "$log" 2>/dev/null | sed 's/^/      /'
      [ "$REQUIRE_ALL" = "1" ] && FAILED=1
      ;;
    *)
      RESULTS+=("FAIL"); FAILED=1
      printf 'FAIL     %-9s %ss  (rc=%s)\n' "$t" "$elapsed" "$rc"
      excerpt "$log"
      ;;
  esac
}

echo "open_ext4_for_mac — offline CI set"
echo "  $(date)"
echo "  $(uname -srm), $(cc --version 2>/dev/null | head -1)"
echo ""
printf '  %-16s %-8s %-9s %s\n' "STAGE" "RESULT" "PASS/FAIL" "TIME"

# ---------------------------------------------------------------- the set --

# First, and before anything is built: does the patch set reproduce the tree
# we are about to compile? A green run of a tree that only exists on one
# machine is the most expensive kind of pass, and it is the exact failure a
# CI system is supposed to make impossible.
stage check-patches  bash scripts/check_patches.sh

stage build          make tools

# The shipping library, and what must not be in it: no getenv, no test-only
# exports. Needs `make core`, which `make tools` does not build.
stage ship-surface   make check-ship-surface

# Known-answer tests for AES-XTS and the LUKS key derivation, against vectors
# generated by OpenSSL. Links nothing else; runs in a second.
stage crypto         make test-crypto

stage read           bash Tests/run_tests.sh
stage write          bash Tests/run_write_tests.sh
stage bounds         bash Tests/run_bounds_tests.sh

# format and orphan each have one section that wants Docker and skip just
# that section, so they belong here: what they lose on a runner is the Linux
# cross-check, not the suite.
stage format         bash Tests/run_format_tests.sh
stage orphan         bash Tests/run_orphan_tests.sh
stage prealloc       bash Tests/run_prealloc_tests.sh
stage revoke         bash Tests/run_revoke_tests.sh
stage eio            bash Tests/run_eio_tests.sh
stage csum           bash Tests/run_csum_tests.sh
stage fragmentation  bash Tests/run_fragmentation_tests.sh

# Mutated images against the offline driver. Needs no special toolchain, which
# is why it can be here at all -- the in-process libFuzzer harness gets its
# own job, so a runner without the runtime cannot turn this one red.
stage fuzz           bash Tests/run_fuzz_tests.sh

# Does the Swift half still compile? This is the canary for the runner image
# having an SDK with FSKit in it: if `macos-15` ever ships an SDK without it,
# this is the stage that says so, in one line, instead of the app build
# failing in a hundred.
stage typecheck      make typecheck

# And does the bundle build at all -- unsigned, no profile, no secrets. Signing
# is release-only (F4); this asks the cheaper question, which is whether the
# extension and the container app still link.
stage app            make app

# Suites added by later phases. Each is listed the day it exists, so that
# forgetting to register one shows up as a shorter summary rather than as
# nothing at all:
#   stage fuzz-regressions make test-fuzz-regressions  (A6)
#   stage envelope         make test-envelope          (C)
#   stage uninstall        make test-uninstall         (D)

# ------------------------------------------------------------------ tally --
echo ""
echo "  ──────────────────────────────────────────────────"
printf '  %d stage(s): %d passed, %d failed, %d skipped\n' \
  "${#NAMES[@]}" \
  "$(printf '%s\n' "${RESULTS[@]}" | grep -c '^PASS$')" \
  "$(printf '%s\n' "${RESULTS[@]}" | grep -cE '^(FAIL|TIMEOUT)$')" \
  "$SKIPPED"
printf '  assertions: %d passed, %d failed\n' "$TOT_PASS" "$TOT_FAIL"
printf '  logs: %s\n' "$OUT"
echo ""

if [ "$FAILED" -ne 0 ]; then
  echo "  OFFLINE SET RED"
  printf '  did not pass:'
  for i in "${!NAMES[@]}"; do
    case "${RESULTS[$i]}" in
      PASS) ;;
      SKIP) [ "$REQUIRE_ALL" = "1" ] && printf ' %s(SKIP)' "${NAMES[$i]}" ;;
      *)    printf ' %s' "${NAMES[$i]}" ;;
    esac
  done
  echo ""
  exit 1
elif [ "$SKIPPED" -ne 0 ]; then
  # Green with something untested is not the same as green.
  echo "  OFFLINE SET GREEN — but $SKIPPED stage(s) did not run"
else
  echo "  OFFLINE SET GREEN"
fi
exit 0
