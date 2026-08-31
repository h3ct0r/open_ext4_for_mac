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

# --- a volume claiming more free space than it has --------------------------
echo
echo "statfs impossible free count"
# A stick in the field reported 2,045,724 free blocks against 1,920,357 total,
# which df renders as a negative block count and Disk Utility as 106.5% free.
# The count is clamped so the OS is never handed an impossible number -- and
# `available` has to follow the clamped value, not the raw one. It did not:
# clamping only `free` left df still printing "Avail 8.9Gi" for a 7.3Gi
# volume, which made the clamp look ineffective for a week.
IMG="$WORK/statfs-impossible.img"; new_vol "$IMG" 4 4096
python3 - "$IMG" <<'EOF'
import struct, sys
# The superblock carries a crc32c of itself, so a field cannot be edited in
# place without re-stamping it -- an unstamped edit is rejected at mount as an
# unsupported feature, which never reaches the accounting code under test.
T = []
for i in range(256):
    c = i
    for _ in range(8):
        c = (c >> 1) ^ (0x82F63B78 if c & 1 else 0)
    T.append(c)
def crc32c(buf, crc=0xFFFFFFFF):
    for b in buf:
        crc = (crc >> 8) ^ T[(crc ^ b) & 0xFF]
    return crc
f = open(sys.argv[1], 'r+b')
f.seek(1024); sb = bytearray(f.read(1024))
total = struct.unpack_from('<I', sb, 4)[0]
struct.pack_into('<I', sb, 12,    total + 400085)    # free blocks > total
struct.pack_into('<I', sb, 0x158, 0)                 # and its high half
struct.pack_into('<I', sb, 0x3FC, crc32c(bytes(sb[:0x3FC])))
f.seek(1024); f.write(sb); f.close()
EOF
out=$("$DUMP" "$IMG" df 2>&1); rc=$?
tot=$(sed -nE 's/^total: *([0-9]+) blocks.*/\1/p' <<<"$out")
fre=$(sed -nE 's/^free: *([0-9]+) blocks.*/\1/p' <<<"$out")
avl=$(sed -nE 's/^available: *([0-9]+) blocks.*/\1/p' <<<"$out")
if [ -n "$avl" ] && [ -n "$tot" ] && [ "$avl" -le "$tot" ] && [ "$avl" -le "$fre" ]; then
  ok "available ($avl) follows the clamp, not the raw count (total $tot)"
else
  bad "available follows the clamped free count" "total=$tot free=$fre avail=$avl rc=$rc"
fi
if [ -n "$fre" ] && [ "$fre" -le "$tot" ]; then
  ok "free ($fre) is clamped to the volume size"
else
  bad "free is clamped to the volume size" "total=$tot free=$fre"
fi
if grep -q "only the cached total is impossible" <<<"$out"; then
  ok "the audit names which record is wrong (the cached total)"
else
  bad "the audit names which record is wrong" "$(grep -i accounting <<<"$out" | head -1)"
fi

# --- a damaged superblock is not reported as an unsupported one -------------
echo
echo "damaged superblock wording"
# lwext4 folds its superblock-checksum test into the same boolean that reports
# feature problems, so a damaged superblock came back as "unsupported
# filesystem feature" -- which sends the user hunting for a missing driver
# feature instead of running e2fsck.
IMG="$WORK/statfs-damaged.img"; new_vol "$IMG" 4 4096
python3 - "$IMG" <<'EOF'
import struct, sys
f = open(sys.argv[1], 'r+b')
f.seek(1024 + 12); f.write(struct.pack('<I', 999999))   # edited, not re-stamped
f.close()
EOF
out=$("$DUMP" "$IMG" df 2>&1 || true)
if grep -q "superblock is damaged" <<<"$out"; then
  ok "a bad superblock checksum is reported as damage, not as a missing feature"
else
  bad "a bad superblock checksum is reported as damage" "$(head -2 <<<"$out")"
fi

