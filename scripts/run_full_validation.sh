#!/usr/bin/env bash
# Run the complete validation chain unattended, one stage after another.
#
#   1. read suite          — image-level, no dependencies
#   2. write suite         — e2fsck after every mutating operation
#   3. format              — volumes we create, judged by e2fsck and by Linux
#   4. open-unlink         — the orphan list, and recovery from a torn one
#   5. crash consistency   — cut the write stream everywhere, replay, verify
#   6. differential        — cross-check against the real Linux ext4 driver
#   7. mounted driver      — the same crash testing against a real mount
#
# Stages 5-7 need a running Docker daemon (a real Linux kernel on Apple
# Silicon); stage 7 additionally needs the signed extension installed and
# enabled. They are skipped with a warning rather than failing the run if that
# is unavailable, so this is still useful on a machine without it. Stages 3 and
# 4 each have one section that wants Docker and skip just that section.
#
# Usage:  bash scripts/run_full_validation.sh [--asan]
# Exits non-zero if any stage that actually ran failed.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ASAN=0
[ "${1:-}" = "--asan" ] && ASAN=1

LOG="$ROOT/build/validation.log"

STAGES=(); RESULTS=(); DURATIONS=()
FAILED=0

banner() {
  echo | tee -a "$LOG"
  echo "════════════════════════════════════════════════════" | tee -a "$LOG"
  echo "  $1" | tee -a "$LOG"
  echo "════════════════════════════════════════════════════" | tee -a "$LOG"
}

stage() {  # stage <name> <command...>
  local name="$1"; shift
  banner "$name"
  local start=$SECONDS
  if "$@" 2>&1 | tee -a "$LOG"; then
    local rc=${PIPESTATUS[0]}
  else
    local rc=${PIPESTATUS[0]}
  fi
  local elapsed=$(( SECONDS - start ))
  STAGES+=("$name"); DURATIONS+=("${elapsed}s")
  # 77 means the suite decided it could not run -- a missing prerequisite, not
  # a pass. Recording it as PASS would mean a stage that silently stopped
  # testing anything still showed green.
  case "$rc" in
    0)  RESULTS+=("PASS") ;;
    77) RESULTS+=("SKIP") ;;
    *)  RESULTS+=("FAIL"); FAILED=1 ;;
  esac
}

skip() {  # skip <name> <why>
  STAGES+=("$1"); RESULTS+=("SKIP"); DURATIONS+=("-")
  banner "$1"
  echo "  skipped: $2" | tee -a "$LOG"
}

START=$SECONDS
echo "open_ext4_for_mac — full validation" | tee -a "$LOG"
echo "started $(date)" | tee -a "$LOG"

# `make clean` removes build/, so the log has to be created after it, not
# before -- otherwise tee spends the whole build writing to a deleted file.
make clean >/dev/null 2>&1
mkdir -p "$ROOT/build"
: > "$LOG"

banner "build"
if [ "$ASAN" -eq 1 ]; then
  echo "  configuration: debug (AddressSanitizer + UBSan)" | tee -a "$LOG"
  make tools CONFIG=debug > "$ROOT/build/build.log" 2>&1; BUILD_RC=$?
else
  echo "  configuration: release" | tee -a "$LOG"
  make tools > "$ROOT/build/build.log" 2>&1; BUILD_RC=$?
fi
tail -2 "$ROOT/build/build.log" | tee -a "$LOG"

# Without this, a failed build shows up as four suites reporting "build first:
# make tools" and a summary full of FAILs that say nothing about the cause.
if [ "$BUILD_RC" -ne 0 ] || [ ! -x "$ROOT/build/bin/ext4dump" ]; then
  echo | tee -a "$LOG"
  echo "  BUILD FAILED — nothing below would mean anything. Last 20 lines:" | tee -a "$LOG"
  tail -20 "$ROOT/build/build.log" | sed 's/^/    /' | tee -a "$LOG"
  exit 1
fi

stage "1. read suite"  bash Tests/run_tests.sh
stage "2. write suite" bash Tests/run_write_tests.sh

# Only the format suite's Linux round-trip needs Docker, and it skips that
# section by itself; the geometry sweep needs nothing but e2fsck.
stage "3. format" bash Tests/run_format_tests.sh

# Same arrangement: only its cross-check against the Linux kernel needs Docker.
stage "4. open-unlink recovery" bash Tests/run_orphan_tests.sh

if docker info >/dev/null 2>&1; then
  stage "5. crash consistency" bash Tests/run_crash_tests.sh
  stage "6. differential vs Linux" bash Tests/run_diff_tests.sh

  # Stages 1-6 all drive the core directly through a plain file. Only this one
  # goes through FSKit, so it is the only evidence about the path a real mount
  # takes. It needs the signed extension installed *and enabled*.
  if pluginkit -m -p com.apple.fskit.fsmodule 2>/dev/null | grep -q "dev.h3ct0r.ext4mac.Ext4FS"; then
    stage "7. mounted driver" bash Tests/run_mount_crash_tests.sh
  else
    skip "7. mounted driver" "the FSKit extension is not installed"
  fi
else
  skip "5. crash consistency"     "docker daemon not reachable"
  skip "6. differential vs Linux" "docker daemon not reachable"
  skip "7. mounted driver"        "docker daemon not reachable"
fi

TOTAL=$(( SECONDS - START ))

banner "summary"
printf '%-28s %-6s %s\n' "STAGE" "RESULT" "TIME" | tee -a "$LOG"
for i in "${!STAGES[@]}"; do
  printf '%-28s %-6s %s\n' "${STAGES[$i]}" "${RESULTS[$i]}" "${DURATIONS[$i]}" | tee -a "$LOG"
done
echo | tee -a "$LOG"
echo "total: ${TOTAL}s" | tee -a "$LOG"
echo "log:   $LOG" | tee -a "$LOG"
SKIPPED=0
for r in "${RESULTS[@]}"; do [ "$r" = "SKIP" ] && SKIPPED=$((SKIPPED+1)); done

if [ "$FAILED" -ne 0 ]; then
  echo "FAILURES PRESENT" | tee -a "$LOG"
elif [ "$SKIPPED" -ne 0 ]; then
  # Say so plainly: green with something untested is not the same as green.
  echo "ALL GREEN — but $SKIPPED stage(s) did not run" | tee -a "$LOG"
else
  echo "ALL GREEN" | tee -a "$LOG"
fi

exit "$FAILED"
