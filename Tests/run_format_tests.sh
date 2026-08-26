#!/usr/bin/env bash
# Format tests.
#
# A formatter is judged by two independent authorities, never by its own
# reader: e2fsck must call the result clean, and the real Linux kernel must
# mount it, read what we wrote, and write to it in turn.
#
# The geometry sweep matters more than it looks. lwext4's mkfs had three
# separate bugs that only appear at particular sizes -- a free-block count that
# assumed the last block group was full, bitmap padding it never wrote, and an
# inodes-per-group value that was a multiple of 4 rather than 8. Each was
# invisible at the sizes a casual test would pick.
#
# Runs unattended. Writes a report to build/format-report.txt.
set -uo pipefail

export PATH="/opt/homebrew/opt/e2fsprogs/sbin:/opt/homebrew/opt/e2fsprogs/bin:$PATH"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DUMP="$ROOT/build/bin/ext4dump"
WORK="$ROOT/build/format"
REPORT="$ROOT/build/format-report.txt"
DOCKER_IMAGE="debian:stable-slim"

rm -rf "$WORK"; mkdir -p "$WORK"
: > "$REPORT"

PASS=0; FAIL=0
note() { echo "$*" | tee -a "$REPORT"; }
ok()   { PASS=$((PASS+1)); note "  ok    $1"; }
# `bad` must end in a success status. Without it the trailing test is the
# function's exit code, and it is false whenever there is no detail argument --
# so the common `cmd && bad "..." || ok "..."` idiom runs *both* arms and the
# suite reports a failure and a pass for the same check.
bad()  { FAIL=$((FAIL+1)); note "  FAIL  $1"; [ $# -gt 1 ] && note "        $2"; return 0; }
expect_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }

[ -x "$DUMP" ] || { echo "build first: make tools"; exit 1; }
command -v mke2fs >/dev/null || { echo "mke2fs not found; brew install e2fsprogs"; exit 1; }

blank() {  # blank <path> <megabytes>
  rm -f "$1"; dd if=/dev/zero of="$1" bs=1m count="$2" 2>/dev/null
}

note "########## FORMAT ##########"

# ================================================================ geometry ==
#
# Sizes chosen so that some leave a partial last block group and some do not,
# across all three block sizes. That distinction is what the free-count and
# inodes-per-group bugs turned on.

note ""
note "geometry sweep: e2fsck must be clean on every combination"
note ""

SWEEP_FAIL=0; SWEEP_N=0; FIRST_ERR=""
for mb in 9 17 33 47 64 65 100 128 129 200 257 400 512; do
  for bs in 1024 2048 4096; do
    for gen in 2 3 4; do
      # ext3/ext4 carry a journal of at least 1024 blocks; below that the
      # volume cannot hold one and the format is expected to fail.
      [ "$gen" -ne 2 ] && [ $(( mb * 1024 * 1024 )) -lt 8388608 ] && continue
      img="$WORK/sweep.img"
      blank "$img" "$mb"
      SWEEP_N=$((SWEEP_N+1))
      if ! "$DUMP" "$img" format "$gen" "$bs" SWEEP >/dev/null 2>&1; then
        SWEEP_FAIL=$((SWEEP_FAIL+1))
        [ -z "$FIRST_ERR" ] && FIRST_ERR="${mb}MB bs=$bs ext$gen: format refused it"
        continue
      fi
      if ! e2fsck -fn "$img" >/dev/null 2>&1; then
        SWEEP_FAIL=$((SWEEP_FAIL+1))
        [ -z "$FIRST_ERR" ] && FIRST_ERR="${mb}MB bs=$bs ext$gen: $(e2fsck -fn "$img" 2>&1 | grep -m1 -vE '^e2fsck|^Pass|^$' | cut -c1-50)"
      fi
    done
  done
done
rm -f "$WORK/sweep.img"

if [ "$SWEEP_FAIL" -eq 0 ]; then
  ok "$SWEEP_N size/block-size/generation combinations are e2fsck-clean"
else
  bad "$SWEEP_N size/block-size/generation combinations are e2fsck-clean" \
      "$SWEEP_FAIL failed, first: $FIRST_ERR"
fi

# ================================================================= options ==

note ""
note "options are honoured"
note ""

img="$WORK/opts.img"
blank "$img" 128
"$DUMP" "$img" format 4 4096 MYLABEL >/dev/null 2>&1
expect_eq "the label reaches the superblock" "MYLABEL" \
  "$(dumpe2fs -h "$img" 2>/dev/null | sed -n 's/^Filesystem volume name: *//p')"
expect_eq "the block size is what we asked for" "4096" \
  "$(dumpe2fs -h "$img" 2>/dev/null | sed -n 's/^Block size: *//p')"

blank "$img" 128
"$DUMP" "$img" format 4 1024 SMALLBS >/dev/null 2>&1
expect_eq "a 1 KiB block size is honoured" "1024" \
  "$(dumpe2fs -h "$img" 2>/dev/null | sed -n 's/^Block size: *//p')"

# inodes_per_group must be a multiple of 8: every group's inode bitmap has to
# start on a byte boundary, and e2fsck checks the tail padding when it does not.
ipg=$(dumpe2fs -h "$img" 2>/dev/null | sed -n 's/^Inodes per group: *//p')
if [ $(( ipg % 8 )) -eq 0 ]; then
  ok "inodes per group is a multiple of 8 ($ipg)"
else
  bad "inodes per group is a multiple of 8" "got $ipg"
fi

blank "$img" 128
"$DUMP" "$img" format 2 1024 EXT2VOL >/dev/null 2>&1
if dumpe2fs -h "$img" 2>/dev/null | grep -q "has_journal"; then
  bad "ext2 is created without a journal"
else
  ok "ext2 is created without a journal"
fi
blank "$img" 128
"$DUMP" "$img" format 3 1024 EXT3VOL >/dev/null 2>&1
if dumpe2fs -h "$img" 2>/dev/null | grep -q "has_journal"; then
  ok "ext3 is created with a journal"
else
  bad "ext3 is created with a journal"
fi

# Two volumes formatted back to back must not share a UUID: DiskArbitration
# keys container identity on it, and lwext4's mkfs writes whatever it is given
# without generating one.
blank "$WORK/u1.img" 16; "$DUMP" "$WORK/u1.img" format 4 1024 U1 >/dev/null 2>&1
blank "$WORK/u2.img" 16; "$DUMP" "$WORK/u2.img" format 4 1024 U2 >/dev/null 2>&1
u1=$(dumpe2fs -h "$WORK/u1.img" 2>/dev/null | sed -n 's/^Filesystem UUID: *//p')
u2=$(dumpe2fs -h "$WORK/u2.img" 2>/dev/null | sed -n 's/^Filesystem UUID: *//p')
if [ -n "$u1" ] && [ "$u1" != "$u2" ] && [ "$u1" != "00000000-0000-0000-0000-000000000000" ]; then
  ok "each volume gets its own UUID"
else
  bad "each volume gets its own UUID" "[$u1] vs [$u2]"
fi
rm -f "$WORK/u1.img" "$WORK/u2.img"

# ============================================================ round-tripping ==

note ""
note "the volume we create is usable"
note ""

img="$WORK/rt.img"
blank "$img" 128
"$DUMP" "$img" format 4 4096 ROUNDTRIP >/dev/null 2>&1

# Our own driver must be able to mount and write what we just created.
"$DUMP" "$img" mkdir /docs >/dev/null 2>&1
"$DUMP" "$img" create /docs/hello.txt >/dev/null 2>&1
"$DUMP" "$img" write /docs/hello.txt "written after formatting" >/dev/null 2>&1
"$DUMP" "$img" symlink /docs/hello.txt /link >/dev/null 2>&1
expect_eq "our driver mounts and writes the volume it created" "written after formatting" \
  "$("$DUMP" "$img" cat /docs/hello.txt 2>/dev/null)"
if e2fsck -fn "$img" >/dev/null 2>&1; then
  ok "still e2fsck-clean after writing to it"
else
  bad "still e2fsck-clean after writing to it"
fi

if ! docker info >/dev/null 2>&1; then
  note ""
  note "  skipped the Linux checks: docker is not running"
else
  docker run --rm --privileged -v "$WORK:/w" "$DOCKER_IMAGE" bash -c '
    dmesg -C 2>/dev/null
    mkdir -p /mnt/t
    if ! mount -o loop /w/rt.img /mnt/t 2>/dev/null; then echo "MOUNT-REFUSED"; exit 0; fi
    echo "CONTENT $(cat /mnt/t/docs/hello.txt 2>/dev/null)"
    echo "SYMLINK $(readlink /mnt/t/link 2>/dev/null)"
    echo "LABEL $(findmnt -no SOURCE /mnt/t | xargs blkid -s LABEL -o value 2>/dev/null)"
    if echo "from linux" > /mnt/t/linux.txt 2>/dev/null && mkdir -p /mnt/t/newdir 2>/dev/null; then
      echo "LINUXWRITE ok"
    fi
    umount /mnt/t
    echo "COMPLAINTS $(dmesg | grep -c "EXT4-fs error" || true)"
  ' > "$WORK/linux.log" 2>&1

  if grep -q "MOUNT-REFUSED" "$WORK/linux.log"; then
    bad "the Linux kernel mounts the volume we created"
  else
    ok "the Linux kernel mounts the volume we created"
  fi
  expect_eq "Linux reads what we wrote" "written after formatting" \
    "$(sed -n 's/^CONTENT //p' "$WORK/linux.log")"
  expect_eq "Linux resolves the symlink we made" "/docs/hello.txt" \
    "$(sed -n 's/^SYMLINK //p' "$WORK/linux.log")"
  expect_eq "Linux sees the label we set" "ROUNDTRIP" \
    "$(sed -n 's/^LABEL //p' "$WORK/linux.log")"
  expect_eq "Linux can write to it" "ok" \
    "$(sed -n 's/^LINUXWRITE //p' "$WORK/linux.log")"
  expect_eq "the kernel log is silent" "0" \
    "$(sed -n 's/^COMPLAINTS //p' "$WORK/linux.log")"

  # And back again: what Linux added must be visible to us.
  expect_eq "we read back what Linux added" "from linux" \
    "$("$DUMP" "$img" cat /linux.txt 2>/dev/null)"
  if e2fsck -fn "$img" >/dev/null 2>&1; then
    ok "e2fsck clean after both drivers have written"
  else
    bad "e2fsck clean after both drivers have written"
  fi
fi

# ================================================================= rename ==
#
# The volume label is set at format time and changed afterwards through the
# same 16-byte superblock field, so the two belong together.

note ""
note "renaming a volume"
note ""

img="$WORK/rename.img"
blank "$img" 64
"$DUMP" "$img" format 4 4096 BEFORE >/dev/null 2>&1
"$DUMP" "$img" label AFTER >/dev/null 2>&1
expect_eq "the label changes" "AFTER" \
  "$(dumpe2fs -h "$img" 2>/dev/null | sed -n 's/^Filesystem volume name: *//p')"
if e2fsck -fn "$img" >/dev/null 2>&1; then
  ok "e2fsck clean after a rename"
else
  bad "e2fsck clean after a rename"
fi

# ext4's label field is exactly 16 bytes with no terminator when full.
"$DUMP" "$img" label "SIXTEENCHARSABCD" >/dev/null 2>&1
expect_eq "a label that exactly fills the field" "SIXTEENCHARSABCD" \
  "$(dumpe2fs -h "$img" 2>/dev/null | sed -n 's/^Filesystem volume name: *//p')"

# Silently truncating would leave the volume named something the user did not
# type, which is worse than refusing.
"$DUMP" "$img" label "THIS_LABEL_IS_MUCH_TOO_LONG" >/dev/null 2>&1 \
  && bad "an over-long label is refused" || ok "an over-long label is refused"
expect_eq "a refused rename leaves the old label" "SIXTEENCHARSABCD" \
  "$(dumpe2fs -h "$img" 2>/dev/null | sed -n 's/^Filesystem volume name: *//p')"

if docker info >/dev/null 2>&1; then
  cp "$img" "$WORK/rn.img"
  docker run --rm --privileged -v "$WORK:/w" "$DOCKER_IMAGE" bash -c '
    mkdir -p /mnt/t
    mount -o loop /w/rn.img /mnt/t 2>/dev/null || exit 0
    echo "LABEL $(findmnt -no SOURCE /mnt/t | xargs blkid -s LABEL -o value 2>/dev/null)"
    umount /mnt/t
  ' > "$WORK/rn.log" 2>&1
  expect_eq "Linux sees the new label" "SIXTEENCHARSABCD" \
    "$(sed -n 's/^LABEL //p' "$WORK/rn.log")"
  rm -f "$WORK/rn.img"
fi
rm -f "$img"

# =============================================================== refusals ==
#
# A formatter that cannot say no is dangerous.

note ""
note "bad requests are refused"
note ""

img="$WORK/bad.img"
blank "$img" 64
"$DUMP" "$img" format 5 4096 X >/dev/null 2>&1 && bad "an unknown generation is refused" || ok "an unknown generation is refused"
"$DUMP" "$img" format 4 3000 X >/dev/null 2>&1 && bad "a non-power-of-two block size is refused" || ok "a non-power-of-two block size is refused"
"$DUMP" "$img" format 4 8192 X >/dev/null 2>&1 && bad "an oversized block size is refused" || ok "an oversized block size is refused"

blank "$img" 2
"$DUMP" "$img" format 4 4096 X >/dev/null 2>&1 && bad "a volume too small for a journal is refused" || ok "a volume too small for a journal is refused"

# Formatting must not touch a volume it has refused.
blank "$img" 64
mke2fs -q -t ext4 -L KEEPME -F "$img" 2>/dev/null
before=$(shasum -a 256 "$img" | cut -d' ' -f1)
"$DUMP" "$img" format 9 4096 X >/dev/null 2>&1
expect_eq "a refused format leaves the volume untouched" "$before" \
  "$(shasum -a 256 "$img" | cut -d' ' -f1)"
rm -f "$img"

note ""
note "─────────────────────────────────"
note "passed: $PASS   failed: $FAIL"
note "report: $REPORT"

rm -f "$WORK/rt.img" "$WORK/opts.img"
[ "$FAIL" -eq 0 ]
