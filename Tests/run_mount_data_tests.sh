#!/usr/bin/env bash
# Does a file written through a real FSKit mount read back byte-exact?
#
# Nothing asked that before this suite. Of the five suites that take a real
# mount, only the LUKS one checksums a file; run_throughput_tests.sh writes
# /dev/zero and asserts on size, which cannot see corruption because zeros stay
# zeros whatever happens to them. The differential suite against Linux is the
# strongest oracle in the tree and never mounts at all -- it drives ext4dump.
# So the mounted data path, which is the only path a user's files ever take,
# was covered by nothing, and a field report of corrupted images was the first
# thing to notice.
#
# Everything here runs on an attached disk image: no hardware, no sudo, no
# operator. `mount -F -t ext4` works unprivileged on an hdiutil device owned by
# the attaching user.
#
# Contents come from tools/datafile.c, seeded rather than checksummed, so a
# failure reports the first wrong byte and its alignment instead of "the hash
# differs". Block-aligned zeros and a ragged few bytes are different bugs.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/Tests/lib.sh"

export PATH="/opt/homebrew/opt/e2fsprogs/sbin:/opt/homebrew/opt/e2fsprogs/bin:$PATH"

DUMP="$ROOT/build/bin/ext4dump"
DATA="$ROOT/build/bin/datafile"
WORK="$ROOT/build/mountdata"
MNT="$WORK/mnt"
DEV=""
STARTED_AT=$(date +%s)

[ -x "$DUMP" ] || { echo "build first: make tools"; exit 1; }
[ -x "$DATA" ] || { echo "build first: make tools"; exit 1; }

rm -rf "$WORK"; mkdir -p "$WORK" "$MNT"

note() { printf "        %s\n" "$*"; }

cleanup() {
    umount "$MNT" 2>/dev/null
    [ -n "$DEV" ] && hdiutil detach "$DEV" -force >/dev/null 2>&1
    return 0
}
trap cleanup EXIT

echo "########## MOUNTED DATA INTEGRITY ##########"
echo ""

# --------------------------------------------------------------- primitives --

attach_and_mount() {  # attach_and_mount <image>
    DEV=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount "$1" \
          | head -1 | awk '{print $1}')
    [ -n "$DEV" ] || { note "could not attach $1"; exit 1; }
    local out
    if ! out=$(mount -F -t ext4 "${DEV#/dev/}" "$MNT" 2>&1); then
        if printf '%s' "$out" | grep -q "is disabled"; then
            note "the extension is installed but not enabled."
            note "System Settings > General > Login Items & Extensions"
            note "  > File System Extensions, then run this again."
            note "SKIPPED"
            hdiutil detach "$DEV" >/dev/null 2>&1; DEV=""
            exit 77
        fi
        note "mount failed: $out"
        exit 1
    fi
    assert_mounted "after mounting"
}

# Every write below goes through a path, not a handle. If the volume stops
# being mounted the path still resolves, the writes still succeed, and they
# land on the boot disk -- so the run continues and reports on a volume nothing
# ever touched. Borrowed from run_mount_crash_tests.sh, which learned it first.
assert_mounted() {  # assert_mounted <when>
    if ! mount | grep -q "^$DEV on .*$(basename "$MNT") "; then
        note "the volume is not mounted at $MNT ($1)"
        note "everything below would measure the boot disk, so stopping here"
        exit 1
    fi
}

detach_volume() {
    umount "$MNT" 2>/dev/null
    hdiutil detach "$DEV" >/dev/null 2>&1
    DEV=""
}

# Unmount and mount again before reading. Without this the page cache answers
# every read with the bytes just written and the volume is never consulted --
# the single easiest way to write a data-integrity suite that cannot fail.
remount() {  # remount <image>
    umount "$MNT" 2>/dev/null
    hdiutil detach "$DEV" >/dev/null 2>&1
    DEV=""
    attach_and_mount "$1"
}

# A volume with the requested geometry. `blocks` is chosen by the caller so
# that both an evenly-dividing volume and one with a short last group get
# exercised: an overhanging free range is only mis-walked when the last group
# is partial, which is how one bug stayed invisible until the fixture changed.
make_volume() {  # make_volume <image> <blocks>
    rm -f "$1"
    python3 -c "open('$1','wb').truncate($2 * 4096)"
    "$DUMP" "$1" format 4 4096 MOUNTDATA >/dev/null 2>&1
}

