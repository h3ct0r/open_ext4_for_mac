#!/usr/bin/env bash
# Volumes and files past four gibibytes.
#
# Everything mounted has been small: the largest volume any suite mounts is
# 4 GiB and the largest file 1 GiB. Neither number is arbitrary -- 4 GiB is
# where a byte count stops fitting in 32 bits, and a file that crosses it
# exercises i_size_high, the large_file read-only-compat feature, and every
# place a block count or a logical block index could still be a uint32 that
# nothing has ever pushed. A driver that is wrong there is wrong on exactly
# the files people care most about.
#
# Reading a 4.5 GiB file back in full costs minutes, which is how a suite
# stops being run. datafile's contents are a pure function of (offset, seed),
# so `verify-range` checks the places where an arithmetic mistake would show:
# the head, the tail, the 4 GiB boundary itself, and windows either side of
# every gibibyte. The whole file's SIZE is still checked on every one of them,
# because a file that came back short is broken however well a sample reads.
#
# Slow by construction -- SLOW=1 to run it. `make test-scale` sets that.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/Tests/lib.sh"

export PATH="/opt/homebrew/opt/e2fsprogs/sbin:/opt/homebrew/opt/e2fsprogs/bin:$PATH"

DUMP="$ROOT/build/bin/ext4dump"
DATA="$ROOT/build/bin/datafile"
WORK="$ROOT/build/scale"
MNT="$WORK/mnt"
DEV=""

[ -x "$DUMP" ] || { echo "build first: make tools"; exit 1; }
[ -x "$DATA" ] || { echo "build first: make tools"; exit 1; }

if [ "${SLOW:-0}" != "1" ]; then
    echo "scale suite skipped (writes ~4.5 GiB; SLOW=1 to run, or make test-scale)"
    exit 0
fi

rm -rf "$WORK"; mkdir -p "$WORK" "$MNT"
note() { printf "        %s\n" "$*"; }
cleanup() {
    umount "$MNT" 2>/dev/null
    [ -n "$DEV" ] && hdiutil detach "$DEV" -force >/dev/null 2>&1
    rm -rf "$WORK"
    return 0
}
trap cleanup EXIT

attach_and_mount() {  # attach_and_mount <image>
    DEV=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount "$1" \
          | head -1 | awk '{print $1}')
    [ -n "$DEV" ] || { note "could not attach $1"; exit 1; }
    local out
    if ! out=$(mount -F -t ext4 "${DEV#/dev/}" "$MNT" 2>&1); then
        if printf '%s' "$out" | grep -q "is disabled"; then
            note "the extension is installed but not enabled."
            note "System Settings > General > Login Items & Extensions"
            hdiutil detach "$DEV" >/dev/null 2>&1; DEV=""
            exit 77
        fi
        note "mount failed: $out"
        exit 1
    fi
    mount | grep -q "^$DEV on " || { note "not mounted"; exit 1; }
}

remount() {  # the cold read. Without it the page cache answers every read
             # with the bytes just written and the medium is never consulted.
    umount "$MNT" 2>/dev/null
    hdiutil detach "$DEV" >/dev/null 2>&1
    DEV=""
    attach_and_mount "$1"
}

GIB=$((1024 * 1024 * 1024))
IMG="$WORK/big.img"
VOL_BYTES=$((16 * GIB))
BIG=$((4 * GIB + GIB / 2))          # 4.5 GiB: past the boundary, not by much
SEED=90210

echo "########## VOLUMES AND FILES PAST 4 GiB ##########"
echo ""
echo "a volume of $((VOL_BYTES / GIB)) GiB"
echo ""

# Sparse: the bytes only exist where something writes them, which is what
# makes a 16 GiB fixture cost megabytes. The lazy-group fixtures already
# depend on this working.
python3 -c "open('$IMG','wb').truncate($VOL_BYTES)"
t0=$(date +%s)
if "$DUMP" "$IMG" format 4 4096 SCALE >/dev/null 2>&1; then
    ok "formats in $(( $(date +%s) - t0 ))s"
else
    bad "formats"; finish; exit 1
fi

