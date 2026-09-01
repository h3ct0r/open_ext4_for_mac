#!/usr/bin/env bash
# A failed checksum has to stop something.
#
# Twenty-two sites in lwext4 verify a metadata checksum. Until now every one
# of them logged and carried on -- and the log went through ext4_dbg, which
# this build compiles out, so the warning did not exist either. Seven of those
# sites are worse than merely quiet. They are the bitmap sites in
# ext4_balloc.c and ext4_ialloc.c, and on a failed verify each one went on to
# modify the bitmap, recompute the checksum over the modified bytes, and write
# that back. A corrupt bitmap was thereby laundered into one that verifies,
# and the evidence was destroyed in the same breath. A checksum whose failure
# is invisible and whose evidence is overwritten is worse than no checksum,
# because it is trusted.
#
# The policy this suite pins down is: refuse writes, allow reads. The seven
# bitmap sites are reached only from allocate and free, so refusing there is
# exactly "refuse the write paths" -- no new state threaded through lwext4.
# The other fifteen sites verify structures being read and still only report.
#
# Every cell corrupts a real image from outside the driver
# (Tests/bitmap_csum.py flips one byte inside the region the checksum covers)
# and then asks two questions, because either alone can be satisfied by a bug:
#
#   did the operation get refused, and did the checksum survive untouched?
#
# The second is the one that matters. A refusal that still rewrote the
# checksum would pass a naive test and leave the volume in exactly the state
# this change exists to prevent.
#
# Runs everywhere: plain images, no Docker. e2fsck is used as an independent
# witness that the corruption is still visible afterwards.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/Tests/lib.sh"

DUMP="$ROOT/build/bin/ext4dump"
INJECT="$ROOT/Tests/bitmap_csum.py"
WORK="$ROOT/build/csum"

[ -x "$DUMP" ] || { echo "build first: make tools"; exit 1; }

rm -rf "$WORK"; mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

# fresh <name> [gen]: a small formatted image to hurt.
fresh() {
  local img="$WORK/$1.img" gen="${2:-4}"
  rm -f "$img"
  python3 -c "open('$img','wb').truncate(64*1024*1024)"
  "$DUMP" "$img" format "$gen" 4096 CSUM >/dev/null 2>&1 \
    || { echo "format failed" >&2; return 1; }
  echo "$img"
}

# Both bitmaps of group 0: the stored checksums and a digest of the bytes they
# cover. One string, so a cell can compare before and after in one line.
snap() { python3 "$INJECT" show "$1" 0; }

# The size a file reports, or -1. Used to ask whether a refused write left
# anything behind.
fsize() {
  "$DUMP" "$1" stat "$2" 2>/dev/null | sed -nE 's/.*size[^0-9]*([0-9]+).*/\1/p' | head -1
}

echo "########## a failed checksum has to stop something ##########"
echo ""
echo "the block bitmap: allocation is refused"
echo ""

IMG=$(fresh block) || exit 1
"$DUMP" "$IMG" create /f.txt >/dev/null 2>&1
python3 "$INJECT" corrupt "$IMG" 0 block >/dev/null
CORRUPTED=$(snap "$IMG")

# The file exists but has no blocks, so this write must allocate one.
out=$("$DUMP" "$IMG" write /f.txt "hello" 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then
  ok "a write that needs a block is refused"
else
  bad "a write that needs a block is refused" "rc=0: $out"
fi

case "$out" in
  *"I/O error"*) ok "the refusal is reported as an I/O error" ;;
  *)             bad "the refusal is reported as an I/O error" "got: $out" ;;
esac

case "$out" in
  *"Bitmap checksum failed"*) ok "and it says why, out loud" ;;
  *) bad "and it says why, out loud" "no warning in: $out" ;;
esac

sz=$(fsize "$IMG" /f.txt)
[ "${sz:-x}" = "0" ] \
  && ok "nothing was written" \
  || bad "nothing was written" "file is now $sz bytes"

[ "$(snap "$IMG")" = "$CORRUPTED" ] \
  && ok "the checksum and the bitmap are untouched" \
  || bad "the checksum and the bitmap are untouched" \
         "before: $CORRUPTED / after: $(snap "$IMG")"

echo ""
echo "the inode bitmap: creation is refused"
echo ""

IMG=$(fresh inode) || exit 1
python3 "$INJECT" corrupt "$IMG" 0 inode >/dev/null
CORRUPTED=$(snap "$IMG")

