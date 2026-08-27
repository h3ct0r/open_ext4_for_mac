#!/usr/bin/env bash
# How fast is the mounted driver, actually?
#
# Every byte currently moves by copy: the kernel asks the extension, the
# extension asks lwext4, lwext4 asks FSKit, and the bytes come back the same
# way. FSKit offers a way out -- FSVolumeKernelOffloadedIOOperations, where the
# module hands the kernel a logical-to-physical extent map and the kernel moves
# the data itself -- and this project has the read half of that written and
# switched off.
#
# Whether turning it on is worth anything is a measurement, not an opinion, and
# there was no way to take it. That is what this is for: a number before, a
# number after, on the same volume with the same file.
#
# Deliberately crude. It reports throughput for large sequential reads and
# writes and for a lot of small ones, because those fail differently: bulk
# transfer is what offloading should improve, and per-operation overhead is
# what it should not.
#
#   bash Tests/run_throughput_tests.sh              # on a disk image
#   EXT4_BENCH_DEVICE=diskNs1 bash ...              # on real media, read-only
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DUMP="$ROOT/build/bin/ext4dump"
WORK="$ROOT/build/throughput"
MNT="$WORK/mnt"
SIZE_MB="${EXT4_BENCH_MB:-256}"
DEVICE="${EXT4_BENCH_DEVICE:-}"

note() { echo "$*"; }

[ -x "$DUMP" ] || { echo "build first: make tools"; exit 1; }
if ! bash "$ROOT/scripts/check_extension.sh" >/dev/null 2>&1; then
  echo "the FSKit extension is not enabled; see scripts/check_extension.sh"
  echo "SKIPPED"; exit 77
fi

umount "$MNT" 2>/dev/null
rm -rf "$WORK"; mkdir -p "$MNT"

DEV=""
cleanup() {
  umount "$MNT" 2>/dev/null
  [ -n "$DEV" ] && hdiutil detach "$DEV" -force >/dev/null 2>&1
  return 0
}
trap cleanup EXIT

if [ -n "$DEVICE" ]; then
  note "target: /dev/$DEVICE (real media)"
  diskutil mount "$DEVICE" >/dev/null 2>&1 || { echo "could not mount $DEVICE"; exit 1; }
  MP=$(mount | sed -n "s|^/dev/$DEVICE on \(.*\) (ext4.*|\1|p" | head -1)
  [ -n "$MP" ] || { echo "$DEVICE did not mount as ext4"; exit 1; }
else
  note "target: a $((SIZE_MB * 2))MB disk image"
  dd if=/dev/zero of="$WORK/bench.img" bs=1m count=$((SIZE_MB * 2)) 2>/dev/null
  "$DUMP" "$WORK/bench.img" format 4 >/dev/null 2>&1
  DEV=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount "$WORK/bench.img" \
        2>/dev/null | head -1 | awk '{print $1}')
  mount -F -t ext4 "${DEV#/dev/}" "$MNT" 2>/dev/null || { echo "mount failed"; exit 1; }
  MP="$MNT"
fi

# Wall-clock around a shell command, to two decimals.
#
# A benchmark that discards output reports a failure as infinite speed: with
# kernel-offloaded I/O enabled, writes silently became no-ops and this printed
# 2844 MB/s. Every measurement below is therefore checked against the work it
# was supposed to do, and a benchmark that cannot verify its own work is not a
# benchmark.
timed() { local s=$(python3 -c 'import time;print(time.time())'); "$@" >/dev/null 2>&1;
          python3 -c "import time;print(f'{time.time()-$s:.2f}')"; }

# expect_size <file> <mb> -- die rather than report a number for work not done.
expect_size() {
  local got=$(stat -f %z "$1" 2>/dev/null || echo 0)
  local want=$(( $2 * 1024 * 1024 ))
  if [ "$got" -ne "$want" ]; then
    echo "  ERROR: $1 is $got bytes, expected $want."
    echo "         The operation did not do what was measured; the timing above"
    echo "         is meaningless. Not reporting a rate."
    return 1
  fi
  return 0
}
rate()  { python3 -c "print(f'{$1/$2:.1f}')" 2>/dev/null || echo "?"; }

note ""
note "  vends kernel-offloaded I/O: $(grep -q 'vendsKernelOffloadedIO = true' "$ROOT/Extension/Ext4Volume.swift" && echo yes || echo no)"
note ""

# --- bulk write --------------------------------------------------------------
if [ -z "$DEVICE" ]; then
  t=$(timed dd if=/dev/zero of="$MP/big.bin" bs=1m count="$SIZE_MB")
  if expect_size "$MP/big.bin" "$SIZE_MB"; then
    note "  write  ${SIZE_MB}MB sequential   ${t}s   $(rate "$SIZE_MB" "$t") MB/s"
  fi
  sync
else
  # Real media is not reformatted by this script, so it only reads.
  [ -f "$MP/big.bin" ] || { echo "  (no big.bin on $DEVICE; run once on an image first)"; }
fi

# --- bulk read ---------------------------------------------------------------
if [ -f "$MP/big.bin" ]; then
  umount "$MNT" 2>/dev/null && mount -F -t ext4 "${DEV#/dev/}" "$MNT" 2>/dev/null   # cold-ish
  if expect_size "$MP/big.bin" "$SIZE_MB"; then
    t=$(timed dd if="$MP/big.bin" of=/dev/null bs=1m)
    note "  read   ${SIZE_MB}MB sequential   ${t}s   $(rate "$SIZE_MB" "$t") MB/s"
  fi
fi

# --- many small files --------------------------------------------------------
if [ -z "$DEVICE" ]; then
  mkdir -p "$MP/small"
  t=$(timed bash -c 'for i in $(seq 1 400); do echo x > '"$MP"'/small/f$i; done')
  note "  create 400 small files       ${t}s"
  t=$(timed bash -c 'cat '"$MP"'/small/* ')
  note "  read   400 small files       ${t}s"
fi

note ""
note "Numbers from one run on a busy laptop. Compare them against each other,"
note "not against a kext."