blocks=$("$DUMP" "$IMG" probe 2>/dev/null | sed -nE 's/.*blocks:[^0-9]*([0-9]+).*/\1/p' | head -1)
[ "${blocks:-0}" -gt $((VOL_BYTES / 4096 - 4096)) ] \
    && ok "the superblock counts $blocks blocks, which is the whole volume" \
    || bad "the superblock counts the whole volume" "got '${blocks:-none}'"

attach_and_mount "$IMG"
df_out=$(df -k "$MNT" | tail -1)
avail=$(awk '{print $2}' <<<"$df_out")
# statfs reports in 1 KiB units here; a 16 GiB volume is ~16.7 million of them.
[ "${avail:-0}" -gt $((12 * 1024 * 1024)) ] \
    && ok "df reports the volume's real size ($((avail / 1024)) MiB)" \
    || bad "df reports the volume's real size" "$df_out"

echo ""
echo "a file of $((BIG / GIB)).5 GiB"
echo ""

t0=$(date +%s)
if "$DATA" write "$MNT/big.bin" "$BIG" "$SEED" >/dev/null 2>&1; then
    secs=$(( $(date +%s) - t0 ))
    ok "written in ${secs}s ($(( BIG / 1048576 / (secs > 0 ? secs : 1) )) MB/s)"
else
    bad "a 4.5 GiB file can be written at all"; finish; exit 1
fi

sz=$(stat -f %z "$MNT/big.bin" 2>/dev/null)
[ "${sz:-0}" = "$BIG" ] \
    && ok "and reports its full size while still mounted" \
    || bad "and reports its full size while still mounted" "got ${sz:-none}"

remount "$IMG"

sz=$(stat -f %z "$MNT/big.bin" 2>/dev/null)
[ "${sz:-0}" = "$BIG" ] \
    && ok "the size survives a remount, so i_size_high was written and read" \
    || bad "the size survives a remount" "got ${sz:-none}"

# Every window that could catch a truncated offset. Each also re-checks the
# whole file's size, so a short file fails here even if the sampled bytes are
# right where they land.
WIN=$((4 * 1024 * 1024))
declare -a SPOTS=(
    "0:the first bytes"
    "$((1 * GIB)):one gibibyte in"
    "$((2 * GIB)):two"
    "$((3 * GIB)):three"
    "$((4 * GIB - WIN / 2)):straddling the 4 GiB boundary"
    "$((4 * GIB)):the first block past 4 GiB"
    "$((BIG - WIN)):the tail"
)
bad_spots=""
for spot in "${SPOTS[@]}"; do
    off="${spot%%:*}"
    "$DATA" verify-range "$MNT/big.bin" "$BIG" "$SEED" "$off" "$WIN" >/dev/null 2>&1 \
        || bad_spots="$bad_spots ${spot#*:}($off);"
done
[ -z "$bad_spots" ] \
    && ok "read cold, all ${#SPOTS[@]} sampled windows match, boundary included" \
    || bad "read cold, every sampled window matches" "$bad_spots"

echo ""
echo "and it is all still consistent"
echo ""

umount "$MNT" 2>/dev/null
hdiutil detach "$DEV" >/dev/null 2>&1; DEV=""

# The one thing no sample can show: a file over 2 GiB needs the large_file
# read-only-compat bit, and a volume that grew one without claiming it is a
# volume Linux mounts read-only. Read after the unmount, not before -- the
# image of a mounted volume carries whatever the superblock looked like
# mid-flight, INCOMPAT_RECOVER included, and reading it there once made this
# cell report on a filesystem that did not exist yet.
ro=$("$DUMP" "$IMG" probe 2>/dev/null | sed -nE 's/.*ro_compat=0x0*([0-9a-fA-F]+).*/\1/p' | head -1)
if [ -n "$ro" ] && [ $(( 0x$ro & 0x2 )) -ne 0 ]; then
    ok "the volume claims large_file (ro_compat=0x$ro)"
else
    bad "the volume claims large_file" "ro_compat='${ro:-none}'"
fi

fsck.ext4 -fn "$IMG" >/dev/null 2>&1 \
    && ok "e2fsck finds nothing wrong with a 16 GiB volume holding a 4.5 GiB file" \
    || bad "e2fsck finds nothing wrong" "$(fsck.ext4 -fn "$IMG" 2>&1 | tail -8)"

finish
