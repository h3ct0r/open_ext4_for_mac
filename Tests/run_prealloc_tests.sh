#!/usr/bin/env bash
# Preallocation: blocks without content, zeros without writing them.
#
# fcntl(F_PREALLOCATE) asks for space cheaply. ext4 answers with UNWRITTEN
# extents -- allocated, excluded from reads, converted to written by the first
# write into them. The three ways to get this wrong are all data corruption:
# expose the blocks' previous contents (disclosure), let a written and an
# unwritten extent merge (one state lies about the other), or lose track of
# the blocks at truncate/unlink (a leak e2fsck has to clean).
#
# Every assertion here has an independent oracle: e2fsck for accounting,
# debugfs's [u] extent markers against our own extents command, and the Linux
# kernel for crash cuts.
set -uo pipefail
export PATH="/opt/homebrew/opt/e2fsprogs/sbin:/opt/homebrew/opt/e2fsprogs/bin:$PATH"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DUMP="$ROOT/build/bin/ext4dump"
WORK="$ROOT/build/prealloc"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok    $*"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $*"; shift; [ $# -gt 0 ] && echo "        $*"; }

[ -x "$DUMP" ] || { echo "build first: make tools"; exit 1; }
rm -rf "$WORK"; mkdir -p "$WORK"

echo "########## PREALLOCATION ##########"
echo ""

IMG="$WORK/p.img"
new_vol() {
  rm -f "$IMG"
  dd if=/dev/zero of="$IMG" bs=1m count=64 2>/dev/null
  "$DUMP" "$IMG" format 4 4096 PREALLOC >/dev/null 2>&1
}

# --- the shape: allocated, unwritten, size untouched -------------------------
new_vol
"$DUMP" "$IMG" create /f.bin >/dev/null 2>&1
# stdout only. The tool's RESULT is on stdout and its log lines go to stderr,
# so folding them together made this cell fail the moment mount grew an
# accounting audit -- an exact-match assertion on 2>&1 breaks on any new log
# line, however correct. Failures are still reported: rc is checked below.
out=$("$DUMP" "$IMG" prealloc /f.bin 0 1048576 2>/dev/null); rc=$?
[ "$rc" = 0 ] && [ "$out" = "preallocated 1048576 bytes" ] \
  && ok "a megabyte is preallocated in full" \
  || bad "a megabyte is preallocated in full" "rc=$rc out=$out"

ext=$("$DUMP" "$IMG" extents /f.bin 2>/dev/null)
grep -q "size=0 alloc=1048576" <<<"$ext" \
  && ok "size stays zero while a megabyte is allocated" \
  || bad "size stays zero while a megabyte is allocated" "$(head -1 <<<"$ext")"
[ -z "$(grep -v 'unwritten' <<<"$ext" | grep 'logical')" ] \
  && ok "every extent is unwritten" \
  || bad "every extent is unwritten"

# debugfs is the independent witness for the [u] flag
debugfs -R "stat /f.bin" "$IMG" 2>/dev/null | grep -q '\[u\]' \
  && ok "debugfs sees the uninit flag" || bad "debugfs sees the uninit flag"
e2fsck -fn "$IMG" >/dev/null 2>&1 \
  && ok "e2fsck accepts blocks past EOF" || bad "e2fsck accepts blocks past EOF" \
       "$(e2fsck -fn "$IMG" 2>&1 | grep -m1 -vE '^e2fsck|^Pass|^$' | cut -c1-60)"

# --- reads see zeros, never old contents -------------------------------------
# Make the disclosure bug measurable: fill the volume with a marker, delete,
# then preallocate into the space the marker blocks came from. If conversion
# or reads ever expose old contents, the marker is what they expose.
new_vol
"$DUMP" "$IMG" create /marker.bin >/dev/null 2>&1
"$DUMP" "$IMG" write /marker.bin "$(python3 -c "print('SECRET-'*512)")" >/dev/null 2>&1
"$DUMP" "$IMG" rm /marker.bin >/dev/null 2>&1
"$DUMP" "$IMG" create /f.bin >/dev/null 2>&1
"$DUMP" "$IMG" prealloc /f.bin 0 65536 >/dev/null 2>&1
"$DUMP" "$IMG" truncate /f.bin 65536 >/dev/null 2>&1     # size now covers it
if "$DUMP" "$IMG" cat /f.bin 2>/dev/null | grep -q "SECRET"; then
  bad "preallocated space reads as zeros, not old contents"
else
  ok "preallocated space reads as zeros, not old contents"
fi
n=$("$DUMP" "$IMG" cat /f.bin 2>/dev/null | tr -d '\0' | wc -c | tr -d ' ')
[ "$n" = "0" ] && ok "all 64KB read as zero bytes" \
              || bad "all 64KB read as zero bytes" "found $n nonzero"

# --- first write converts, everything else stays zero ------------------------
"$DUMP" "$IMG" write /f.bin "DATA-LANDS-HERE" >/dev/null 2>&1
got=$("$DUMP" "$IMG" cat /f.bin 2>/dev/null | head -c 15)
[ "$got" = "DATA-LANDS-HERE" ] \
  && ok "a write into preallocated space stores its data" \
  || bad "a write into preallocated space stores its data" "read back: $got"
rest=$("$DUMP" "$IMG" cat /f.bin 2>/dev/null | tail -c +16 | tr -d '\0' | wc -c | tr -d ' ')
[ "$rest" = "0" ] \
  && ok "the rest of the converted block is zeros, not the marker" \
  || bad "the rest of the converted block is zeros, not the marker" "$rest nonzero"
"$DUMP" "$IMG" extents /f.bin 2>/dev/null | sed -n '2p' | grep -vq unwritten \
  && ok "the written block's extent converted to written" \
  || bad "the written block's extent converted to written"
e2fsck -fn "$IMG" >/dev/null 2>&1 \
  && ok "conversion leaves the volume clean" || bad "conversion leaves the volume clean" \
       "$(e2fsck -fn "$IMG" 2>&1 | grep -m1 -vE '^e2fsck|^Pass|^$' | cut -c1-60)"

# --- append after preallocation must use the preallocated blocks -------------
new_vol
"$DUMP" "$IMG" create /a.bin >/dev/null 2>&1
"$DUMP" "$IMG" prealloc /a.bin 0 131072 >/dev/null 2>&1
"$DUMP" "$IMG" write /a.bin "$(python3 -c "print('A'*9000)")" >/dev/null 2>&1
before=$("$DUMP" "$IMG" stat /a.bin 2>/dev/null | sed -n 's/.*alloc[^0-9]*\([0-9]*\).*/\1/p' | head -1)
ext=$("$DUMP" "$IMG" extents /a.bin 2>/dev/null | head -1)
grep -q "alloc=131072" <<<"$ext" \
  && ok "writing into preallocated space allocates nothing new" \
  || bad "writing into preallocated space allocates nothing new" "$ext"

# --- truncate and unlink release everything ----------------------------------
"$DUMP" "$IMG" truncate /a.bin 0 >/dev/null 2>&1
"$DUMP" "$IMG" extents /a.bin 2>/dev/null | head -1 | grep -q "alloc=0" \
  && ok "truncate to zero frees preallocated blocks too" \
  || bad "truncate to zero frees preallocated blocks too" \
       "$("$DUMP" "$IMG" extents /a.bin 2>/dev/null | head -1)"

new_vol
base=$(e2fsck -fn "$IMG" 2>&1 | sed -n 's/^.*: \([0-9]*\/[0-9]*\) files.*, \([0-9]*\)\/[0-9]* blocks$/\1 \2/p')
"$DUMP" "$IMG" create /g.bin >/dev/null 2>&1
"$DUMP" "$IMG" prealloc /g.bin 0 1048576 >/dev/null 2>&1
"$DUMP" "$IMG" rm /g.bin >/dev/null 2>&1
after=$(e2fsck -fn "$IMG" 2>&1 | sed -n 's/^.*: \([0-9]*\/[0-9]*\) files.*, \([0-9]*\)\/[0-9]* blocks$/\1 \2/p')
[ "$base" = "$after" ] \
  && ok "unlinking a zero-size preallocated file leaks nothing" \
  || bad "unlinking a zero-size preallocated file leaks nothing" "was [$base] now [$after]"
e2fsck -fn "$IMG" >/dev/null 2>&1 \
  && ok "and the volume is clean afterwards" || bad "and the volume is clean afterwards"

# --- crash cuts across the whole lifecycle, Linux kernel as the oracle -------
if docker info >/dev/null 2>&1; then
  new_vol
  "$DUMP" "$IMG" create /c.bin >/dev/null 2>&1
  WL="$WORK/wl.txt"
  {
    echo "prealloc /c.bin 0 262144"
    echo "write /c.bin $(python3 -c "print('C'*5000)")"
    echo "truncate /c.bin 0"
    echo "rm /c.bin"
  } > "$WL"
  cp "$IMG" "$WORK/count.img"
  T=$(EXT4DUMP_REPORT_WRITES=1 EXT4B_TXN_BATCH=1 "$DUMP" "$WORK/count.img" script "$WL" 2>&1 >/dev/null | sed -n 's/^writes=//p' | tail -1)
  rm -f "$WORK/count.img"
  gen=0
  for n in $(seq 1 "$T"); do
    cp "$IMG" "$WORK/cut_$n.img"
    EXT4DUMP_FAIL_AFTER=$n EXT4B_TXN_BATCH=1 "$DUMP" "$WORK/cut_$n.img" script "$WL" >/dev/null 2>&1
    gen=$((gen+1))
  done
  docker run --rm --privileged -v "$WORK:/work" debian:stable-slim bash -c '
    mkdir -p /mnt/t
    for img in /work/cut_*.img; do
      mount -o loop "$img" /mnt/t 2>/dev/null && umount /mnt/t || echo "REFUSED $img"
    done; exit 0' > "$WORK/replay.log" 2>&1
  refused=$(grep -c REFUSED "$WORK/replay.log"); refused=${refused:-0}
  dirty=0; first=""
  for img in "$WORK"/cut_*.img; do
    if ! e2fsck -fn "$img" >/dev/null 2>&1; then
      dirty=$((dirty+1))
      [ -z "$first" ] && first="$(basename "$img"): $(e2fsck -fn "$img" 2>&1 | grep -m1 -vE '^e2fsck|^Pass|^$' | cut -c1-56)"
    fi
  done
  if [ "$dirty" -eq 0 ] && [ "$refused" -eq 0 ]; then
    ok "every cut of prealloc/convert/truncate/rm recovers via kernel replay ($gen cuts)"
  else
    bad "every cut of prealloc/convert/truncate/rm recovers via kernel replay ($gen cuts)" \
        "$dirty dirty, $refused refused — first: $first"
  fi
else
  echo "  skip  docker is not running; crash cuts not replayed"
fi

# ============ a torn write into preallocated space exposes nothing ==
#
# Writing into a preallocated file used to zero the range before the data,
# so that a reader could never see what the blocks held for their previous
# owner. That doubled every byte written, and macOS preallocates before
# every large copy -- 994 MB on the medium for a 522 MB file. The zeroing
# is gone; what makes it safe is the ORDER that replaced it. The data is
# written while the extent is still unwritten, and the extent is marked
# written only afterwards, so a cut in between leaves it unwritten, which
# reads back as zeros.
#
# This is the cell that proves it. A file full of a recognisable pattern is
# written and deleted, its blocks are preallocated to a new file, and the
# write into them is cut at a series of points. Every byte the filesystem
# then shows must be the new data or a zero -- never the old pattern.
echo ""
echo "a torn write into preallocated space"
SECRET="$WORK/secret.bin"; FRESH="$WORK/fresh.bin"
python3 -c "open('$SECRET','wb').write(b'OLD-OWNER-SECRET-BYTES!!'*(8*1024*1024//24))"
python3 -c "open('$FRESH','wb').write(b'N'*(8*1024*1024))"
leaks=0; dirty=0; partials=0
for CUT in 20 40 60 80 100; do
  img="$WORK/tear_$CUT.img"
  rm -f "$img"; dd if=/dev/zero of="$img" bs=1m count=120 2>/dev/null
  "$DUMP" "$img" format 4 >/dev/null 2>&1
  "$DUMP" "$img" create /secret >/dev/null 2>&1
  "$DUMP" "$img" put /secret "$SECRET" >/dev/null 2>&1
  "$DUMP" "$img" rm /secret >/dev/null 2>&1
  "$DUMP" "$img" create /victim >/dev/null 2>&1
  "$DUMP" "$img" prealloc /victim 0 8388608 >/dev/null 2>&1
  EXT4B_TXN_BATCH=1 EXT4DUMP_FAIL_AFTER=$CUT "$DUMP" "$img" put /victim "$FRESH" >/dev/null 2>&1
  "$DUMP" "$img" label RECOVER >/dev/null 2>&1        # read-write mount replays
  "$DUMP" "$img" cat /victim > "$WORK/tear_read.bin" 2>/dev/null
  verdict=$(python3 - "$WORK/tear_read.bin" <<'PYEOF'
import sys
d = open(sys.argv[1], "rb").read()
leak = b"OLD-OWNER-SECRET" in d
other = len(d) - d.count(b"N") - d.count(b"\x00")
print(f"{'LEAK' if leak or other else 'clean'} {len(d)}")
PYEOF
)
  case "$verdict" in LEAK*) leaks=$((leaks+1)) ;; esac
  size=${verdict##* }
  [ "$size" -gt 0 ] && [ "$size" -lt 8388608 ] && partials=$((partials+1))
  e2fsck -fn "$img" >/dev/null 2>&1 || dirty=$((dirty+1))
  rm -f "$img"
done
if [ "$leaks" -eq 0 ] && [ "$dirty" -eq 0 ]; then
  ok "a cut write into preallocated space shows only new data or zeros ($partials partial states)"
else
  bad "a cut write into preallocated space shows only new data or zeros" \
      "$leaks leaked the previous owner's bytes, $dirty inconsistent"
fi
rm -f "$SECRET" "$FRESH" "$WORK/tear_read.bin"

echo ""
echo "─────────────────────────────────"
echo "passed: $PASS   failed: $FAIL"
rm -f "$WORK"/cut_*.img
[ "$FAIL" -eq 0 ]
