#!/usr/bin/env bash
# Turn a USB stick into something this driver will be offered.
#
# Formatting a device as ext4 is not enough. macOS routes a volume to a
# filesystem driver by its *partition type*, not by what is written inside the
# partition, so an ext4 superblock inside a partition still typed DOS_FAT_32 is
# handed to msdos and this module is never asked. That cost three formats and
# an hour before anyone thought to look at the partition table.
#
# Two other routes were tried and do not work, recorded here so nobody spends
# the afternoon again:
#
#   - gpt(8) refuses to write a partition table on an external disk while
#     DiskArbitration holds it -- "operation not permitted: create" and the
#     same for add, on both the raw and buffered nodes, as root. diskutil can,
#     because it coordinates with DA, which is what it is for.
#   - A whole-disk ext4 volume with no partition scheme at all is never offered
#     to the module. DiskArbitration reports "Content (IOContent): None" and
#     routes it to nobody, despite "Whole" appearing in our FSMediaTypes.
#
# What works is diskutil's own EXT4 personality, registered by the .fs bundle
# that `sudo make install-diskutil` installs. Its FSFormatContentMask is the
# Linux filesystem type GUID, so diskutil sets that type when it creates the
# partition. Its formatter is newfs_fskit, and startFormat works now
# (validation stage 12), so a clean partitionDisk leaves a formatted volume;
# ext4dump remains the fallback for a partitionDisk that fails or overruns
# its bound.
#
#   sudo make prepare-device DEVICE=diskN
#
# EXT4_SIZE bounds the partition (default 100%): the pull-test autopsy dd's
# the whole partition to a file for e2fsck, which wants it small.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DUMP="$ROOT/build/bin/ext4dump"
DEVICE="${DEVICE:-${1:-}}"
LABEL="${EXT4_LABEL:-ext4test}"
LINUX_FS_GUID=0FC63DAF-8483-4772-8E79-3D69D8477DE4

die() { echo "error: $*" >&2; exit 1; }

[ -n "$DEVICE" ] || die "no device. Usage: sudo make prepare-device DEVICE=diskN"
[ "$(id -u)" = "0" ] || die "needs root: sudo make prepare-device DEVICE=$DEVICE"
[ -x "$DUMP" ] || die "missing $DUMP; run make tools"

# Whole disk only. Handed diskNsM, the partition table is what changes, so
# operating on the parent is what was meant.
WHOLE="${DEVICE%s[0-9]*}"
[ "$WHOLE" != "$DEVICE" ] && echo "note: $DEVICE is a partition; preparing the whole disk $WHOLE"
DEVICE="$WHOLE"

diskutil info "$DEVICE" >/dev/null 2>&1 || die "$DEVICE is not a disk this machine knows about"

# ------------------------------------------------------------------ safety --
#
# This erases everything. The checks below are not ceremony: over one
# afternoon the intended target was named disk6, then disk8, then disk6 again,
# because BSD names are assigned in plug order and change on every replug. A
# script that trusts a name it was given last time will eventually be given the
# name of something else.
INFO=$(diskutil info "$DEVICE" 2>/dev/null)
REMOVABLE=$(sed -n 's/.*Removable Media: *//p' <<<"$INFO" | head -1)
INTERNAL=$(sed -n 's/.*Device Location: *//p' <<<"$INFO" | head -1)
SIZE=$(sed -n 's/.*Disk Size: *//p' <<<"$INFO" | head -1)
NAME=$(sed -n 's/.*Device \/ Media Name: *//p' <<<"$INFO" | head -1)

# Internal-vs-External is the safety line, not the removable bit: large
# sticks and USB SSDs claim "Fixed" media while hanging off an external bus.
[ "$INTERNAL" = "Internal" ] && die "$DEVICE is an internal disk. Refusing."
case "$INTERNAL:$REMOVABLE" in
  External:*emovable*) ;;
  External:*) echo "note: $DEVICE claims fixed media on an external bus (large sticks do)" ;;
  *:*emovable*) ;;
  *) die "$DEVICE reports neither External nor Removable (location '${INTERNAL:-nothing}', media '${REMOVABLE:-nothing}'). Refusing." ;;
esac

echo "about to erase:"
echo "    device    /dev/$DEVICE"
echo "    name      ${NAME:-unknown}"
echo "    size      ${SIZE:-unknown}"
echo "    volumes   $(diskutil list "$DEVICE" | sed -n 's/^ *[0-9]*: *//p' | tr '\n' ';' | cut -c1-70)"
echo ""

if [ "${CONFIRM:-}" != "ERASE" ]; then
  echo "Everything on it will be destroyed. If that is what you want:"
  echo ""
  echo "    sudo make prepare-device DEVICE=$DEVICE CONFIRM=ERASE"
  exit 1
fi

# ------------------------------------------------------------- partitioning --
echo "partitioning..."
diskutil unmountDisk force "$DEVICE" >/dev/null 2>&1
sleep 1

