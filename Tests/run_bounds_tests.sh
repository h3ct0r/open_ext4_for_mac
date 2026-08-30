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

# --- hostile journal geometry -----------------------------------------------
# Fields the journal superblock and revoke blocks state about themselves,
# believed before anything bounded them. blocksize larger than the real block
# turned every checksum pass and replay memcpy into an out-of-bounds access
# (the checksum helper WRITES past the buffer, zeroing the tail in place);
# a revoke count below its own header size underflowed to ~2^30 fabricated
# entries -- reads past the block, a heap allocation each, then an abort.
# Both are one corrupt field on a stick, hit during mount.
#
# The fixtures use mke2fs without metadata_csum so the journal superblock
# carries no self-checksum -- the checksummed format rejects blunt corruption
# by luck; the fields must be bounded regardless (a crafted image checksums
# itself consistently). A wedged driver is the failure mode here, so every
# run gets a deadline: a kill is a FAIL, not a hang.
echo ""
echo "hostile journal geometry"

run_deadline() {  # run_deadline <seconds> <cmd...>; rc 137 if killed
  local secs=$1; shift
  "$@" & local pid=$!
  ( sleep "$secs"; kill -9 $pid 2>/dev/null ) & local dog=$!
  wait $pid 2>/dev/null; local rc=$?
  kill $dog 2>/dev/null; wait $dog 2>/dev/null
  return $rc
}

if ! command -v mke2fs >/dev/null; then
  echo "  (mke2fs not found; skipping journal-geometry cells)"
else
  JG="$WORK/jgeo.img"
  make_jgeo() {  # fresh no-csum journalled volume; prints the jsb byte offset
    rm -f "$JG"
    mke2fs -q -F -b 4096 -O ^metadata_csum,^64bit -J size=4 "$JG" 16384 \
      2>/dev/null
    local blk
    blk=$(debugfs -R "blocks <8>" "$JG" 2>/dev/null \
          | tr ' ' '\n' | grep -v '^$' | head -1)
    echo $(( blk * 4096 ))
  }

  # jbd superblock layout: 12-byte header, then s_blocksize at +12,
  # s_maxlen at +16, s_first at +20 -- all big-endian.
  poke_be32() {  # poke_be32 <img> <offset> <value>
    python3 - "$1" "$2" "$3" <<'PY'
import struct, sys
path, off, val = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
with open(path, 'r+b') as f:
    f.seek(off)
    f.write(struct.pack('>I', val))
PY
  }

  jsb=$(make_jgeo)
  poke_be32 "$JG" $((jsb + 12)) 65536        # blocksize 16x the real one
  run_deadline 15 "$DUMP" "$JG" create /x >/dev/null 2>&1; rc=$?
  if [ $rc -ge 1 ] && [ $rc -lt 128 ]; then
    ok "an oversized journal blocksize is refused, not believed (rc=$rc)"
  else
    bad "an oversized journal blocksize is refused" \
        "rc=$rc (0 = accepted, >=128 = crashed or wedged)"
  fi

  jsb=$(make_jgeo)
  poke_be32 "$JG" $((jsb + 16)) 0            # maxlen 0: wrap() divides by faith
  run_deadline 15 "$DUMP" "$JG" create /x >/dev/null 2>&1; rc=$?
  if [ $rc -ge 1 ] && [ $rc -lt 128 ]; then
    ok "a zero-length journal is refused, not believed (rc=$rc)"
  else
    bad "a zero-length journal is refused" "rc=$rc"
  fi

  # A revoke block whose count underflows. The fixture earns real revoke
  # blocks (directories created and removed in one session), the power-cut
  # knob leaves them unreplayed, then the count is set below its own header.
  jsb=$(make_jgeo)
  {
    for i in 1 2 3 4 5 6 7 8; do
      echo "mkdir /t$i"; echo "create /t$i/x"; echo "rm /t$i/x"; echo "rm /t$i"
      echo "create /f$i"
    done
  } > "$WORK/jgeo-load.txt"
  EXT4DUMP_FAIL_AFTER=60 "$DUMP" "$JG" script "$WORK/jgeo-load.txt" \
    >/dev/null 2>&1
  poked=$(python3 - "$JG" "$jsb" <<'PY'
import struct, sys
path, jsb = sys.argv[1], int(sys.argv[2])
JBD_MAGIC = 0xC03B3998
n = 0
with open(path, 'r+b') as f:
    # walk the 4 MiB journal region one block at a time
    for i in range(1, 1024):
        f.seek(jsb + i * 4096)
        hdr = f.read(12)
        if len(hdr) < 12:
            break
        magic, btype, _ = struct.unpack('>III', hdr)
        if magic == JBD_MAGIC and btype == 5:        # revoke block
            f.seek(jsb + i * 4096 + 12)
            f.write(struct.pack('>I', 12))           # < header size: underflow
            n += 1
print(n)
PY
)
  if [ "${poked:-0}" -eq 0 ]; then
    bad "revoke-count fixture holds no revoke blocks" \
        "the cut left none in the log; nothing was tested"
  else
    run_deadline 20 "$DUMP" "$JG" label AFTER >/dev/null 2>&1; rc=$?
    if [ $rc -lt 128 ]; then
      ok "an underflowing revoke count is bounded, not walked ($poked block(s), rc=$rc)"
    else
      bad "an underflowing revoke count is bounded" \
          "rc=$rc: recovery walked ~2^30 fabricated entries"
    fi
  fi