out=$("$DUMP" "$IMG" create /new.txt 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then
  ok "creating a file is refused"
else
  bad "creating a file is refused" "rc=0: $out"
fi

"$DUMP" "$IMG" stat /new.txt >/dev/null 2>&1 \
  && bad "and the file does not exist" "stat found it" \
  || ok "and the file does not exist"

[ "$(snap "$IMG")" = "$CORRUPTED" ] \
  && ok "the checksum and the bitmap are untouched" \
  || bad "the checksum and the bitmap are untouched" \
         "before: $CORRUPTED / after: $(snap "$IMG")"

echo ""
echo "freeing: the blocks leak rather than pass through a bad bitmap"
echo ""

# The deliberate trade. Refusing a free strands the blocks -- they stay marked
# in use with nothing pointing at them until e2fsck reclaims them. A leak is
# recoverable; handing the same blocks to a second file because the map said
# they were free is not.
IMG=$(fresh free) || exit 1
"$DUMP" "$IMG" create /f.txt  >/dev/null 2>&1
"$DUMP" "$IMG" write  /f.txt "hello" >/dev/null 2>&1
python3 "$INJECT" corrupt "$IMG" 0 block >/dev/null
CORRUPTED=$(snap "$IMG")

"$DUMP" "$IMG" rm /f.txt >/dev/null 2>&1
before_block=$(echo "$CORRUPTED"     | head -1)
after_block=$(snap "$IMG"            | head -1)
[ "$before_block" = "$after_block" ] \
  && ok "the block bitmap was not written through" \
  || bad "the block bitmap was not written through" \
         "before: $before_block / after: $after_block"

# The independent witness. If the driver had laundered the checksum, e2fsck
# would find a tidy volume and the corruption would be gone for good.
fsck_out=$(fsck.ext4 -fn "$IMG" 2>&1)
case "$fsck_out" in
  *"does not match checksum"*)
    ok "e2fsck still sees the corruption afterwards" ;;
  *)
    bad "e2fsck still sees the corruption afterwards" \
        "$(echo "$fsck_out" | grep -iE 'bitmap|checksum' | head -3)" ;;
esac
case "$fsck_out" in
  *"Block bitmap differences"*)
    ok "and reports the leaked block" ;;
  *)
    bad "and reports the leaked block" "no bitmap difference reported" ;;
esac

echo ""
echo "what stays allowed: reading a volume whose bitmaps do not verify"
echo ""

# Refuse writes, allow reads. A volume with a bad bitmap checksum is still the
# only copy of someone's data, and the whole reason to refuse the write is so
# that it can still be read off.
IMG=$(fresh reads) || exit 1
"$DUMP" "$IMG" create /f.txt >/dev/null 2>&1
"$DUMP" "$IMG" write /f.txt "hello" >/dev/null 2>&1
"$DUMP" "$IMG" mkdir /d >/dev/null 2>&1
python3 "$INJECT" corrupt "$IMG" 0 block >/dev/null
python3 "$INJECT" corrupt "$IMG" 0 inode >/dev/null

read_failed=""
run_read() { "$DUMP" "$IMG" "$@" >/dev/null 2>&1 || read_failed="$read_failed $1"; }
run_read ls /
run_read cat /f.txt
run_read stat /f.txt
run_read extents /f.txt
run_read df
run_read groups
run_read check
run_read orphans
run_read probe
[ -z "$read_failed" ] \
  && ok "every read-only verb still works" \
  || bad "every read-only verb still works" "failed:$read_failed"

[ "$("$DUMP" "$IMG" cat /f.txt 2>/dev/null)" = "hello" ] \
  && ok "and the contents come back intact" \
  || bad "and the contents come back intact"

echo ""
echo "healthy volumes are unaffected"
echo ""

# The other half of the proof. A refusal that also fired on good volumes would
# be indistinguishable from a driver that cannot write at all.
IMG=$(fresh healthy) || exit 1
log=$( { "$DUMP" "$IMG" create /f.txt        >/dev/null &&
         "$DUMP" "$IMG" write  /f.txt hello  >/dev/null &&
         "$DUMP" "$IMG" append /f.txt world  >/dev/null &&
         "$DUMP" "$IMG" mkdir  /d            >/dev/null &&
         "$DUMP" "$IMG" rm     /f.txt        >/dev/null ; } 2>&1 ) \
  && ok "create, write, append, mkdir and rm all succeed" \
  || bad "create, write, append, mkdir and rm all succeed" "$log"

case "$log" in
  *"Bitmap checksum failed"*)
    bad "nothing complains about a checksum" "$log" ;;
  *)  ok "nothing complains about a checksum" ;;
esac

fsck.ext4 -fn "$IMG" >/dev/null 2>&1 \
  && ok "e2fsck is clean" \
  || bad "e2fsck is clean" "$(fsck.ext4 -fn "$IMG" 2>&1 | tail -5)"

echo ""
echo "the check is feature-gated: volumes without metadata_csum are untouched"
echo ""

# ext2 and ext3 are formatted without metadata_csum, so the verify short-
# circuits to true and there is nothing to refuse. Worth asserting rather than
# assuming: a refusal that ignored the feature bit would make every ext2
# volume read-only, and no cell above would have noticed.
for gen in 2 3; do
  IMG=$(fresh "gen$gen" "$gen") || exit 1
  "$DUMP" "$IMG" create /f.txt >/dev/null 2>&1
  python3 "$INJECT" corrupt "$IMG" 0 block >/dev/null
  if "$DUMP" "$IMG" write /f.txt "hello" >/dev/null 2>&1; then
    ok "ext$gen still writes with no checksums to fail"
  else
    bad "ext$gen still writes with no checksums to fail"
  fi
done

finish
