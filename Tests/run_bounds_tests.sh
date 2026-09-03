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
  dd if=/dev/zero of="$1" bs=1M count=64 2>/dev/null
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

# The clamp that keeps df honest also hides the corrupt value, which is the
# one worth seeing when the question is how far the accounting has drifted.
# `groups` reports the counter as stored and sets its exit code on the
# disagreement, so a damaged volume is detectable in a script.
gout=$("$DUMP" "$IMG" groups bad 2>&1); grc=$?
raw=$(sed -nE 's/^superblock says: +([0-9]+) free.*/\1/p' <<<"$gout")
sumd=$(sed -nE 's/^descriptors sum to: +([0-9]+) free.*/\1/p' <<<"$gout")
if [ "$raw" = "$((tot + 400085))" ]; then
  ok "groups reports the stored count ($raw), not the clamped one"
else
  bad "groups reports the stored count, not the clamped one" \
      "expected $((tot + 400085)), got ${raw:-none}"
fi
if [ -n "$sumd" ] && [ "$sumd" -le "$tot" ]; then
  ok "the descriptors still sum to something possible ($sumd)"
else
  bad "the descriptors still sum to something possible" "sum=${sumd:-none} total=$tot"
fi
# Exactly 1, not merely non-zero: an unrecognised verb also exits non-zero,
# so "not 0" would pass against a build that has no such command.
if [ "$grc" -eq 1 ]; then
  ok "groups exits 1 when the two records disagree"
else
  bad "groups exits 1 when the two records disagree" "rc=$grc"
fi

# --- an impossible group hidden behind a plausible sum ----------------------
echo
echo "per-group impossibility"
# The field stick had three groups claiming more free blocks than they hold
# while the descriptors still summed to less than the volume size. The audit
# tested the sum only, so it reported the damage as confined to the cached
# total -- the verdict that means "allocation is healthy, this is cosmetic".
# It was the opposite: the allocator was scanning groups for blocks that do
# not exist. With the two records made to agree as well, the pre-fix audit
# called the volume healthy at info level and exited 0.
IMG="$WORK/hidden-group.img"
rm -f "$IMG"; python3 -c "open('$IMG','wb').truncate(4*1024*1024*1024)"
"$DUMP" "$IMG" format 4 >/dev/null 2>&1
python3 - "$IMG" <<'EOF'
import sys, struct
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
bs  = 1024 << struct.unpack_from('<I', sb, 24)[0]
bpg = struct.unpack_from('<I', sb, 32)[0]
fdb = struct.unpack_from('<I', sb, 20)[0]
inc = struct.unpack_from('<I', sb, 96)[0]
dsz = struct.unpack_from('<H', sb, 254)[0] if (inc & 0x80) else 32
if dsz == 0: dsz = 32
# Group 1 claims 20000 blocks more than the group physically holds...
off = (fdb + 1) * bs + dsz + 12          # group 1, free_blocks_count_lo
f.seek(off); cur = struct.unpack('<H', f.read(2))[0]
delta = (bpg + 20000) - cur
f.seek(off); f.write(struct.pack('<H', cur + delta))
# ...and the cached total is credited to match, so the sum still adds up and
# stays under the volume size. Only the per-group check can see this.
struct.pack_into('<I', sb, 12, struct.unpack_from('<I', sb, 12)[0] + delta)
struct.pack_into('<I', sb, 0x3FC, crc32c(bytes(sb[:0x3FC])))
f.seek(1024); f.write(sb); f.close()
EOF
out=$("$DUMP" "$IMG" groups 2>&1); rc=$?
if grep -q "the descriptors themselves are impossible" <<<"$out"; then
  ok "an impossible group is named even when the sum is plausible"
else
  bad "an impossible group is named even when the sum is plausible" \
      "$(grep -i accounting <<<"$out" | head -1)"
fi
if grep -q "free-space accounting agrees" <<<"$out"; then
  bad "a volume with an impossible group is not called healthy" \
      "the audit reported agreement"
else
  ok "a volume with an impossible group is not called healthy"
fi
if grep -qE "^1 group\(s\) claim more free blocks than they hold$" <<<"$out"; then
  ok "the count of impossible groups is reported"
else
  bad "the count of impossible groups is reported" "$(tail -2 <<<"$out")"
fi
if [ "$rc" -eq 1 ]; then
  ok "an impossible group sets the exit code (rc=1)"
else
  bad "an impossible group sets the exit code" "rc=$rc"
fi

