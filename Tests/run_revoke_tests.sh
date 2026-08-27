#!/usr/bin/env bash
# Are the revoke blocks this driver writes readable by the code that reads them?
#
# A revoke block says "do not replay these blocks; they were freed". Recovery
# -- ours, e2fsck's, and the Linux kernel's -- computes the number of entries
# from the header's `count` field:
#
#     nr_entries = (count - sizeof(header)) / 4
#
# so an overstated count makes every reader parse one entry past the last real
# one, into bytes the writer never set. The result is a fabricated revoke: an
# arbitrary block number that recovery will silently refuse to replay. That is
# not a crash; it is a block quietly left stale on a volume that reports a
# successful recovery.
#
# lwext4's emission had exactly this: with journal checksums on, it reserved
# space for the 4-byte checksum tail inside `count`. This suite reads every
# revoke block the driver wrote and checks that every entry -- the last one is
# the one that matters -- names a real block.
#
# Runs unattended, no docker needed. Exits nonzero on any invalid entry.
set -uo pipefail
export PATH="/opt/homebrew/opt/e2fsprogs/sbin:/opt/homebrew/opt/e2fsprogs/bin:$PATH"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DUMP="$ROOT/build/bin/ext4dump"
WORK="$ROOT/build/revoke"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok    $*"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $*"; }

[ -x "$DUMP" ] || { echo "build first: make tools"; exit 1; }
rm -rf "$WORK"; mkdir -p "$WORK"

echo "########## REVOKE BLOCKS MUST PARSE ##########"
echo ""

# A workload whose whole point is deletion -- of *directories*. Two things
# hide revokes from a naive workload: data blocks are never journaled, so
# freeing them emits nothing; and lwext4 only emits a revoke for a block it
# journaled in the same session (a real gap, covered elsewhere). A directory
# created and rmdir'd in one run threads that needle: its block is journaled
# at creation and freed at removal, so a revoke must be emitted.
WL="$WORK/workload.txt"
{
  echo "mkdir /d"
  for i in $(seq 1 60); do
    echo "mkdir /d/s$i"
    echo "create /d/s$i/x"
  done
  for i in $(seq 1 60); do
    echo "rm /d/s$i/x"
    echo "rm /d/s$i"
  done
} > "$WL"

# scan <image> <flavor-label>
# The log is not erased at unmount -- only the superblock's start is reset --
# so every revoke block the run wrote is still physically in the journal.
scan() {
  local img="$1" label="$2"
  python3 - "$img" <<'PY'
import struct, sys

img = sys.argv[1]
data = open(img, "rb").read()

# Superblock: block size and count, for entry validation.
sb = data[1024:1024 + 1024]
blocks_count  = struct.unpack_from("<I", sb, 0x4)[0]
log_bs        = struct.unpack_from("<I", sb, 0x18)[0]
bs = 1024 << log_bs

JBD_MAGIC = 0xC03B3998
REVOKE    = 5
HDR       = 16          # jbd_bhdr (12) + count (4)

found = 0
invalid = 0
for blk in range(len(data) // bs):
    off = blk * bs
    magic, btype, seq = struct.unpack_from(">III", data, off)
    if magic != JBD_MAGIC or btype != REVOKE:
        continue
    count = struct.unpack_from(">I", data, off + 12)[0]
    if count < HDR or count > bs:
        invalid += 1
        print(f"    revoke block at fs block {blk}: count {count} out of range")
        continue
    found += 1
    nr = (count - HDR) // 4
    for i in range(nr):
        entry = struct.unpack_from(">I", data, off + HDR + i * 4)[0]
        if entry == 0 or entry >= blocks_count:
            invalid += 1
            print(f"    revoke block at fs block {blk}: entry {i + 1} of {nr} "
                  f"is {entry}, volume has {blocks_count} blocks")
            break

print(f"    {found} revoke block(s) scanned")
sys.exit(0 if (found > 0 and invalid == 0) else (2 if found == 0 else 1))
PY
  local rc=$?
  if [ "$rc" -eq 0 ]; then
    ok "$label: every revoke entry names a real block"
  elif [ "$rc" -eq 2 ]; then
    bad "$label: the workload emitted no revoke blocks -- the test tested nothing"
  else
    bad "$label: a revoke entry points at garbage -- recovery would fabricate a revoke"
  fi
}

# --- our own format: checksummed journal, where the tail reservation lives ---
IMG="$WORK/ours.img"
dd if=/dev/zero of="$IMG" bs=1m count=64 2>/dev/null
"$DUMP" "$IMG" format 4 4096 REVOKE >/dev/null 2>&1
"$DUMP" "$IMG" script "$WL" >/dev/null 2>&1
feat=$(dumpe2fs -h "$IMG" 2>/dev/null | sed -n 's/^Journal features: *//p')
case "$feat" in *checksum*) : ;; *) bad "our format lost journal checksums ($feat) -- this test needs them";; esac
scan "$IMG" "our format (checksummed journal)"

# --- mke2fs without journal checksums: count has no tail folded in, so this
#     doubles as the control that the scanner itself is sound ---
IMG2="$WORK/plain.img"
dd if=/dev/zero of="$IMG2" bs=1m count=64 2>/dev/null
mke2fs -q -t ext4 -b 4096 -L REVOKE2 "$IMG2"
"$DUMP" "$IMG2" script "$WL" >/dev/null 2>&1
scan "$IMG2" "mke2fs format (no journal checksums)"

# --- freed data blocks must be revoked too ---------------------------------
# Data blocks are never journaled, so the naive rule "revoke what you
# journaled" emits nothing for them -- but a *metadata* block from an earlier,
# already-checkpointed transaction freed and reused as data is exactly what a
# replay from a lagging tail will clobber. The rule has to be "revoke what you
# free". This workload frees only file data blocks; before the rule changed it
# produced zero revoke blocks.
WL2="$WORK/workload-data.txt"
{
  echo "mkdir /d2"
  for i in $(seq 1 40); do
    echo "create /d2/f$i"
    echo "write /d2/f$i data-payload-that-occupies-a-block-of-its-own-so-freeing-it-matters"
  done
  for i in $(seq 1 40); do
    echo "rm /d2/f$i"
  done
} > "$WL2"
IMG3="$WORK/datafree.img"
dd if=/dev/zero of="$IMG3" bs=1m count=64 2>/dev/null
"$DUMP" "$IMG3" format 4 4096 REVOKE3 >/dev/null 2>&1
"$DUMP" "$IMG3" script "$WL2" >/dev/null 2>&1
scan "$IMG3" "our format, data-block frees"

echo ""
echo "─────────────────────────────────"
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