# --- inspection commands neither fail nor write ------------------------------
echo
echo "read-only commands stay read-only"
# Every suite reads these verbs' stdout and asserts on its content; almost none
# looks at the exit code (68 call sites capture output, 6 check status). So a
# change that made the mount dirty -- correct output, then a failed write-back
# at unmount -- passed 114 cells while every read-only command exited 1. The
# cause was auditing group descriptors through ext4_fs_get_block_group_ref,
# which initializes and dirties any group still flagged BLOCK_UNINIT rather
# than merely reading it.
#
# The exit code is only half the guard. On a read-write mount that same change
# writes silently instead of failing, so the image itself must come back
# byte-identical.
# Sized for many groups on purpose. A small fixture has one block group, and
# group 0 is always written out at format, so nothing is left flagged
# BLOCK_UNINIT -- the very state that made the regression fire. Every fixture
# in the suite was single-group, which is why 114 cells stayed green against a
# build where this failed. Sparse, so it costs bytes, not gigabytes.
IMG="$WORK/readonly.img"
rm -f "$IMG"; python3 -c "open('$IMG','wb').truncate(4*1024*1024*1024)" 2>/dev/null \
  || python3 -c "import sys;open(sys.argv[1],'wb').truncate(4*1024*1024*1024)" "$IMG"
"$DUMP" "$IMG" format 4 >/dev/null 2>&1
uninit() { dumpe2fs "$1" 2>/dev/null | grep -c 'BLOCK_UNINIT'; }
fresh_uninit=$(uninit "$IMG")
if [ "${fresh_uninit:-0}" -gt 1 ]; then
  ok "the fixture keeps $fresh_uninit groups uninitialized after format"
else
  bad "the fixture keeps groups uninitialized after format" \
      "uninit groups=${fresh_uninit:-none} (is something materializing them?)"
fi
"$DUMP" "$IMG" mkdir /d              >/dev/null 2>&1
"$DUMP" "$IMG" create /d/f 0644      >/dev/null 2>&1
"$DUMP" "$IMG" write /d/f "content"  >/dev/null 2>&1
"$DUMP" "$IMG" setxattr /d/f user.k v >/dev/null 2>&1
# Writing one small file touches group 0, which format already initialized, so
# a healthy build consumes no lazy groups here. The regression consumes all of
# them on any read-write mount -- measured separately from inspection so each
# failure names the thing that actually caused it.
written_uninit=$(uninit "$IMG")
if [ "$fresh_uninit" = "$written_uninit" ]; then
  ok "writing one small file consumes no lazy groups ($written_uninit intact)"
else
  bad "writing one small file consumes no lazy groups" \
      "uninit groups $fresh_uninit -> $written_uninit"
fi

before=$(md5 -q "$IMG" 2>/dev/null || md5sum "$IMG" | cut -d' ' -f1)

ro_failed=""
while read -r verb args; do
  [ -z "$verb" ] && continue
  if ! "$DUMP" "$IMG" $verb $args >/dev/null 2>&1; then
    ro_failed="$ro_failed $verb"
  fi
done <<'VERBS'
probe
ls /
stat /d/f
cat /d/f
extents /d/f
xattr /d/f
orphans
check
df
VERBS

if [ -z "$ro_failed" ]; then
  ok "every read-only command exits 0 on a healthy volume"
else
  bad "every read-only command exits 0 on a healthy volume" "failed:$ro_failed"
fi

after=$(md5 -q "$IMG" 2>/dev/null || md5sum "$IMG" | cut -d' ' -f1)
if [ "$before" = "$after" ]; then
  ok "inspecting a volume leaves it byte-identical"
else
  bad "inspecting a volume leaves it byte-identical" "$before -> $after"
fi

after_uninit=$(uninit "$IMG")
if [ "$written_uninit" = "$after_uninit" ]; then
  ok "inspection consumes no lazily-initialized groups ($after_uninit intact)"
else
  bad "inspection consumes no lazily-initialized groups" \
      "uninit groups $written_uninit -> $after_uninit"
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