fi

# --- a corrupt extent header ------------------------------------------------
# The extent tree's own headers state how many entries they hold and how many
# they could hold, and both were believed. eh_max is used as the stride to the
# checksum tail (12 + 12 * eh_max, which for 0xFFFF is 786 KB past a 4 KB
# block) and eh_entries bounds the binary search, so a corrupt inode turned
# reading one file into a heap overflow -- read on every path, and write on the
# checksum-setting one. The root header made it worse: it lives inside the
# inode, never passed through the block reader, and so was the one header
# nothing validated, reachable without a single valid checksum anywhere.
#
# Confirmed with AddressSanitizer before the fix: `cat` on the file below was
# a heap-buffer-overflow in ext4_ext_binsearch, reached from a plain read.
# Run this suite under `make test-asan` for that to be the assertion; without
# the sanitizer it still catches a crash or a hang.
echo ""
echo "a corrupt extent header"

EXTIMG="$WORK/extent_hdr.img"
rm -f "$EXTIMG"; dd if=/dev/zero of="$EXTIMG" bs=1m count=64 2>/dev/null
"$DUMP" "$EXTIMG" format 4 >/dev/null 2>&1
"$DUMP" "$EXTIMG" create /victim >/dev/null 2>&1
"$DUMP" "$EXTIMG" write /victim hello-world >/dev/null 2>&1

imap=$(debugfs -R 'imap <12>' "$EXTIMG" 2>/dev/null)
blk=$(sed -n 's/.*located at block \([0-9]*\).*/\1/p' <<<"$imap")
off=$(sed -n 's/.*offset \(0x[0-9a-f]*\).*/\1/p' <<<"$imap")
if [ -z "$blk" ] || [ -z "$off" ]; then
  bad "could not locate the inode to corrupt" "debugfs said: $imap"
else
  python3 - "$EXTIMG" "$blk" "$off" <<'PYEOF'
import struct, sys
img, blk, off = sys.argv[1], int(sys.argv[2]), int(sys.argv[3], 16)
d = bytearray(open(img, 'rb').read())
hdr = blk * 4096 + off + 40          # i_block[] holds the root extent header
magic, entries, mx, depth = struct.unpack_from('<HHHH', d, hdr)
# Claim far more entries, and far more room, than 60 bytes can hold.
struct.pack_into('<HHHH', d, hdr, magic, 0x4000, 0xFFFF, depth)
open(img, 'wb').write(d)
PYEOF
  for verb in "cat /victim" "extents /victim" "write /victim x"; do
    out=$(run_deadline 20 "$DUMP" "$EXTIMG" $verb 2>&1); rc=$?
    if [ $rc -ge 128 ]; then
      bad "a corrupt extent header is refused ($verb)" "rc=$rc: crashed or hung"
    elif grep -qi 'AddressSanitizer' <<<"$out"; then
      bad "a corrupt extent header is refused ($verb)" "sanitizer reported an overflow"
    else
      ok "a corrupt extent header is refused, not walked ($verb)"
    fi
  done
fi

finish
