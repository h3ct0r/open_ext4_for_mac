#!/usr/bin/env bash
# Run the complete validation chain unattended, one stage after another.
#
#   1. read suite          — image-level, no dependencies
#   2. write suite         — e2fsck after every mutating operation
#   3. crash consistency   — cut the write stream everywhere, replay, verify
#   4. differential        — cross-check against the real Linux ext4 driver
#   5. mounted driver      — the same crash testing against a real mount
#
# Stages 3-5 need a running Docker daemon (a real Linux kernel on Apple
# Silicon); stage 5 additionally needs the signed extension installed and
# enabled. They are skipped with a warning rather than failing the run if that
# is unavailable, so this is still useful on a machine without it.
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
  if [ "$rc" -eq 0 ]; then RESULTS+=("PASS"); else RESULTS+=("FAIL"); FAILED=1; fi
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

if docker info >/dev/null 2>&1; then
  stage "3. crash consistency" bash Tests/run_crash_tests.sh
  stage "4. differential vs Linux" bash Tests/run_diff_tests.sh

  # Stages 1-4 all drive the core directly through a plain file. Only this one
  # goes through FSKit, so it is the only evidence about the path a real mount
  # takes. It needs the signed extension installed and enabled.
  if pluginkit -m -p com.apple.fskit.fsmodule 2>/dev/null | grep -q "dev.h3ct0r.ext4mac.Ext4FS"; then
    stage "5. mounted driver" bash Tests/run_mount_crash_tests.sh
  else
    skip "5. mounted driver" "the FSKit extension is not installed and enabled"
  fi
else
  skip "3. crash consistency"     "docker daemon not reachable"
  skip "4. differential vs Linux" "docker daemon not reachable"
  skip "5. mounted driver"        "docker daemon not reachable"
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
[ "$FAILED" -eq 0 ] && echo "ALL GREEN" | tee -a "$LOG" || echo "FAILURES PRESENT" | tee -a "$LOG"

exit "$FAILED"
