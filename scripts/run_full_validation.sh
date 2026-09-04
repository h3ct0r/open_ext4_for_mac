#!/usr/bin/env bash
# Run the complete validation chain unattended, one stage after another.
#
#   1. read suite          — image-level, no dependencies
#   2. write suite         — e2fsck after every mutating operation
#   3. format              — volumes we create, judged by e2fsck and by Linux
#   4. open-unlink         — the orphan list, and recovery from a torn one
#   5. crypto + LUKS       — AES-XTS against OpenSSL, ext4 inside a container
#   6. crash consistency   — cut the write stream everywhere, replay, verify
#   7b. reordered writes   — and reorder what was in flight, as a drive does
#   7. differential        — cross-check against the real Linux ext4 driver
#   8. mounted driver      — the same crash testing against a real mount
#   9. encrypted, mounted  — a LUKS volume through FSKit, verified by Linux
#
# Stages 5-9 need a running Docker daemon (a real Linux kernel on Apple
# Silicon); the last two additionally need the signed extension installed and
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

summary() {
  banner "summary"
  printf '%-28s %-6s %s\n' "STAGE" "RESULT" "TIME" | tee -a "$LOG"
  for i in "${!STAGES[@]}"; do
    printf '%-28s %-6s %s\n' "${STAGES[$i]}" "${RESULTS[$i]}" "${DURATIONS[$i]}" | tee -a "$LOG"
  done
  echo | tee -a "$LOG"
  echo "total: $(( SECONDS - START ))s" | tee -a "$LOG"
  echo "log:   $LOG" | tee -a "$LOG"

  local skipped=0 r
  for r in "${RESULTS[@]}"; do [ "$r" = "SKIP" ] && skipped=$(( skipped + 1 )); done

  if [ "$FAILED" -ne 0 ]; then
    echo "FAILURES PRESENT" | tee -a "$LOG"
  elif [ "$skipped" -ne 0 ]; then
    # Say so plainly: green with something untested is not the same as green.
    echo "ALL GREEN — but $skipped stage(s) did not run" | tee -a "$LOG"
  else
    echo "ALL GREEN" | tee -a "$LOG"
  fi
}

# No stage may run forever.
#
# Everything here talks to a device, a container, or a mounted filesystem, and
# each of those can stop answering rather than fail. A driver killed while it
# holds physical media leaves the device serving no reads at all, and anything
# waiting on it sits in uninterruptible sleep where no signal reaches it. The
# chain would then hang with no output and no indication of which stage, which
# is indistinguishable from a slow suite -- and stage 7 legitimately takes two
# minutes, so "it has been quiet a while" tells you nothing.
#
# Generous on purpose: the longest stage today is ~130s, so 15 minutes is six
# times the worst honest case and will only fire on something genuinely stuck.
STAGE_TIMEOUT="${EXT4_STAGE_TIMEOUT:-900}"

