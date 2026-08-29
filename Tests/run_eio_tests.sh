#!/usr/bin/env bash
# Errors surface, not vanish.
#
# The journal-replay incident had a second lesson hiding behind the first: the
# replay path *lost write errors* -- a void callback discarded the flush
# result, and recovery then cleared a journal whose contents never reached the
# medium. The audit that followed found the same shape in a dozen places:
# checkpoint writes whose failure advances the log tail anyway, a cache
# release that swallows the flush of nearly every metadata block, a format
# that reports success over a filesystem that never landed, an unmount that
# reports clean through four layers of discarded results.
#
# None of that is testable with a device that never fails. EXT4DUMP_FAIL_AFTER
# models a power cut -- writes vanish *silently*, because a cut hands the
# driver no errno. This suite uses the opposite model: EXT4DUMP_EIO_READ_AT /
# EXT4DUMP_EIO_WRITE_AT make the N-th device command answer EIO, the way a
# failing stick does. Every cell asserts two things: the injected fault
# actually fired (the EIO-INJECT line -- a red test whose fault was never
# reached proves nothing), and the failure came OUT: nonzero exit, an intact
# journal, an e2fsck-clean medium.
#
# Ordinals are deterministic: ext4dump is single-threaded, so for a fixed
# fixture and command the N-th read is always the same block. Cells that need
# a specific block first map ordinal to offset with EXT4DUMP_TRACE
# (`TRC R seq=` is 0-based; the knob is 1-based, so knob = seq + 1).
#
# Runs everywhere: plain images, no Docker. Writes build/eio-report.txt.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/Tests/lib.sh"

DUMP="$ROOT/build/bin/ext4dump"
WORK="$ROOT/build/eio"
REPORT="$ROOT/build/eio-report.txt"

[ -x "$DUMP" ] || { echo "build first: make tools"; exit 1; }

rm -rf "$WORK"; mkdir -p "$WORK"
: > "$REPORT"
trap 'rm -rf "$WORK"' EXIT

note() { echo "$*" | tee -a "$REPORT"; }
# Route the tallies through the report as well.
ok()  { PASS=$((PASS+1)); note "  ok    $*"; }
bad() { FAIL=$((FAIL+1)); note "  FAIL  $*"; shift; [ $# -gt 0 ] && note "        $*"; return 0; }

# fresh <name>: a small formatted image to hurt.
fresh() {
  local img="$WORK/$1.img"
  rm -f "$img"
  truncate -s 64m "$img"
  "$DUMP" "$img" format 4 >/dev/null 2>&1 || { echo "format failed" >&2; return 1; }
  echo "$img"
}

note "########## errors surface, not vanish ##########"
note ""
note "the injector itself"
note ""

# ------------------------------------------------------------ self-tests --
# Prove the knob works before trusting any cell that uses it. Each asserts
# both halves: the fault fired, and the command noticed.

img=$(fresh self)

EXT4DUMP_EIO_READ_AT=1 "$DUMP" "$img" ls / >/dev/null 2>"$WORK/r1.err"
rc=$?
if [ $rc -ne 0 ] && grep -q '^EIO-INJECT read #1 ' "$WORK/r1.err"; then
  ok "a failed read fails the command (rc=$rc)"
else
  bad "read injection self-test" "rc=$rc; $(grep EIO-INJECT "$WORK/r1.err" || echo 'fault never fired')"
fi

EXT4DUMP_EIO_WRITE_AT=1 "$DUMP" "$img" label EIOTEST >/dev/null 2>"$WORK/w1.err"
rc=$?
if [ $rc -ne 0 ] && grep -q '^EIO-INJECT write #1 ' "$WORK/w1.err"; then
  ok "a failed write fails the command (rc=$rc)"
else
  bad "write injection self-test" "rc=$rc; $(grep EIO-INJECT "$WORK/w1.err" || echo 'fault never fired')"
fi

EXT4DUMP_EIO_READ_AT=1 EXT4DUMP_EIO_STICKY=1 "$DUMP" "$img" ls / >/dev/null 2>"$WORK/rs.err"
rc=$?
fired=$(grep -c '^EIO-INJECT read' "$WORK/rs.err")
if [ $rc -ne 0 ] && [ "${fired:-0}" -ge 1 ]; then
  ok "sticky mode keeps failing ($fired reads refused)"
else
  bad "sticky injection self-test" "rc=$rc fired=$fired"
fi

# A fault aimed past the end of the run must leave everything green -- the
# negative control for every cell below.
EXT4DUMP_EIO_READ_AT=999999 "$DUMP" "$img" ls / >/dev/null 2>"$WORK/none.err"
rc=$?
if [ $rc -eq 0 ] && ! grep -q 'EIO-INJECT' "$WORK/none.err"; then
  ok "an unreached fault changes nothing"
else
  bad "unreached-fault control" "rc=$rc"
fi

finish