# ------------------------------------------------------------------- cells --

# name : bytes : datafile flags
#
# The sizes bracket the boundaries the write path actually branches on: below a
# block, exactly a block, a few blocks, a run long enough to coalesce, and one
# large enough to cross block groups. The --prealloc rows are the shape macOS
# uses before every large copy, which takes a different branch again --
# ext4_bridge.c writes into the still-unwritten extent and marks it written
# afterwards, skipping the zeroing pass. That branch had no test at all.
#
# The prealloc-tail rows exist because every size above is either sub-block or
# an exact multiple of 4096, and that omission hid a live data-corruption bug
# for the whole of this suite's first day. A preallocated write whose LAST
# bytes are a partial block put that tail at the start of the write instead of
# at its own offset, because the block was classified as past-the-end:
# have_blocks comes from i_size, and preallocated space lies beyond i_size.
# Real files are not multiples of the block size, so this hit almost
# everything a user copied while every cell here stayed green.
CASES=$(cat <<'EOF'
sub-block|1000|
one-block|4096|
few-blocks|65536|
one-megabyte|1048576|
eight-megabytes|8388608|
preallocated-1m|1048576|--prealloc
preallocated-8m|8388608|--prealloc
preallocated-64m|67108864|--prealloc
prealloc-tail-4097|4097|--prealloc
prealloc-tail-5000|5000|--prealloc
prealloc-tail-131313|131313|--prealloc
prealloc-tail-40424|40424|--prealloc
prealloc-tail-3000001|3000001|--prealloc
EOF
)

run_geometry() {  # run_geometry <label> <blocks>
    local label="$1" blocks="$2"
    local img="$WORK/$label.img"
    echo "$label volume ($blocks blocks)"

    make_volume "$img" "$blocks"
    attach_and_mount "$img"

    local seed=1000
    # --- write every case -----------------------------------------------
    while IFS='|' read -r name bytes flags; do
        [ -z "$name" ] && continue
        seed=$((seed + 1))
        if ! out=$($DATA write "$MNT/$name.bin" "$bytes" "$seed" $flags 2>&1); then
            bad "$label: writing $name" "$out"
            continue
        fi
        assert_mounted "after writing $name"
    done <<< "$CASES"

    # --- cold read back -------------------------------------------------
    remount "$img"
    seed=1000
    local failed=0
    while IFS='|' read -r name bytes flags; do
        [ -z "$name" ] && continue
        seed=$((seed + 1))
        if out=$($DATA verify "$MNT/$name.bin" "$bytes" "$seed" 2>&1); then
            :
        else
            bad "$label: $name reads back byte-exact" "$out"
            failed=1
        fi
    done <<< "$CASES"
    [ "$failed" = 0 ] && ok "$label: every file reads back byte-exact after a remount"

    # --- overwrite in place, then re-verify -----------------------------
    # Its own file, not one from CASES: the offline pass below re-derives every
    # case from its original seed, and overwriting one of them there would make
    # that pass fail on a file this cell deliberately changed.
    $DATA write "$MNT/overwrite.bin" 1048576 2000 >/dev/null 2>&1
    $DATA write "$MNT/overwrite.bin" 1048576 2001 >/dev/null 2>&1
    assert_mounted "after overwriting"
    remount "$img"
    if out=$($DATA verify "$MNT/overwrite.bin" 1048576 2001 2>&1); then
        ok "$label: overwriting a file in place leaves the new contents"
    else
        bad "$label: overwriting a file in place leaves the new contents" "$out"
    fi

    # --- concurrent writers ---------------------------------------------
    # The mounted driver is multi-threaded -- a field copy showed seven worker
    # threads -- while every offline suite is serial. Nothing tested this.
    local pids=() i
    for i in 1 2 3 4 5 6; do
        $DATA write "$MNT/conc$i.bin" 4194304 $((3000 + i)) >/dev/null 2>&1 &
        pids+=($!)
    done
    local conc_ok=1
    for i in "${!pids[@]}"; do wait "${pids[$i]}" || conc_ok=0; done
    [ "$conc_ok" = 1 ] || bad "$label: six concurrent writers all succeed" "a writer exited non-zero"
    assert_mounted "after concurrent writes"

    remount "$img"
    local cfail=0
    for i in 1 2 3 4 5 6; do
        if ! out=$($DATA verify "$MNT/conc$i.bin" 4194304 $((3000 + i)) 2>&1); then
            bad "$label: concurrent file $i reads back byte-exact" "$out"
            cfail=1
        fi
    done
    [ "$cfail" = 0 ] && ok "$label: six files written concurrently all read back byte-exact"

    detach_volume

    # --- the same bytes, read by the core instead of FSKit ---------------
    # A mounted-only check cannot tell a bad write from a bad read: both make
    # the file wrong through the mount. ext4dump shares the core and none of
    # FSKit, so agreement here means the bytes on the medium are right.
    seed=1001
    local ofail=0 checked=0
    while IFS='|' read -r name bytes flags; do
        [ -z "$name" ] && continue
        "$DUMP" "$img" cat "/$name.bin" > "$WORK/offline.bin" 2>/dev/null
        if ! out=$($DATA verify "$WORK/offline.bin" "$bytes" "$seed" 2>&1); then
            bad "$label: $name reads correctly offline through the core" "$out"
            ofail=1
        fi
        checked=$((checked + 1))
        seed=$((seed + 1))
    done <<< "$CASES"
    [ "$ofail" = 0 ] && ok "$label: all $checked files read correctly offline through the core"

    # --- structure --------------------------------------------------------
    if out=$(e2fsck -fn "$img" 2>&1); then
        ok "$label: e2fsck finds nothing to repair"
    else
        bad "$label: e2fsck finds nothing to repair" "$(printf '%s' "$out" | head -6 | tr '\n' ' ')"
    fi
}

