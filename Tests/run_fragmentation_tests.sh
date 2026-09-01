#!/usr/bin/env bash
# What interleaved allocation costs, and that it stays paid down.
#
# A Finder copy onto a stick came back 89% non-contiguous while the same
# corpus onto an image was 2.4%. Five explanations were measured and refuted
# -- preallocation, file count, volume fullness, the copy engine, concurrent
# background writes -- and the sixth is the one that reproduces: it is not the
# medium, it is what a slow medium causes. Several files in flight at once, and
# every write call becomes its own extent, because the block after this
# inode's last extent has been taken by whichever file allocated next.
#
# `ext4dump interleave` dials that directly. Same bytes, same files, same
# mount, one variable: `serial` finishes each file before starting the next,
# `round` walks them a chunk at a time. No threads, no timing, no stick.
#
# Measured before the fix, eight 32 MiB files with 1 MiB writes: 2 extents
# serial, 34 round -- one per megabyte, which is the field's shape exactly,
# and 1 MiB is the largest write macOS issues.
#
# The cells below are the two halves that have to hold together. Fragmentation
# must come down, AND the space the allocator reserves ahead to bring it down
# must come back: a reservation that is never released is a space leak, which
# is a worse bug than the fragmentation it cures.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/Tests/lib.sh"

DUMP="$ROOT/build/bin/ext4dump"
WORK="$ROOT/build/frag"

[ -x "$DUMP" ] || { echo "build first: make tools"; exit 1; }

rm -rf "$WORK"; mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

FILES=8
MIB=16
CHUNK_KIB=1024          # what FSKit hands us at most, so what the field sees

# extents <image> <path>: how many extents map the file.
extents() {
  "$DUMP" "$1" extents "$2" 2>/dev/null | grep -c "logical"
}

# alloc_minus_size <image> <path>: blocks held past end-of-file, in bytes.
# This is the reservation that has to come back.
past_eof() {
  "$DUMP" "$1" extents "$2" 2>/dev/null \
    | sed -nE 's/.*size=([0-9]+) alloc=([0-9]+).*/\2 \1/p' \
    | awk '{print $1 - $2}'
}

run_arm() {                 # run_arm <order> -> echoes the image path
  local order="$1"
  local img="$WORK/$order.img"
  rm -f "$img"
  python3 -c "open('$img','wb').truncate(2*1024*1024*1024)"
  "$DUMP" "$img" format 4 4096 FRAG >/dev/null 2>&1 || return 1
  "$DUMP" "$img" interleave "$FILES" "$MIB" "$CHUNK_KIB" "$order" \
      >/dev/null 2>&1 || return 1
  echo "$img"
}

echo "########## what interleaved allocation costs ##########"
echo ""
echo "the control: one file at a time"
echo ""

SERIAL=$(run_arm serial) || { echo "serial arm failed"; exit 1; }
s_ext=$(extents "$SERIAL" /il-000.bin)
if [ "$s_ext" -le 3 ]; then
  ok "written one after another, a ${MIB} MiB file is $s_ext extent(s)"
else
  bad "written one after another, a ${MIB} MiB file is few extents" \
      "got $s_ext"
fi

echo ""
echo "the shape the field produced"
echo ""

ROUND=$(run_arm round) || { echo "round arm failed"; exit 1; }
r_ext=$(extents "$ROUND" /il-000.bin)

# The bar. Without an allocation reservation each 1 MiB write call is its own
# extent, so a 16 MiB file arrives as ~17. Reserving ahead should hold it to a
# handful. This is the cell the fix exists to turn green; it fails against a
# build without one, which is the only reason to believe it.
if [ "$r_ext" -le 6 ]; then
  ok "interleaved, the same file is $r_ext extent(s)"
else
  bad "interleaved, the same file is at most 6 extents" \
      "got $r_ext -- about one per ${CHUNK_KIB} KiB write, which is the unfixed shape"
fi

# Ratio rather than absolute count, because the absolute one moves with the
# fixture and this is the thing that actually differs between the two arms.
if [ "$r_ext" -le $(( s_ext * 4 )) ]; then
  ok "interleaving costs less than 4x the serial layout"
else
  bad "interleaving costs less than 4x the serial layout" \
      "serial $s_ext, interleaved $r_ext"
fi

echo ""
echo "and the space reserved to achieve it comes back"
echo ""