# --- pre-recovery totals are labelled as such -------------------------------
echo
echo "unreplayed journal in the audit"
# A read-only mount does not replay, so the superblock it reads is whatever
# the last crash left. The field stick reported 2,471,492 free of 1,920,357
# that way; one read-write mount replayed the log and the same volume read
# 1,750,596, agreeing with its descriptors. The audit reported the stale
# number as corruption with nothing to say it was pre-recovery, and an
# investigation went after a value that recovery was about to correct.
IMG="$WORK/unreplayed.img"; new_vol "$IMG" 4 4096
out=$("$DUMP" "$IMG" groups 2>&1)
if grep -q "pre-recovery" <<<"$out"; then
  bad "a clean volume is not labelled pre-recovery" "$(grep -i pre-recovery <<<"$out" | head -1)"
else
  ok "a clean volume is not labelled pre-recovery"
fi
python3 - "$IMG" <<'EOF'
import sys, struct
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
# INCOMPAT_RECOVER: the volume says it has a journal still to replay.
struct.pack_into('<I', sb, 96, struct.unpack_from('<I', sb, 96)[0] | 0x0004)
struct.pack_into('<I', sb, 0x3FC, crc32c(bytes(sb[:0x3FC])))
f.seek(1024); f.write(sb); f.close()
EOF
out=$("$DUMP" "$IMG" groups 2>&1)
# Level 3, not 2. The level is the whole difference between a line in a log
# nobody streams and a line the extension can put in front of the person
# holding the stick: the Swift logger routes >= 3 to os_log's error channel,
# and Part B's per-mount ring buffer captures level-3 lines into the event it
# writes for the app to read. "The files look old" is exactly the complaint
# this line answers, so it has to travel.
if grep -q "\[core:3\] read-only mount of an unreplayed journal" <<<"$out"; then
  ok "a read-only mount of a dirty volume says the contents predate the crash"
else
  bad "a read-only mount of a dirty volume says so, at level 3" \
      "$(grep -i unreplayed <<<"$out" | head -1)"
fi
if grep -q "pre-recovery" <<<"$out"; then
  ok "the audit labels its totals pre-recovery when the journal is unreplayed"
else
  bad "the audit labels its totals pre-recovery" \
      "$(grep -iE 'accounting|agrees' <<<"$out" | head -1)"
fi

# Reading an unrecovered volume must still work, and this is load-bearing.
# Structures caught mid-update legitimately fail their checksums there -- that
# is what the field log showed. The allocator refuses a write through a bitmap
# whose checksum failed, and that is only safe because a write cannot reach a
# volume in this state: WRITE_PROLOGUE returns EROFS on a read-only mount, and
# a read-write mount replays before anything else. If reads ever start failing
# here, every crash snapshot becomes unmountable and that refusal has to be
# reconsidered.
prerec_failed=""
for verb in "ls /" probe df groups check orphans; do
  if ! "$DUMP" "$IMG" $verb >/dev/null 2>&1; then
    prerec_failed="$prerec_failed ${verb%% *}"
  fi
done
if [ -z "${prerec_failed:-}" ]; then
  ok "an unrecovered volume can still be read"
else
  bad "an unrecovered volume can still be read" "failed:$prerec_failed"
fi