# 32 groups exactly, and 33 groups with the last holding 5000 of 32768 blocks.
run_geometry "even-groups"   $((32 * 32768))
echo ""
run_geometry "partial-group" $((32 * 32768 + 5000))

# --- the real copy path, not a synthetic one --------------------------------
# `cp` goes through copyfile(3), which is what Finder uses and what the field
# report came from. It found the preallocated-tail bug when every synthetic
# size in this suite passed, because those sizes were block multiples and real
# files are not. Keeping it means the suite exercises whatever copyfile
# actually does today rather than our model of it.
echo ""
echo "the real copy path"
CPIMG="$WORK/copyfile.img"
CPSRC="$WORK/cpsrc"
mkdir -p "$CPSRC"
for n in 40424 131313 1052136 3000001; do
    "$DATA" write "$CPSRC/f$n.bin" "$n" "$n" >/dev/null 2>&1
done
# macOS attaches these to very nearly every file it touches, so a real copy
# always carries them and cp(1) brings them along. Without them this cell was
# only testing file data, and it missed a volume that reported "still has
# errors" for 408 files whose bytes were all intact: mkfs was not claiming
# ext_attr, which makes every i_file_acl illegal to e2fsck.
xattr -w com.apple.quarantine "0081;68deb4c6;Chrome;TESTGUID" "$CPSRC/f40424.bin"
xattr -w com.apple.metadata:kMDItemWhereFroms "https://example.invalid/x" \
      "$CPSRC/f131313.bin"
