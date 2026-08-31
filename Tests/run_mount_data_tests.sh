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
CASES=$(cat <<'EOF'
sub-block|1000|
one-block|4096|
few-blocks|65536|
one-megabyte|1048576|
eight-megabytes|8388608|
preallocated-1m|1048576|--prealloc
preallocated-8m|8388608|--prealloc
preallocated-64m|67108864|--prealloc
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
