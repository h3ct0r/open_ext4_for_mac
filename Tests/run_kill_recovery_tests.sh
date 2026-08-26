#!/usr/bin/env bash
# Does the journal survive the driver being killed outright?
#
# Tests/run_mount_crash_tests.sh freezes the extension with SIGSTOP and images
# the device underneath it. That is a power cut at the driver's write boundary,
# and it is the right model for one thing -- but a frozen process has already
# issued everything it was going to issue, so the snapshot sees the device in
# issue order. This suite kills the process instead, which is what actually
# happens when a driver crashes, and then lets the journal recover.
#
# The interesting part is what it does NOT catch on a disk image. Five rounds
# of this pass cleanly against an image; the same thing on a real USB stick
# left the volume with an entry whose inode was deleted and a parent link count
# that never landed, twice. Same driver, same workload, same kill. The
# difference is the medium: an image reaches APFS through the page cache in
# issue order, and a USB stick has its own write cache and reorders freely.
#
# So on an image this suite proves the journal and its recovery are correct.
# Pointed at a physical disk -- EXT4_KILL_DEVICE=diskN, which ERASES it -- it
# becomes the detector for the write barrier this driver does not have.
#
# Needs the extension signed, installed and enabled. Writes a report to
# build/kill-recovery-report.txt.
set -uo pipefail

export PATH="/opt/homebrew/opt/e2fsprogs/sbin:/opt/homebrew/opt/e2fsprogs/bin:$PATH"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/build/kill-recovery"
REPORT="$ROOT/build/kill-recovery-report.txt"
MNT="$WORK/mnt"
EXT_PATTERN="/Ext4FS.appex/Contents/MacOS/Ext4FS"

ROUNDS="${ROUNDS:-5}"
IMAGE_MB=64
# Set to a BSD name (diskN or diskNsM) to run against real media instead.
# Everything on it is destroyed, every round.
DEVICE="${EXT4_KILL_DEVICE:-}"

PASS=0; FAIL=0
note() { echo "$*" | tee -a "$REPORT"; }
ok()   { PASS=$((PASS+1)); note "  ok    $1"; }
bad()  { FAIL=$((FAIL+1)); note "  FAIL  $1"; [ $# -gt 1 ] && note "        $2"; return 0; }

DEV=""
cleanup() {
  umount "$MNT" 2>/dev/null
  [ -n "$DEV" ] && [ -z "$DEVICE" ] && hdiutil detach "$DEV" -force >/dev/null 2>&1
  return 0
}
trap cleanup EXIT

if ! bash "$ROOT/scripts/check_extension.sh" >/dev/null 2>&1; then
  echo "the FSKit extension is not enabled; see scripts/check_extension.sh"
  echo "SKIPPED"; exit 77
fi

rm -rf "$WORK"; mkdir -p "$WORK" "$MNT"; : > "$REPORT"

note "########## RECOVERY AFTER THE DRIVER IS KILLED ##########"
note ""
if [ -n "$DEVICE" ]; then
  note "target: /dev/$DEVICE  (real media -- its contents are destroyed)"
else
  note "target: a ${IMAGE_MB}MB disk image"
fi
note ""

# --------------------------------------------------------------- one round --
prepare() {   # leaves the volume formatted, and DEV set
  if [ -n "$DEVICE" ]; then
    DEV="/dev/$DEVICE"
    # Formatting a physical device needs the raw node, which needs privilege.
    sudo "$ROOT/build/bin/ext4dump" "/dev/r$DEVICE" format 4 >/dev/null 2>&1
  else
    rm -f "$WORK/k.img"
    dd if=/dev/zero of="$WORK/k.img" bs=1m count="$IMAGE_MB" 2>/dev/null
    "$ROOT/build/bin/ext4dump" "$WORK/k.img" format 4 >/dev/null 2>&1
    DEV=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount "$WORK/k.img" \
          2>/dev/null | head -1 | awk '{print $1}')
  fi
  [ -n "$DEV" ]
}

fsck_target() {
  if [ -n "$DEVICE" ]; then sudo e2fsck -fn "/dev/$DEVICE" 2>&1
  else e2fsck -fn "$WORK/k.img" 2>&1; fi
}

detach_target() {
  [ -z "$DEVICE" ] && [ -n "$DEV" ] && hdiutil detach "$DEV" -force >/dev/null 2>&1
  DEV=""
  return 0
}

for round in $(seq 1 "$ROUNDS"); do
  prepare || { bad "round $round: could not prepare the volume"; continue; }
  mount -F -t ext4 "${DEV#/dev/}" "$MNT" 2>/dev/null || {
    bad "round $round: did not mount"; detach_target; continue; }

  # A workload that touches every kind of metadata: directory entries, inode
  # allocation, block allocation, link counts, and an xattr apiece.
  ( for i in $(seq 1 300); do
      mkdir -p "$MNT/d$i/inner" 2>/dev/null
      echo x > "$MNT/d$i/f" 2>/dev/null
      xattr -w user.k v "$MNT/d$i/f" 2>/dev/null
    done ) >/dev/null 2>&1 &
  WORKLOAD=$!

  # Somewhere in the middle of it, at no particular boundary.
  sleep "$(python3 -c 'import random; print(round(random.uniform(0.8, 2.2), 2))')"
  pkill -9 -f "$EXT_PATTERN" 2>/dev/null
  sleep 2
  kill "$WORKLOAD" 2>/dev/null; wait "$WORKLOAD" 2>/dev/null

  umount "$MNT" 2>/dev/null
  if [ -z "$DEVICE" ]; then hdiutil detach "$DEV" -force >/dev/null 2>&1; DEV=""; fi

  # Recovery is what is being tested, so let the driver do it: mounting
  # replays the journal, exactly as it would after any crash.
  if [ -n "$DEVICE" ]; then DEV="/dev/$DEVICE"
  else DEV=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount "$WORK/k.img" \
             2>/dev/null | head -1 | awk '{print $1}'); fi
  mount -F -t ext4 "${DEV#/dev/}" "$MNT" 2>/dev/null || {
    bad "round $round: did not mount after the kill"; detach_target; continue; }
  sleep 1
  umount "$MNT" 2>/dev/null
  detach_target
  sleep 1

  out=$(fsck_target)
  if grep -qE "^(Pass 5|.*: [0-9]+/[0-9]+ files)" <<<"$out" && ! grep -q "WARNING" <<<"$out"; then
    ok "round $round: the journal recovered the volume completely"
  else
    bad "round $round: inconsistent after recovery" \
        "$(grep -vE '^Pass |^e2fsck |^$' <<<"$out" | head -3 | tr '\n' ' ')"
  fi
done

note ""
note "─────────────────────────────────"
note "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
