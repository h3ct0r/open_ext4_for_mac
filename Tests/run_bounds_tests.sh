#!/usr/bin/env bash
# Bounds, overflow, and POSIX-semantics checks for the bridge.
#
# Every case here is a way the bridge could be made to write out of bounds,
# wrap an arithmetic check, or accept an operation POSIX forbids -- found in
# the pre-release audit. Each is red before its fix. Offline, seconds.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/Tests/lib.sh"

DUMP="$ROOT/build/bin/ext4dump"
WORK="$ROOT/build/bounds"
[ -x "$DUMP" ] || { echo "build first: make tools"; exit 1; }
rm -rf "$WORK"; mkdir -p "$WORK"

echo "########## BOUNDS & SEMANTICS ##########"
echo ""

new_vol() {  # new_vol <img> <gen> <bsize>
  rm -f "$1"
  dd if=/dev/zero of="$1" bs=1m count=64 2>/dev/null
  "$DUMP" "$1" format "$2" "$3" BOUNDS >/dev/null 2>&1
}

# --- long-symlink heap overflow on a small-block volume ---------------------
# ext4 slow symlinks live in a single block, so a target at or beyond the
# block size is not representable -- and the old code memcpy'd it into a
# one-block buffer anyway. On a 1 KiB volume a 2000-byte target overflowed
# the heap by ~1000 bytes.
echo "long symlinks on small blocks"
IMG="$WORK/sym1k.img"; new_vol "$IMG" 4 1024
big=$(printf 'a%.0s' $(seq 1 2000))
out=$("$DUMP" "$IMG" symlink "$big" /link 2>&1); rc=$?
[ $rc -ne 0 ] && grep -qiE "name too long|too long" <<<"$out" \
  && ok "a 2000-byte target on a 1 KiB volume is refused, not overflowed" \
  || bad "a 2000-byte target on a 1 KiB volume is refused" "$out"
# and it left nothing behind
"$DUMP" "$IMG" stat /link >/dev/null 2>&1 \
  && bad "no dangling symlink entry remains after the refusal" \
  || ok "no dangling symlink entry remains after the refusal"
e2fsck -fn "$IMG" >/dev/null 2>&1 \
  && ok "e2fsck clean after the refused symlink" \
  || bad "e2fsck clean after the refused symlink"

# a target that DOES fit (block size minus the terminator) still works
mid=$(printf 'b%.0s' $(seq 1 1000))
"$DUMP" "$IMG" symlink "$mid" /ok >/dev/null 2>&1 \
  && ok "a 1000-byte target on a 1 KiB volume is stored" \
  || bad "a 1000-byte target on a 1 KiB volume is stored"
e2fsck -fn "$IMG" >/dev/null 2>&1 \
  && ok "e2fsck clean after a valid slow symlink" \
  || bad "e2fsck clean after a valid slow symlink"

# same, under batching -- a half-made symlink must not be committed
IMG="$WORK/sym1k_b.img"; new_vol "$IMG" 4 1024
EXT4B_TXN_BATCH=8 "$DUMP" "$IMG" symlink "$big" /link >/dev/null 2>&1
"$DUMP" "$IMG" stat /link >/dev/null 2>&1 \
  && bad "batched: no committed symlink after a refused one" \
  || ok "batched: no committed symlink after a refused one"

# --- write past the addressable end returns EFBIG, fast ---------------------
echo
echo "writes past the addressable end"
IMG="$WORK/big.img"; new_vol "$IMG" 4 4096
"$DUMP" "$IMG" create /f.bin >/dev/null 2>&1
# 4096-byte blocks address 2^32 blocks -> 2^44 bytes. Offset just past that
# used to truncate the logical block number to 32 bits and overwrite block 0.
huge=$(( (1 << 44) + 8192 ))
# No timeout(1) on macOS; perl's alarm bounds the (possibly hanging) call.
out=$(perl -e 'alarm 20; exec @ARGV' "$DUMP" "$IMG" write /f.bin "X" "$huge" 2>&1); rc=$?
[ $rc -ne 0 ] && grep -qiE "too large|file too large|EFBIG" <<<"$out" \
  && ok "a write past 2^44 bytes is refused with EFBIG" \
  || bad "a write past 2^44 bytes is refused with EFBIG" "$out(rc=$rc)"

# --- crafted superblock claiming more blocks than the device ----------------
echo
echo "oversized superblock"
IMG="$WORK/oversize.img"; new_vol "$IMG" 4 4096
# s_blocks_count_lo at offset 0x404; set it to 0xFFFFFFFF. With 64BIT off this
# is a 4-billion-block claim on a 64 MiB device -- must be refused.
printf '\xff\xff\xff\xff' | dd of="$IMG" bs=1 seek=$((0x400 + 0x4)) conv=notrunc 2>/dev/null
v=$("$DUMP" "$IMG" probe 2>/dev/null | head -1)
grep -qiE "UNSUPPORTED|larger than the device" <<<"$v" \
  && ok "a superblock larger than the device is refused" \
  || bad "a superblock larger than the device is refused" "$v"