# --- freeing a range that overhangs the volume ------------------------------
echo
echo "out-of-range free"
# ext4_balloc_free_blocks divided its arguments into a first and last group id
# and walked between them without establishing that the last one exists. A
# range past the end of the medium was walked as if those groups were there,
# crediting a bitmap block's worth of free space per iteration through the
# descriptor table's address arithmetic. That is how a field volume ended up
# with groups claiming more free blocks than they hold.
# Sized so the last group is PARTIAL (33 groups, the last holding 5000 of
# 32768 blocks). A volume whose size divides evenly by the group size has no
# overhang for the walk to get wrong, and this cell passes against the unfixed
# core on such a fixture -- the same blind spot that let a single-block-group
# suite miss the lazy-group bug.
IMG="$WORK/oob-free.img"
rm -f "$IMG"; python3 -c "open('$IMG','wb').truncate((32*32768+5000)*4096)"
"$DUMP" "$IMG" format 4 >/dev/null 2>&1
"$DUMP" "$IMG" create /victim 0644 >/dev/null 2>&1
dd if=/dev/zero of="$WORK/payload" bs=1M count=4 2>/dev/null
"$DUMP" "$IMG" put /victim "$WORK/payload" >/dev/null 2>&1
python3 - "$IMG" <<'EOF'
import sys, struct
f = open(sys.argv[1], 'r+b')
f.seek(1024); sb = f.read(1024)
bs  = 1024 << struct.unpack_from('<I', sb, 24)[0]
isz = struct.unpack_from('<H', sb, 88)[0]
fdb = struct.unpack_from('<I', sb, 20)[0]
tot = struct.unpack_from('<I', sb, 4)[0]
inc = struct.unpack_from('<I', sb, 96)[0]
dsz = struct.unpack_from('<H', sb, 254)[0] if (inc & 0x80) else 32
if dsz == 0: dsz = 32
f.seek((fdb + 1) * bs)
itbl = struct.unpack_from('<I', f.read(dsz), 8)[0]
off = itbl * bs + (12 - 1) * isz          # inode 12, the file just created
f.seek(off + 40); ib = bytearray(f.read(60))
assert struct.unpack_from('<H', ib, 0)[0] == 0xF30A, "not an extent inode"
eb, el, shi, slo = struct.unpack_from('<IHHI', ib, 12)
# Start just inside the volume, run 30000 blocks past its end.
struct.pack_into('<IHHI', ib, 12, eb, 30000, 0, tot - 100)
f.seek(off + 40); f.write(bytes(ib)); f.close()
EOF
rmout=$("$DUMP" "$IMG" rm /victim 2>&1)
# lwext4's own debug output is compiled out of this build, so a refusal has to
# come through the shim's logger or nobody in the field can see it -- and the
# range is the only clue to whatever produced it.
if grep -q "past the end of a .* volume" <<<"$rmout"; then
  ok "the refused range is reported, not silently dropped"
else
  bad "the refused range is reported" "$(tail -2 <<<"$rmout" | tr '\n' ' ')"
fi
out=$("$DUMP" "$IMG" groups 2>&1); rc=$?
if grep -q "claim more free blocks than they hold" <<<"$out"; then
  bad "freeing past the end of the volume leaves no impossible group" \
      "$(grep 'claim more' <<<"$out" | head -1)"
else
  ok "freeing past the end of the volume leaves no impossible group"
fi
if [ "$rc" -eq 0 ]; then
  ok "the accounting still adds up after an out-of-range free"
else
  bad "the accounting still adds up after an out-of-range free" \
      "$(tail -3 <<<"$out" | tr '\n' ' ')"
fi

# --- the core stays quiet on a healthy volume -------------------------------
# lwext4's DBG_WARN lines were compiled out of this build, so twenty-two
# "extent block checksum failed" reports per suite run went unheard -- all of
# them spurious, from checksumming the in-inode extent root as though it were a
# block. Now that the level reaches the logger, the channel is only worth
# having if it is silent when nothing is wrong: one false positive per file
# teaches everyone to ignore the next real one.
echo
echo "core diagnostics on a healthy volume"
IMG="$WORK/quiet.img"; new_vol "$IMG" 4 4096
qout=$( { "$DUMP" "$IMG" mkdir /q
          "$DUMP" "$IMG" create /q/f 0644
          "$DUMP" "$IMG" write /q/f "some bytes"
          "$DUMP" "$IMG" setxattr /q/f user.k v
          "$DUMP" "$IMG" ls /
          "$DUMP" "$IMG" stat /q/f
          "$DUMP" "$IMG" extents /q/f; } 2>&1 )
qn=$(grep -cE "\[(warn|error)\]" <<<"$qout")
if [ "$qn" = 0 ]; then
  ok "an ordinary workload provokes no core warnings"
else
  bad "an ordinary workload provokes no core warnings" \
      "$(grep -oE '\[(warn|error)\].*' <<<"$qout" | sort -u | head -2 | tr '\n' ' ')"
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
groups
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

# Which groups are lazy, counted by us and by e2fsprogs independently. The
# mount-time audit reports one sum for the whole volume, which says that the
# accounting is wrong but not where; this is the breakdown that says where,
# and it is only trustworthy if it agrees with a tool that does not share our
# descriptor-addressing code.
gout=$("$DUMP" "$IMG" groups 2>/dev/null)
g_uninit=$(sed -nE 's/^[0-9]+ group\(s\), ([0-9]+) still BLOCK_UNINIT$/\1/p' <<<"$gout")
if [ -n "$g_uninit" ] && [ "$g_uninit" = "$after_uninit" ]; then
  ok "groups counts the same $g_uninit lazy groups dumpe2fs does"
else
  bad "groups counts the same lazy groups dumpe2fs does" \
      "groups=${g_uninit:-none} dumpe2fs=$after_uninit"
fi
if grep -q "^the two agree$" <<<"$gout"; then
  ok "the per-group counts add up to the cached total on a healthy volume"