xattr -w user.plain "value" "$CPSRC/f1052136.bin" 2>/dev/null
make_volume "$CPIMG" $((32 * 32768 + 5000))
attach_and_mount "$CPIMG"
cp "$CPSRC"/*.bin "$MNT/" 2>/dev/null
assert_mounted "after cp"
remount "$CPIMG"
if out=$("$ROOT/scripts/verify_copy.sh" "$CPSRC" "$MNT" 2>&1); then
    ok "cp(1) preserves every byte of every file"
else
    bad "cp(1) preserves every byte of every file" \
        "$(grep -E '^(DIFFERS|MISSING|SIZE)' <<<"$out" | head -3 | tr '\n' ' ')"
fi
# Did the attributes actually make the crossing? A cell that only checks data
# would pass on a volume where every xattr was silently dropped.
if [ -n "$(xattr "$MNT/f40424.bin" 2>/dev/null)" ]; then
    ok "extended attributes survive the copy"
else
    bad "extended attributes survive the copy" "the copy carries none"
fi
detach_volume

# e2fsck, which is where the missing ext_attr feature showed up. The cell
# above passed for a day while every file on the volume carried an xattr
# block e2fsck wanted to strip.
if out=$(e2fsck -fn "$CPIMG" 2>&1); then
    ok "e2fsck finds nothing to repair after a copy carrying xattrs"
else
    bad "e2fsck finds nothing to repair after a copy carrying xattrs" \
        "$(grep -E 'i_file_acl|i_blocks|Block bitmap' <<<"$out" | head -2 | tr '\n' ' ')"
fi

# --- a preallocated write does not shred the extent tree --------------------
# Each mark_written splits the extent it lands in, so a preallocated write used
# to end with roughly one extent per write chunk: 3 MB in four extents where a
# plain write of the same bytes is one, and 512 MB in 256 against ten. macOS
# preallocates before every Finder copy, so that was every copied file --
# e2fsck counts each as "non-contiguous" and suggests narrowing the tree, and
# the extra depth is what made the three-way split reachable at all (0055).
#
# The bound is deliberately loose. What matters is that adjacent written runs
# fold back together, not the exact count, which depends on where the
# allocator happened to put things.
echo ""
echo "extent tree after a preallocated write"
FRAGIMG="$WORK/frag.img"
make_volume "$FRAGIMG" $((32 * 32768 + 5000))
attach_and_mount "$FRAGIMG"
"$DATA" write "$MNT/plain.bin"  3000001 61            >/dev/null 2>&1
"$DATA" write "$MNT/pre.bin"    3000001 61 --prealloc >/dev/null 2>&1
assert_mounted "after writing the extent-tree pair"
detach_volume

count_extents() {  # count_extents <image> <path>
    "$DUMP" "$1" extents "$2" 2>/dev/null | head -1 |
        sed -nE 's/.*, ([0-9]+) extent\(s\).*/\1/p'
}
pl=$(count_extents "$FRAGIMG" /plain.bin)
pr=$(count_extents "$FRAGIMG" /pre.bin)
if [ -n "$pr" ] && [ "$pr" -le 2 ]; then
    ok "a preallocated 3 MB write lands in $pr extent(s), like a plain one ($pl)"
else
    bad "a preallocated write folds its converted runs together" \
        "preallocated=${pr:-?} extents against plain=${pl:-?}; adjacent written runs are not merging"
fi

# --- every ordinary operation, and its effect ------------------------------
# setAttributes returned success and did nothing for the whole life of this
# driver, because nothing here ever checked an operation's EFFECT -- only that
# it did not error. These are the cheapest possible guards against the next one
# of those: do the thing, then look.
echo ""
echo "ordinary operations"
OPSIMG="$WORK/ops.img"
make_volume "$OPSIMG" $((32 * 32768 + 5000))
attach_and_mount "$OPSIMG"

opck() {  # opck <name> <got> <want>
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', wanted '$3'"; fi
}

echo "hello" > "$MNT/f.txt"
opck "a file reads back what was written"  "$(cat "$MNT/f.txt")" "hello"
mkdir -p "$MNT/d/sub"
opck "mkdir -p creates the whole path"     "$([ -d "$MNT/d/sub" ] && echo y)" "y"
mv "$MNT/f.txt" "$MNT/g.txt"
opck "rename moves the name"               "$([ -f "$MNT/g.txt" ] && [ ! -e "$MNT/f.txt" ] && echo y)" "y"
ln "$MNT/g.txt" "$MNT/h.txt" 2>/dev/null
opck "a hard link raises the link count"   "$(stat -f %l "$MNT/g.txt")" "2"
ln -s g.txt "$MNT/s.txt" 2>/dev/null
opck "a symlink keeps its target"          "$(readlink "$MNT/s.txt")" "g.txt"
printf 'more' >> "$MNT/g.txt"
opck "append lands at the end"             "$(cat "$MNT/g.txt")" "$(printf 'hello\nmore')"
rm "$MNT/h.txt"
opck "unlink removes the name"             "$([ ! -e "$MNT/h.txt" ] && echo y)" "y"
rmdir "$MNT/d/sub"
opck "rmdir removes the directory"         "$([ ! -e "$MNT/d/sub" ] && echo y)" "y"
xattr -w user.k v1 "$MNT/g.txt" 2>/dev/null
opck "an xattr reads back"                 "$(xattr -p user.k "$MNT/g.txt" 2>/dev/null)" "v1"
xattr -d user.k "$MNT/g.txt" 2>/dev/null
opck "an xattr can be removed"             "$(xattr "$MNT/g.txt" 2>/dev/null | grep -c user.k)" "0"
touch "$MNT/d/x"; echo z > "$MNT/d/y"
opck "a directory lists what it holds"     "$(ls "$MNT/d" | tr '\n' ' ' | xargs)" "x y"
python3 -c "
f = open('$MNT/sp.bin', 'wb'); f.seek(1048576); f.write(b'END'); f.close()" 2>/dev/null
opck "a sparse write sets the size"        "$(stat -f %z "$MNT/sp.bin")" "1048579"
opck "a hole reads back as zeros"          "$(python3 -c "print(open('$MNT/sp.bin','rb').read(16) == b'\x00' * 16)")" "True"
echo "over" > "$MNT/o1"; echo "written" > "$MNT/o2"; mv -f "$MNT/o2" "$MNT/o1"
opck "rename over an existing name wins"   "$(cat "$MNT/o1")" "written"