# --- rename semantics -------------------------------------------------------
echo
echo "rename semantics"
IMG="$WORK/ren.img"; new_vol "$IMG" 4 4096
"$DUMP" "$IMG" mkdir /a >/dev/null 2>&1
"$DUMP" "$IMG" mkdir /a/b >/dev/null 2>&1
"$DUMP" "$IMG" mkdir /a/b/c >/dev/null 2>&1
# moving /a into /a/b/c would detach the subtree into a loop
out=$("$DUMP" "$IMG" mv /a /a/b/c/loop 2>&1); rc=$?
[ $rc -ne 0 ] \
  && ok "moving a directory into its own descendant is refused (EINVAL)" \
  || bad "moving a directory into its own descendant is refused" "$out"
e2fsck -fn "$IMG" >/dev/null 2>&1 \
  && ok "e2fsck clean after the refused loop-rename" \
  || bad "e2fsck clean after the refused loop-rename"

# file over an empty directory -> EISDIR
"$DUMP" "$IMG" mkdir /emptydir >/dev/null 2>&1
"$DUMP" "$IMG" create /file >/dev/null 2>&1
out=$("$DUMP" "$IMG" mv /file /emptydir 2>&1); rc=$?
[ $rc -ne 0 ] \
  && ok "renaming a file over a directory is refused (EISDIR)" \
  || bad "renaming a file over a directory is refused" "$out"

# --- hardlink over an existing name -> EEXIST -------------------------------
echo
echo "hardlink over an existing name"
IMG="$WORK/ln.img"; new_vol "$IMG" 4 4096
"$DUMP" "$IMG" create /target >/dev/null 2>&1
"$DUMP" "$IMG" create /taken >/dev/null 2>&1
out=$("$DUMP" "$IMG" ln /target /taken 2>&1); rc=$?
[ $rc -ne 0 ] && grep -qiE "exists|EEXIST" <<<"$out" \
  && ok "a hard link over an existing name is refused (EEXIST)" \
  || bad "a hard link over an existing name is refused" "$out"
e2fsck -fn "$IMG" >/dev/null 2>&1 \
  && ok "e2fsck clean after the refused hardlink" \
  || bad "e2fsck clean after the refused hardlink"

# --- oversize directory-entry name is rejected, not truncated ---------------
echo
echo "over-long names"
IMG="$WORK/name.img"; new_vol "$IMG" 4 4096
name256=$(printf 'n%.0s' $(seq 1 256))
out=$("$DUMP" "$IMG" create "/$name256" 2>&1); rc=$?
[ $rc -ne 0 ] && grep -qiE "too long|ENAMETOOLONG" <<<"$out" \
  && ok "a 256-byte name is refused, not truncated to 255" \
  || bad "a 256-byte name is refused" "$out"

# --- statfs reserved-block accounting ---------------------------------------
echo
echo "statfs reserved blocks"
# mke2fs reserves 5% by default; ours may reserve 0. Either way, available
# must never exceed free. The bug reported avail == free unconditionally.
IMG="$WORK/statfs.img"; new_vol "$IMG" 4 4096
hdr=$("$DUMP" "$IMG" ls / 2>/dev/null | grep 'blocks free' | head -1)
free=$(sed -E 's|.*# ([0-9]+)/[0-9]+ blocks free.*|\1|' <<<"$hdr")
avail=$(sed -E 's|.*avail=([0-9]+).*|\1|' <<<"$hdr")
if [ -n "$free" ] && [ -n "$avail" ] && [ "$avail" -le "$free" ]; then
  ok "statfs available ($avail) never exceeds free ($free)"
else
  bad "statfs available never exceeds free" "free=$free avail=$avail"
fi

# --- a failed assertion reports through the logger, not stdout --------------
echo
echo "assertion failure reporting"
# Sandboxed, the appex has no stdout anyone can read; a failed lwext4 assert
# used to printf there and vanish. It must go through the logger (stderr in
# the tool, os_log in the appex) instead.
so=$("$DUMP" x __assert_selftest 2>/dev/null)          # stdout only
se=$("$DUMP" x __assert_selftest 2>&1 >/dev/null)      # stderr only
if grep -qi "assertion" <<<"$so"; then
  bad "a tripped assertion does not print to stdout" "stdout: $so"
else
  ok "a tripped assertion does not print to stdout"
fi
if grep -qi "assertion failed at" <<<"$se"; then
  ok "a tripped assertion is reported through the logger (stderr)"
else
  bad "a tripped assertion is reported through the logger" "stderr: $se"
fi

finish