stage() {  # stage <name> <command...>
  local name="$1"; shift
  banner "$name"
  local start=$SECONDS

  # Backgrounded so it can be given a deadline, but still writing to the
  # terminal, because a stage that produces no output while it works is the
  # thing being guarded against -- replacing it with a stage that produces no
  # output at all would be a poor trade.
  local rcfile; rcfile=$(mktemp)

  # Job control, so the stage gets its own process group and the deadline can
  # take the whole thing down. Killing just the subshell leaves the suite and
  # its `tee` running: the first version did that, and the stage carried on
  # printing after the summary had already declared it timed out.
  set -m
  ( "$@" 2>&1 | tee -a "$LOG"; echo "${PIPESTATUS[0]}" > "$rcfile" ) &
  local pid=$! waited=0 rc=0
  set +m

  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$STAGE_TIMEOUT" ]; then
      # The group, not the process. Anything still holding a wedged device
      # will survive regardless -- uninterruptible sleep takes no signals --
      # but everything else goes.
      kill -9 -- "-$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      rm -f "$rcfile"
      echo ""
      echo "  this stage produced no result in ${STAGE_TIMEOUT}s and was stopped."
      echo ""
      echo "  Usually the target device has stopped answering: killing the"
      echo "  driver while it holds physical media can leave it serving no"
      echo "  reads, and a process waiting on that is in uninterruptible sleep"
      echo "  where kill -9 does nothing. Unplug the device and replug it."
      echo "  Expect its BSD name to change."
      echo ""
      echo "  Stopping the run: a stuck device will take the remaining stages"
      echo "  with it, and eleven more timeouts is not a more useful answer."
      STAGES+=("$name"); DURATIONS+=("${STAGE_TIMEOUT}s"); RESULTS+=("TIMEOUT")
      FAILED=1
      summary
      exit 1
    fi
    sleep 2
    waited=$(( waited + 2 ))
  done

  wait "$pid" 2>/dev/null
  rc=$(cat "$rcfile" 2>/dev/null || echo 1)
  rm -f "$rcfile"
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

# Before anything is measured: does the tree we just built match the tree
# someone else would get? Every suite below runs against Core/lwext4 as it sits
# on this disk, and says nothing about whether the patch files reproduce it. A
# green run of a tree that only exists here is the most expensive kind of pass.
stage "0. patches reproduce lwext4" bash scripts/check_patches.sh

# What is in the shipping core, and what must not be: no getenv, no test-only
# exports, none of the removed env-var names. Needs the ship library, which
# `make tools` above does not build -- so build it here (fast, cached after).
make core >/dev/null 2>&1
stage "0b. shipping core surface" bash scripts/check_ship_surface.sh

# The operating envelope, as documented, against the operating envelope, as
# coded: one table in docs/ENVELOPE.md, one table in the shim, one diff.
stage "0c. envelope matches the shim" bash Tests/run_envelope_tests.sh

stage "1. read suite"  bash Tests/run_tests.sh
stage "2. write suite" bash Tests/run_write_tests.sh

# Bounds, overflow, and POSIX semantics -- the pre-release audit's findings,
# each with an oracle. Offline, seconds.
stage "2b. bounds & semantics" bash Tests/run_bounds_tests.sh

# Mutated images, structure-aware, with the checksums re-stamped so an edit
# reaches the parser it was aimed at rather than being refused at the gate.
# No special toolchain: this is the fuzzing that can run anywhere, and the
# in-process libFuzzer harness is the deeper instrument for a machine that
# has Homebrew LLVM. The seed is the round number under soak.
stage "2c. mutation campaign" bash Tests/run_fuzz_tests.sh

# And every image that was once a finding, run again. A fuzzer finds a bug
# once; this is what stops it coming back.
stage "2d. hostile image regressions" bash Tests/run_fuzz_regressions_tests.sh

# Only the format suite's Linux round-trip needs Docker, and it skips that
# section by itself; the geometry sweep needs nothing but e2fsck.
stage "3. format" bash Tests/run_format_tests.sh

# Same arrangement: only its cross-check against the Linux kernel needs Docker.
stage "4. open-unlink recovery" bash Tests/run_orphan_tests.sh
stage "4b. preallocation" bash Tests/run_prealloc_tests.sh

# Every revoke block in the journal, entry by entry -- the suite that caught
# the off-by-tail phantom entry. Seconds, offline, no Docker.
stage "4c. journal revoke records" bash Tests/run_revoke_tests.sh

# Known-answer tests for the crypto primitives need nothing at all; the LUKS
# suite needs cryptsetup, so it lives with the Docker stages below.
stage "5. crypto primitives" "$ROOT/build/bin/cryptotest"

# A device that answers EIO, aimed at paths that historically swallowed it.
stage "5b. errors surface, not vanish" bash Tests/run_eio_tests.sh

# A bitmap that fails its checksum: refused, and not rewritten over.
stage "5c. checksums that act" bash Tests/run_csum_tests.sh

# What interleaved allocation costs, and that the reservation gives it back.
stage "5d. fragmentation" bash Tests/run_fragmentation_tests.sh

# The channel the extension uses to say anything at all. Offline: the store,
# the schema, the rotation, the sanitising and the app's reader, none of which
# need a mounted volume. The extension writing one of these from a real
# refused mount is a mounted-path cell and is not here yet.
stage "5e. user-visible events" bash Tests/run_events_tests.sh

# What this build can check about itself with no disk in the machine: whether
# key material is actually locked into memory here. mlock only promises
# best-effort, so "it is supposed to be" and "it is" are different claims.
# 5e above builds the app if it is not there, which is what this runs.
stage "5f. this build checks itself" "$ROOT/build/Ext4Mac.app/Contents/MacOS/Ext4Mac" selftest

# The dry-run uninstall names every artifact an install creates; the release
# check reads the version out of the built bundles.
stage "5g. uninstall names everything" bash Tests/run_uninstall_tests.sh
stage "5h. the build is the version it says" bash scripts/check_release.sh

if docker info >/dev/null 2>&1; then
  stage "6. LUKS containers" bash Tests/run_luks_tests.sh
  stage "7. crash consistency" bash Tests/run_crash_tests.sh

  # Stage 7 cuts the write stream; this one also *reorders* what was in
  # flight. That is the difference between a disk image and a drive, and it
  # is the only stage here that can fail when the journal has no barrier --
  # which is why it also asserts that disabling barriers breaks it.
  stage "7b. reordered writes" bash Tests/run_reorder_tests.sh
  stage "8. differential vs Linux" bash Tests/run_diff_tests.sh

  # The incident regression guard: a deep dirty journal inside LUKS, priced
  # like the USB stick that produced the 2026-08-29 replay hang, must mount
  # inside DiskArbitration's budget. Command counts, not wall time.
  stage "8b. journal replay speed" bash Tests/run_replay_speed_tests.sh

  # Stages 1-8 all drive the core directly through a plain file. These two go
  # through FSKit *and* hand their images to the Linux kernel, so they need
  # both the enabled extension and Docker.
  # check_extension.sh, not pluginkit: pluginkit answers "is it registered",
  # and a module can be registered and still refuse every mount because the
  # user has not approved it -- which is the state a fresh install leaves.
  # The suites below then skip themselves, so the gate only decides whether
  # to bother starting them.
  if bash scripts/check_extension.sh >/dev/null 2>&1; then
    stage "9. mounted driver" bash Tests/run_mount_crash_tests.sh
    stage "10. encrypted volumes, mounted" bash Tests/run_mount_luks_tests.sh
  else
    skip "9. mounted driver" "the FSKit extension is not enabled"
    skip "10. encrypted volumes, mounted" "the FSKit extension is not enabled"
  fi
else
  skip "6. LUKS containers"       "docker daemon not reachable"
  skip "7. crash consistency"     "docker daemon not reachable"
  skip "7b. reordered writes"     "docker daemon not reachable"
  skip "8. differential vs Linux" "docker daemon not reachable"
  skip "8b. journal replay speed" "docker daemon not reachable"
  skip "9. mounted driver"        "docker daemon not reachable"
  skip "10. encrypted volumes, mounted" "docker daemon not reachable"
fi

# Mounted, but Docker-free: e2fsck is their oracle. Gated only on the
# extension, so a machine without Docker still measures the live driver.
if bash scripts/check_extension.sh >/dev/null 2>&1; then
  stage "11. recovery after a kill" bash Tests/run_kill_recovery_tests.sh
  stage "12. newfs through FSKit" bash Tests/run_newfs_tests.sh
else
  skip "11. recovery after a kill" "the FSKit extension is not enabled"
  skip "12. newfs through FSKit" "the FSKit extension is not enabled"
fi

summary
exit "$FAILED"
