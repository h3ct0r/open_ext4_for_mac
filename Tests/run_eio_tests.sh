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

# fresh <name> [gen]: a small formatted image to hurt.
fresh() {
  local img="$WORK/$1.img" gen="${2:-4}"
  rm -f "$img"
  truncate -s 64m "$img"
  "$DUMP" "$img" format "$gen" 4096 >/dev/null 2>&1 || { echo "format failed" >&2; return 1; }
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

# ------------------------------------------- orphan cleanup, unreadable bitmap --
# The mid-release crash state: an inode freed by the release, still on the
# orphan list because the head publish never landed. ext2 (gen 2), because
# without a journal the free and the head publish are separate writes and this
# state is exactly what a cut between them leaves. Cleanup's job here is to
# drop the entry WITHOUT touching the inode -- freeing it again corrupts the
# group counters.
#
# The cell aims EIO at cleanup's inode-bitmap read: the walk cannot tell
# whether the inode is in use, and the only safe answer is to stop and leave
# the list for the next mount. The old fallback guessed "in use" and routed an
# unreadable bitmap into truncate-and-free: e2fsck then showed the double-free
# ("Free inodes count wrong") while the mount reported success.
note ""
note "orphan cleanup on a medium that cannot answer"
note ""

img=$(fresh orphan 2)
"$DUMP" "$img" create /f >/dev/null 2>&1
ino=$("$DUMP" "$img" rm-open /f 2>/dev/null | sed -n 's/.*inode \([0-9]*\).*/\1/p')
if [ -z "$ino" ]; then
  bad "orphan fixture: rm-open reported no inode"
else
  # Complete the free by hand, the way the interrupted release would have:
  # bitmap bit cleared, deletion time set, both free counters bumped.
  gfree=$(dumpe2fs "$img" 2>/dev/null | sed -n 's/.* \([0-9]*\) free inodes.*/\1/p' | head -1)
  debugfs -w -R "freei <$ino>" "$img" >/dev/null 2>&1
  debugfs -w -R "sif <$ino> dtime 1000000000" "$img" >/dev/null 2>&1
  debugfs -w -R "set_bg 0 free_inodes_count $((gfree+1))" "$img" >/dev/null 2>&1
  debugfs -w -R "ssv free_inodes_count $((gfree+1))" "$img" >/dev/null 2>&1

  # Control: with a readable bitmap, cleanup drops the entry and e2fsck is
  # fully clean afterwards. This proves the fixture, not the fix.
  cp "$img" "$WORK/orphan-ctl.img"
  "$DUMP" "$WORK/orphan-ctl.img" label CTL >/dev/null 2>&1
  if e2fsck -fn "$WORK/orphan-ctl.img" >/dev/null 2>&1; then
    ok "fixture: a readable bitmap settles the entry cleanly"
  else
    bad "orphan fixture is not self-consistent" \
        "$(e2fsck -fn "$WORK/orphan-ctl.img" 2>&1 | grep -Ev '^e2fsck|^Pass' | head -2 | tr '\n' ' ')"
  fi

  # Aim: the bitmap block's offset comes from dumpe2fs, its read ordinal from
  # a traced control mount (TRC R seq is 0-based; the knob is 1-based).
  bblk=$(dumpe2fs "$img" 2>/dev/null | sed -n 's/.*Inode bitmap at \([0-9]*\).*/\1/p' | head -1)
  cp "$img" "$WORK/orphan-trc.img"
  seqs=$(EXT4DUMP_TRACE=- "$DUMP" "$WORK/orphan-trc.img" label TRC 2>&1 >/dev/null \
         | sed -n "s/^TRC R seq=\([0-9]*\) off=$((bblk * 4096)) .*/\1/p")
  if [ -z "$seqs" ]; then
    bad "could not locate the inode-bitmap read in the trace"
  fi
  for seq in $seqs; do
    cp "$img" "$WORK/orphan-red.img"
    EXT4DUMP_EIO_READ_AT=$((seq + 1)) \
      "$DUMP" "$WORK/orphan-red.img" label EIO >/dev/null 2>"$WORK/orphan-red.err"
    if ! grep -q '^EIO-INJECT read' "$WORK/orphan-red.err"; then
      bad "bitmap-read fault never fired (ordinal $((seq + 1)))"
      continue
    fi
    # The failure must say what and why -- errno and progress, not a shrug.
    if grep -q 'orphan-list cleanup failed (errno [0-9]*)' "$WORK/orphan-red.err"; then
      ok "the failed cleanup reports its errno"
    else
      bad "cleanup failed without saying why" \
          "$(grep 'core:' "$WORK/orphan-red.err" | head -1)"
    fi
    # The next mount, with the medium answering again, must settle the list --
    # and nothing about the failed attempt may have touched the counters.
    "$DUMP" "$WORK/orphan-red.img" label OK2 >/dev/null 2>&1
    if e2fsck -fn "$WORK/orphan-red.img" >/dev/null 2>&1; then
      ok "an unreadable bitmap defers the entry instead of freeing it (read #$((seq + 1)))"
    else
      bad "cleanup guessed instead of stopping (read #$((seq + 1)))" \
          "$(e2fsck -fn "$WORK/orphan-red.img" 2>&1 | grep -Ei 'wrong|differ' | head -2 | tr '\n' ' ')"
    fi
  done
fi

# --------------------------------------------------- a read that fails midway --
# A file of five blocks whose last block the medium refuses. ext4b_read used
# to report the four successful blocks as rc 0 -- indistinguishable from EOF,
# so `cp` off a failing stick produced silently truncated files. The command
# must fail; how far it got is the caller's to inspect, not a reason to lie.
note ""
note "a read that fails midway is a failure"
note ""

img=$(fresh partial)
"$DUMP" "$img" create /f >/dev/null 2>&1
"$DUMP" "$img" prealloc /f 20000 >/dev/null 2>&1
"$DUMP" "$img" truncate /f 20000 >/dev/null 2>&1
nreads=$(EXT4DUMP_TRACE=- "$DUMP" "$img" cat /f 2>&1 >/dev/null | grep -c 'TRC R')
EXT4DUMP_EIO_READ_AT=$nreads "$DUMP" "$img" cat /f >"$WORK/partial.out" 2>"$WORK/partial.err"
rc=$?
if ! grep -q '^EIO-INJECT read' "$WORK/partial.err"; then
  bad "mid-file read fault never fired (aimed at read #$nreads of $nreads)"
elif [ $rc -ne 0 ]; then
  ok "a truncated read fails instead of posing as EOF (rc=$rc)"
else
  bad "a mid-file EIO was reported as success" \
      "rc=0 with $(wc -c < "$WORK/partial.out" | tr -d ' ') of 20000 bytes"
fi

finish