remount "$OPSIMG"
opck "contents survive a remount"          "$(cat "$MNT/g.txt")" "$(printf 'hello\nmore')"
opck "a symlink survives a remount"        "$(readlink "$MNT/s.txt")" "g.txt"
opck "a listing survives a remount"        "$(ls "$MNT/d" | tr '\n' ' ' | xargs)" "x y"
detach_volume

# --- setAttributes actually sets attributes ---------------------------------
# It did not. FSKit reports what the caller asked for through isValid(_:), and
# uses consumedAttributes for the FILESYSTEM to report back what it applied.
# Reading consumedAttributes as though it were the request meant it arrived
# empty, every branch was skipped, and setAttributes did nothing at all while
# returning success -- chmod, chown, utimes and truncate alike.
#
# Truncate is the one that costs data: a file kept its old length and its old
# tail, so anything rewriting a file shorter left the difference behind. It is
# checked cold, because the size that matters is the one on the medium.
echo ""
echo "setAttributes"
SAIMG="$WORK/setattr.img"
make_volume "$SAIMG" $((32 * 32768 + 5000))
attach_and_mount "$SAIMG"
"$DATA" write "$MNT/sa.bin" 8388608 71 >/dev/null 2>&1
python3 -c "import os; os.truncate('$MNT/sa.bin', 1048576)" 2>/dev/null
chmod 0641 "$MNT/sa.bin" 2>/dev/null
python3 -c "import os; os.utime('$MNT/sa.bin', (1000000000, 1000000000))" 2>/dev/null
assert_mounted "after setAttributes"
remount "$SAIMG"

sz=$(stat -f %z "$MNT/sa.bin" 2>/dev/null)
md=$(stat -f %Lp "$MNT/sa.bin" 2>/dev/null)
mt=$(stat -f %m "$MNT/sa.bin" 2>/dev/null)
[ "$sz" = 1048576 ] \
  && ok "truncate shrinks the file, and it stays shrunk across a remount" \
  || bad "truncate shrinks the file" "size is $sz, expected 1048576"
[ "$md" = 641 ] \
  && ok "chmod survives a remount" || bad "chmod survives a remount" "mode is $md"
[ "$mt" = 1000000000 ] \
  && ok "utimes survives a remount" || bad "utimes survives a remount" "mtime is $mt"

# The bytes past the new end must be gone, not merely hidden by i_size.
if "$DATA" verify "$MNT/sa.bin" 1048576 71 >/dev/null 2>&1; then
    ok "what remains after a truncate is the head of the original"
else
    bad "what remains after a truncate is the head of the original" \
        "the first megabyte no longer matches"
fi
detach_volume

# --- surprise removal while data is in flight -------------------------------
# The field event this driver exists to survive: the stick is pulled mid-write.
# `hdiutil detach -force` on a mounted image is the unattended stand-in -- the
# device disappears under a live volume, exactly as a yank does.
#
# The bar is not that the in-flight file survives; it cannot, and pretending
# otherwise would be the wrong test. It is that a file CLOSED AND FSYNCED
# before the pull is still byte-exact afterwards, and that the volume comes
# back. A filesystem that loses acknowledged data on removal is not usable on
# removable media, and nothing here checked it before.
echo ""
echo "surprise removal"
PULLIMG="$WORK/pull.img"
make_volume "$PULLIMG" $((32 * 32768 + 5000))
attach_and_mount "$PULLIMG"
$DATA write "$MNT/before.bin" 8388608 4242 >/dev/null 2>&1
assert_mounted "before the pull"