# newfs_fskit formats the volume during partitionDisk now, so the normal path
# is simply letting it finish. Still bounded, because a wedged DiskArbitration
# can hang partitionDisk and a hang must not look like a slow format -- but
# generously: a 15 GB stick over USB 2 needs well over the old 90 s, which was
# learned the hard way when the kill landed mid-write, the partition table
# flipped under a format already in flight, and the result probed as nothing.
SIZE="${EXT4_SIZE:-100%}"
if [ "$SIZE" = "100%" ]; then
  ( diskutil partitionDisk "$DEVICE" GPT EXT4 "$LABEL" 100% >/dev/null 2>&1 ) &
else
  ( diskutil partitionDisk "$DEVICE" GPT EXT4 "$LABEL" "$SIZE" FREE Rest R >/dev/null 2>&1 ) &
fi
pd=$!
PD_OK=no
# Timed and reported, because this wait is invisible and long. partitionDisk
# formats through newfs_fskit, which runs the INSTALLED extension -- so a
# stale install makes this phase slow and the fallback then does the work
# quickly, leaving a run that took minutes with a fast-looking format in it.
# Three reformats were attributed to the format itself before the phases were
# separated.
pd_start=$SECONDS
for _ in $(seq 1 300); do
  if ! kill -0 $pd 2>/dev/null; then wait $pd && PD_OK=yes; break; fi
  sleep 1
done
kill -9 $pd 2>/dev/null
pd_secs=$(( SECONDS - pd_start ))
sleep 2
if [ "$PD_OK" = yes ]; then
  echo "  partitioning took ${pd_secs}s (formatted by newfs_fskit)"
else
  echo "  partitioning took ${pd_secs}s and did not finish cleanly"
  if [ "$pd_secs" -ge 60 ]; then
    echo "        that is long enough to suspect the installed extension is"
    echo "        stale or slow: newfs_fskit formats through it. 'make install'"
    echo "        and check with 'make check-extension'."
  fi
fi

PART="${DEVICE}s2"
diskutil list "$DEVICE" 2>/dev/null | grep -q "${DEVICE}s2" || PART="${DEVICE}s1"

TYPE=$(diskutil info "$PART" 2>/dev/null | sed -n 's/.*Partition Type: *//p' | head -1)
PSIZE=$(diskutil info "$PART" 2>/dev/null | sed -n 's/.*Disk Size: *//p' | head -1 | cut -d'(' -f1)
echo "  partition $PART, type ${TYPE:-unknown}, ${PSIZE:-size unknown}"
if [ "$TYPE" != "$LINUX_FS_GUID" ] && [ "$TYPE" != "Linux Filesystem" ]; then
  echo ""
  echo "warning: the partition type is not the Linux filesystem GUID."
  echo "         macOS routes volumes by partition type, so this driver will"
  echo "         probably not be offered this volume at all. Check that"
  echo "         'sudo make install-diskutil' has been run -- the EXT4"
  echo "         personality it registers is what carries the type."
fi

# ----------------------------------------------------------------- format --
format_directly() {
  echo "formatting $PART as ext4 directly..."
  fmt_start=$SECONDS
  diskutil unmountDisk force "$DEVICE" >/dev/null 2>&1
  sleep 1
  # The raw node first, the buffered one only if it refuses.
  #
  # /dev/diskN routes every transfer through the block layer a sector at a
  # time: an 8 GB volume measured 0.4 MB/s on a USB stick -- five minutes to
  # write 129 MB that the medium itself could stream in seconds. /dev/rdiskN
  # goes straight to the device, and the tool now aligns its own transfers
  # (the superblock at offset 1024 is the one write a format makes that is
  # not a whole sector), which is what a character device requires.
  #
  # Attempted rather than assumed: alignment rules vary by device, and a
  # format that fails outright would be a worse trade than a slow one.
  if "$DUMP" "/dev/r$PART" format 4; then
    NODE="/dev/r$PART"
  else
    echo "  the raw node refused; falling back to the buffered node (slower)"
    NODE="/dev/$PART"
    "$DUMP" "$NODE" format 4 || die "format failed"
  fi
  "$DUMP" "$NODE" label "$LABEL" >/dev/null 2>&1
  echo "  formatting took $(( SECONDS - fmt_start ))s via $NODE"
}

if [ "$PD_OK" = yes ]; then
  echo "formatted by newfs_fskit during partitioning"
else
  echo "partitionDisk did not finish cleanly; falling back"
  format_directly
fi

# Trust nothing above. The one postcondition that matters is that the
# driver's own probe recognises what is on the partition *now* -- a format
# has claimed success onto a table that changed underneath it before.
sleep 2
if ! "$DUMP" "/dev/$PART" probe >/dev/null 2>&1; then
  echo "  probe rejects $PART after formatting; retrying once"
  format_directly
  sleep 2
  "$DUMP" "/dev/$PART" probe >/dev/null 2>&1 \
    || die "the freshly formatted $PART does not probe as ext4"
fi
echo ""
echo "ready:"
diskutil list "$DEVICE" 2>/dev/null | head -6
echo ""
echo "check it end to end before running anything against it:"
echo ""
echo "    make preflight EXT4_KILL_DEVICE=$PART"