# Every file, not just the first: eviction is what returns a reservation, and
# an eviction policy that only ever returns the oldest would leave the last
# few holding theirs. Slack is allowed -- a file's last block is partial, and
# the allocator may round -- but not megabytes of it.
leaked=""
for i in $(seq 0 $((FILES - 1))); do
  p=$(printf "/il-%03d.bin" "$i")
  past=$(past_eof "$ROUND" "$p")
  [ -n "$past" ] || { leaked="$leaked $p(unreadable)"; continue; }
  [ "$past" -le 65536 ] || leaked="$leaked $p($past)"
done
[ -z "$leaked" ] \
  && ok "no file holds more than 64 KiB past its end" \
  || bad "no file holds more than 64 KiB past its end" "held:$leaked"

echo ""
echo "the bytes are still the bytes"
echo ""

# The allocation path is where every corruption bug this project has found has
# lived, so a cell that only counted extents would be measuring the wrong
# thing. Each file is filled with one repeated byte, distinct per file.
wrong=""
for i in $(seq 0 $((FILES - 1))); do
  p=$(printf "/il-%03d.bin" "$i")
  want_byte=$(python3 -c "print(chr(ord('A') + $i % 26))")
  n=$("$DUMP" "$ROUND" cat "$p" 2>/dev/null | tr -d "$want_byte" | wc -c | tr -d ' ')
  size=$("$DUMP" "$ROUND" stat "$p" 2>/dev/null | sed -nE 's/.*size[^0-9]*([0-9]+).*/\1/p' | head -1)
  [ "${n:-1}" = "0" ] || wrong="$wrong $p(bad-bytes=$n)"
  [ "${size:-0}" = "$((MIB * 1024 * 1024))" ] || wrong="$wrong $p(size=$size)"
done
[ -z "$wrong" ] \
  && ok "every interleaved file reads back whole, and all its own byte" \
  || bad "every interleaved file reads back whole" "$wrong"

fsck.ext4 -fn "$ROUND" >/dev/null 2>&1 \
  && ok "e2fsck finds nothing wrong with the interleaved volume" \
  || bad "e2fsck finds nothing wrong with the interleaved volume" \
         "$(fsck.ext4 -fn "$ROUND" 2>&1 | tail -6)"

fsck.ext4 -fn "$SERIAL" >/dev/null 2>&1 \
  && ok "nor with the serial one" \
  || bad "nor with the serial one" "$(fsck.ext4 -fn "$SERIAL" 2>&1 | tail -6)"

echo ""
echo "a volume still fills all the way up"
echo ""

# The failure mode a reservation invites: the volume reports itself full while
# the allocator is sitting on blocks no file is using. It cannot be seen from
# outside -- unmounting returns them, so a free count read afterwards shows a
# volume that filled perfectly -- so `interleave` reports the count from inside
# the mount when it stops.
#
# The number is a measurement, not a guess. A 512 MB volume written to ENOSPC
# one file at a time took 519,045,120 bytes before any of this existed. With
# reservations that stopped being taken below the low-space threshold but were
# never given back, it took 510,656,512 -- exactly one 8 MiB reservation less,
# left holding when the threshold also stopped the evictions that would have
# returned it. Releasing what is held, rather than merely taking no more,
# restores the original figure exactly.
FULL="$WORK/full.img"
python3 -c "open('$FULL','wb').truncate(512*1024*1024)"
"$DUMP" "$FULL" format 4 4096 FRAG >/dev/null 2>&1
fill=$("$DUMP" "$FULL" interleave 80 8 1024 serial 2>&1 \
       | sed -nE 's/interleave stopped after ([0-9]+) bytes.*/\1/p')
if [ -n "$fill" ] && [ "$fill" -ge 518000000 ]; then
  ok "filled to ENOSPC with $fill bytes, nothing held back"
else
  bad "filled to ENOSPC with everything the volume has" \
      "got ${fill:-no ENOSPC at all}, expected at least 518000000"
fi

free_left=$("$DUMP" "$FULL" interleave 1 1 1024 serial 2>&1 \
            | sed -nE 's/.*with ([0-9]+) of [0-9]+ block\(s\) free/\1/p')
[ "${free_left:-x}" = "0" ] \
  && ok "and the volume genuinely has nothing left" \
  || bad "and the volume genuinely has nothing left" "free blocks: ${free_left:-unknown}"

finish