# Big enough that it cannot finish inside the delay: at ~70 MB/s on an image,
# 200 MB completed before the detach on the first attempt and the cell tested
# nothing at all. The interruption is asserted below rather than assumed --
# a pull that arrives after the write has finished proves nothing, and would
# pass quietly forever.
$DATA write "$MNT/during.bin" 1073741824 4243 >/dev/null 2>&1 &
inflight=$!
sleep 2
hdiutil detach "$DEV" -force >/dev/null 2>&1
wait "$inflight" 2>/dev/null; inflight_rc=$?
umount "$MNT" 2>/dev/null
DEV=""

if [ "$inflight_rc" -ne 0 ]; then
    ok "the write was actually in flight when the device went away (rc=$inflight_rc)"
else
    bad "the write was actually in flight when the device went away" \
        "the writer finished before the detach, so this cell tested nothing"
fi

# Remount: the journal replays here, which is the recovery a pull depends on.
if attach_and_mount "$PULLIMG" 2>/dev/null; then
    ok "the volume mounts again after a surprise removal"
    if out=$($DATA verify "$MNT/before.bin" 8388608 4242 2>&1); then
        ok "a file closed before the pull is still byte-exact"
    else
        bad "a file closed before the pull is still byte-exact" "$out"
    fi
    detach_volume
else
    bad "the volume mounts again after a surprise removal" "mount failed"
fi

# Structure afterwards. e2fsck -fn, never -fy: a checker that repairs what it
# finds always agrees with itself, and this project has already lost time to
# using a repairing e2fsck as an oracle.
if out=$(e2fsck -fn "$PULLIMG" 2>&1); then
    ok "the volume is structurally sound after a surprise removal"
else
    bad "the volume is structurally sound after a surprise removal" \
        "$(printf '%s' "$out" | head -4 | tr '\n' ' ')"
fi

# --- a pendrive's ordinary life: many mount cycles ---------------------------
# Write, remount, append, remount, verify. Repeated mount/unmount is what a
# removable volume actually does, and it is barely exercised anywhere: the
# offline suites mount once per command and the mounted suites mount once per
# run.
echo ""
echo "repeated mount cycles"
CYCIMG="$WORK/cycles.img"
make_volume "$CYCIMG" $((32 * 32768 + 5000))
attach_and_mount "$CYCIMG"
cyc_ok=1
for round in 1 2 3 4 5; do
    $DATA write "$MNT/c$round.bin" 4194304 $((5000 + round)) >/dev/null 2>&1 \
        || cyc_ok=0
    assert_mounted "in cycle $round"
    remount "$CYCIMG"
    # every file written in an earlier round must still be intact
    for prev in $(seq 1 "$round"); do
        $DATA verify "$MNT/c$prev.bin" 4194304 $((5000 + prev)) >/dev/null 2>&1 \
            || { bad "cycle $round: c$prev.bin survived $((round - prev + 1)) remount(s)" \
                     "contents changed"; cyc_ok=0; }
    done
done
detach_volume
[ "$cyc_ok" = 1 ] && ok "five write-and-remount cycles leave every file byte-exact"

if out=$(e2fsck -fn "$CYCIMG" 2>&1); then
    ok "e2fsck finds nothing to repair after five mount cycles"
else
    bad "e2fsck finds nothing to repair after five mount cycles" \
        "$(printf '%s' "$out" | head -4 | tr '\n' ' ')"
fi

# --- the allocator's out-of-range guard must never fire on real work --------
# Patch 0054 refuses a free whose range leaves the volume. That is a corrupt
# range by definition, so an ordinary workload must never produce one; if this
# ever trips, the guard is protecting us from ourselves and the cause is a bug
# upstream of it, not a reason to relax the check.
echo ""
echo "the out-of-range guard"
since=$(( $(date +%s) - STARTED_AT + 5 ))
if /usr/bin/log show --last "${since}s" --predicate 'subsystem == "dev.h3ct0r.ext4"' \
       --info 2>/dev/null | grep -q "refused a free of"; then
    bad "no legitimate write produces an out-of-range free" \
        "the allocator refused a free during this run"
else
    ok "no legitimate write produces an out-of-range free"
fi

finish