else
  bad "the per-group counts add up to the cached total" \
      "$(grep -E 'disagree|superblock says' <<<"$gout" | head -2 | tr '\n' ' ')"
fi
if grep -qE '^ +[0-9]+ +[0-9]+ +[0-9]+ +[0-9]+ ' <<<"$gout"; then
  ok "the breakdown names groups individually, not just a total"
else
  bad "the breakdown names groups individually" "$(head -3 <<<"$gout")"
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
  # The watchdog's output goes to /dev/null, and that is not tidiness.
  #
  # A caller that captures this function -- out=$(run_deadline 20 ...) -- is
  # waiting for every process holding the write end of the substitution pipe,
  # and the backgrounded subshell holds it too. Killing the subshell does not
  # reap the `sleep` it forked, so the orphaned sleep keeps the pipe open and
  # the capture blocks for the FULL deadline on every call, however fast the
  # command was. Redirecting here detaches the watchdog from that pipe.
  ( sleep "$secs"; kill -9 $pid 2>/dev/null ) >/dev/null 2>&1 & local dog=$!
  wait $pid 2>/dev/null; local rc=$?
  kill $dog 2>/dev/null; wait $dog 2>/dev/null
  return $rc
}

# Is there a sanitizer watching?
#
# Captured, not piped into grep -q: under `set -o pipefail` grep -q exits at
# the first hit, nm takes SIGPIPE, and the pipeline reports failure -- so a
# present symbol reads as absent, intermittently, which is the worst way for
# a check to be wrong.
have_ubsan() {
  local syms; syms="$(nm "$DUMP" 2>/dev/null)"
  case "$syms" in *__ubsan*) return 0 ;; *) return 1 ;; esac
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
rm -f "$EXTIMG"; dd if=/dev/zero of="$EXTIMG" bs=1M count=64 2>/dev/null
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

# --- undefined behaviour on ordinary media ----------------------------------
# Not a corrupt image: a perfectly ordinary one.
#
# ext4_xattr_list() sizes its output buffer in two loops -- one for the
# attributes stored in the inode body, one for those in a separate block --
# and both used the (char *)((T *)0 + 1) - (char *)(T *)0 idiom to spell
# sizeof. Patch 0003 fixed the first. The second went on undefined for as
# long as it did because reaching it needs attributes that do NOT fit in the
# inode, which means 128-byte inodes, and every fixture in this project used
# 256-byte ones. A fuzzing seed built with -I 128 found it on the first run,
# unmutated.
#
# This cell is only an assertion under `make test-asan`, where the tool is
# built with UBSan; in a release build there is nothing to detect and it says
# so rather than passing quietly.
echo ""
echo "undefined behaviour on ordinary media"

if ! command -v mke2fs >/dev/null; then
  echo "  (mke2fs not found; skipping the 128-byte-inode xattr cell)"
else
  UBIMG="$WORK/ub_xattr_block.img"
  rm -f "$UBIMG"; dd if=/dev/zero of="$UBIMG" bs=1M count=3 2>/dev/null
  # -I 128: no extra inode space at all, so every attribute goes to a block.
  mke2fs -q -F -b 1024 -N 128 -I 128 -O ^metadata_csum,^64bit,extent,dir_index \
      "$UBIMG" 2>/dev/null
  head -c 700 /dev/urandom | base64 | head -c 700 > "$WORK/ub_value"
  printf 'hello\n' > "$WORK/ub_file"
  debugfs -w -f /dev/stdin "$UBIMG" >/dev/null 2>&1 <<EOF
write $WORK/ub_file victim
quit
EOF
  debugfs -w -f /dev/stdin "$UBIMG" >/dev/null 2>&1 <<EOF
ea_set -f $WORK/ub_value /victim user.big
quit
EOF

  if ! debugfs -R "ea_list /victim" "$UBIMG" 2>/dev/null | grep -q "user.big"; then
    bad "a 128-byte-inode volume carries an xattr block" \
        "debugfs would not set the attribute; the cell tested nothing"
  else
    ubout=$(run_deadline 20 "$DUMP" "$UBIMG" xattr /victim 2>&1); ubrc=$?
    # Is there a sanitizer watching at all? Without one this proves nothing,
    # and saying "ok" would be a lie told once per release build.
    if have_ubsan; then
      if grep -q "runtime error:" <<<"$ubout"; then
        bad "listing an xattr block is free of undefined behaviour" \
            "$(grep -m1 'runtime error:' <<<"$ubout")"
      elif [ $ubrc -ge 128 ]; then
        bad "listing an xattr block is free of undefined behaviour" "rc=$ubrc"
      else
        ok "listing an xattr block is free of undefined behaviour (UBSan watching)"
      fi
    else
      echo "  note  the xattr-block UB cell needs 'make test-asan' to mean anything"
      echo "        (this build has no UBSan; the listing itself succeeded: rc=$ubrc)"
    fi
  fi

  # A read-write mount, which is a different question from a read-only one:
  # ext4_mount() writes the superblock to clear VALID_FS before the block
  # layer has been told its logical block size, and patch 0023's
  # cache-coherency update then took a modulo by that zero. Every read-write
  # mount, since 0023 landed, on every volume. Nothing noticed because UBSan
  # only prints when it is not made fatal, and no suite read the printing.
  RWIMG="$WORK/ub_rw_mount.img"
  rm -f "$RWIMG"; dd if=/dev/zero of="$RWIMG" bs=1M count=4 2>/dev/null
  mke2fs -q -F -b 1024 -N 128 -I 256 -O metadata_csum,64bit,extent,dir_index \
      -J size=1 "$RWIMG" 2>/dev/null
  rwout=$(run_deadline 20 "$DUMP" "$RWIMG" mkdir /ubdir 2>&1); rwrc=$?
  if have_ubsan; then
    if grep -q "runtime error:" <<<"$rwout"; then
      bad "a read-write mount is free of undefined behaviour" \
          "$(grep -m1 'runtime error:' <<<"$rwout")"
    elif [ $rwrc -ge 128 ]; then
      bad "a read-write mount is free of undefined behaviour" "rc=$rwrc"
    else
      ok "a read-write mount is free of undefined behaviour (UBSan watching)"
    fi
  else
    echo "  note  the read-write UB cell needs 'make test-asan' to mean anything"
    echo "        (this build has no UBSan; the mkdir itself returned rc=$rwrc)"
  fi

  # --- a feature this driver reads wrongly must be refused, not mounted ----
  # meta_bg scatters the group descriptors through the volume instead of
  # putting them after the superblock, and lwext4's placement arithmetic does
  # not agree with e2fsprogs about where they land past the first meta block
  # group. It was on the supported list until it was measured: on a volume
  # e2fsck calls clean the driver failed a descriptor checksum, could not read
  # an inode debugfs reads fine, and reported 137 GB of data from 5 MiB.
  # Writing was worse -- 150 creates left 59 inodes in groups still flagged
  # INODE_UNINIT.
  #
  # This cell is the whole claim: refused at the probe, and the volume
  # untouched by an attempted write. It needs no sanitizer to mean something.
  MBIMG="$WORK/meta_bg.img"
  rm -f "$MBIMG"; dd if=/dev/zero of="$MBIMG" bs=1M count=5 2>/dev/null
  if mke2fs -q -F -t ext4 -b 1024 -g 1024 -N 512 -I 256 \
       -O metadata_csum,64bit,extent,dir_index,meta_bg,^resize_inode \
       -J size=1 "$MBIMG" 2>/dev/null; then
    mb_verdict=$("$DUMP" "$MBIMG" probe 2>/dev/null | awk '/^verdict:/{print $2}')
    if [ "$mb_verdict" = "UNSUPPORTED" ]; then
      ok "a meta_bg volume is refused, not mounted"
    else
      bad "a meta_bg volume is refused, not mounted" \
          "verdict $mb_verdict: this driver reads meta_bg descriptors incorrectly"
    fi

    mb_before=$(md5 -q "$MBIMG" 2>/dev/null || md5sum "$MBIMG" | cut -d' ' -f1)
    {
      echo "mkdir /d"
      mb_i=1
      while [ $mb_i -le 150 ]; do echo "create /d/n$mb_i"; mb_i=$((mb_i+1)); done
    } | run_deadline 40 "$DUMP" "$MBIMG" script - >/dev/null 2>&1
    mb_after=$(md5 -q "$MBIMG" 2>/dev/null || md5sum "$MBIMG" | cut -d' ' -f1)
    if [ "$mb_before" = "$mb_after" ] && e2fsck -fn "$MBIMG" >/dev/null 2>&1; then
      ok "and a write to one leaves it untouched and e2fsck-clean"
    else
      bad "a write to a meta_bg volume leaves it untouched" \
          "$(e2fsck -fn "$MBIMG" 2>&1 | grep -m1 INODE_UNINIT || echo "the image changed")"
    fi
  else
    echo "  (this mke2fs cannot create meta_bg; skipping the refusal cell)"
  fi
fi

finish
