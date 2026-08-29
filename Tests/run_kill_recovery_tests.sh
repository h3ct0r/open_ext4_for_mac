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
# exercises real media with real caches -- the configuration the pull-test
# sweep measured clean, twenty pulls across five drives, which is what
# retired the barrier daemon (docs/STATUS.md). Tests/run_pull_tests.sh is
# the harsher sibling: it pulls the device instead of killing the process.
#
# Needs the extension signed, installed and enabled. Writes a report to
# build/kill-recovery-report.txt.
set -uo pipefail

export PATH="/opt/homebrew/opt/e2fsprogs/sbin:/opt/homebrew/opt/e2fsprogs/bin:$PATH"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Refuse-to-lie guard: are we measuring the build in this tree, or a stale
# install? Warns by default; EXT4_REQUIRE_FRESH=1 makes staleness fatal.
bash "$ROOT/scripts/check_install_freshness.sh" || exit 1
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
MOUNTED_AT=""
cleanup() {
  unmount_target
  [ -n "$DEV" ] && [ -z "$DEVICE" ] && hdiutil detach "$DEV" -force >/dev/null 2>&1
  return 0
}
trap cleanup EXIT

# --------------------------------------------------------- target handling --
#
# A disk image and a physical disk are reached completely differently, and
# discovering that cost a run. An image's device node belongs to whoever
# attached it, so `mount -F` works and ext4dump can format it directly. A
# physical disk's node is root:operator: `mount -F` gets "Permission denied"
# from the probe, and only diskutil -- which is privileged -- can mount it.
# Formatting goes through the *buffered* node under sudo, because the raw
# character device only accepts aligned transfers and ext4dump does not
# promise them.

mount_target() {
  if [ -n "$DEVICE" ]; then
    diskutil mount "$DEVICE" >/dev/null 2>&1 || return 1
    MOUNTED_AT=$(mount | sed -n "s|^/dev/$DEVICE on \(.*\) (ext4.*|\1|p" | head -1)
    [ -n "$MOUNTED_AT" ]
  else
    MOUNTED_AT="$MNT"
    mount -F -t ext4 "${DEV#/dev/}" "$MNT" 2>/dev/null
  fi
}

unmount_target() {
  if [ -n "$DEVICE" ]; then
    diskutil unmount "$DEVICE" >/dev/null 2>&1 || \
      diskutil unmount force "$DEVICE" >/dev/null 2>&1
  else
    umount "$MNT" 2>/dev/null
  fi
  MOUNTED_AT=""
  return 0
}

# Killing the driver under a *physical* mount leaves the device claimed by a
# mount whose extension no longer exists. The volume cannot be remounted, and
# -- worse -- the next process to open the device for writing blocks in
# uninterruptible I/O forever, which no signal clears and only unplugging the
# disk resolves. A disk image never showed this: `hdiutil detach -force` tears
# the whole thing down.
#
# So after every kill the disk is force-unmounted and given time for FSKit to
# let go before anything touches the device again.
release_device() {
  [ -z "$DEVICE" ] && return 0
  local whole="${DEVICE%s[0-9]*}"
  diskutil unmountDisk force "$whole" >/dev/null 2>&1
  # Wait for the extension to be gone rather than guessing at a delay.
  local waited=0
  while pgrep -f "$EXT_PATTERN" >/dev/null 2>&1 && [ "$waited" -lt 10 ]; do
    sleep 1; waited=$((waited + 1))
  done
  sleep 2
  return 0
}

if ! bash "$ROOT/scripts/check_extension.sh" >/dev/null 2>&1; then
  echo "the FSKit extension is not enabled; see scripts/check_extension.sh"
  echo "SKIPPED"; exit 77
fi

umount "$MNT" 2>/dev/null
rm -rf "$WORK" 2>/dev/null; mkdir -p "$WORK" "$MNT"; : > "$REPORT"

note "########## RECOVERY AFTER THE DRIVER IS KILLED ##########"
note ""
if [ -n "$DEVICE" ]; then
  note "target: /dev/$DEVICE  (real media -- its contents are destroyed)"
else
  note "target: a ${IMAGE_MB}MB disk image"
fi
note ""

# --------------------------------------------------------------- one round --
FORMATTED=0

prepare() {   # leaves the volume formatted, and DEV set
  if [ -n "$DEVICE" ]; then
    DEV="/dev/$DEVICE"
    unmount_target

    # Format once, not once per round.
    #
    # A 16 GB ext4 volume means roughly 260 MB of inode tables and journal to
    # write. On an SSD that is under a second; on a USB stick it is minutes,
    # with nothing on screen while it happens, which is indistinguishable from
    # a hang -- and five of them is most of the run. After a successful
    # recovery the volume is reusable, so each round works in its own
    # directory instead.
    if [ "$FORMATTED" -eq 0 ]; then
      # Already a working ext4 volume? Then there is nothing to prove by
      # rewriting 260 MB of metadata, and on a stick that is minutes.
      #
      # "Working" has to mean it mounts read-write, not that it probes USABLE.
      # A volume left behind by an interrupted format probes perfectly well --
      # the superblock is written early and is entirely sane -- while the
      # journal it advertises was never written, so every read-write mount
      # fails with EIO. Trusting the probe here cost a five-round run.
      local reusable=0
      if [ -z "${EXT4_KILL_FORCE_FORMAT:-}" ] && mount_target; then
        reusable=1
        unmount_target
      fi
      if [ "$reusable" -eq 1 ]; then
        note "  /dev/$DEVICE already holds a working ext4 volume; not reformatting"
      else
        note "  formatting /dev/$DEVICE (~260 MB of metadata; slow on a stick)"
        # Streamed, not captured. An earlier version wrapped this in $( ),
        # which swallowed the progress output entirely and made the slowest
        # step in the suite look like a hang for the second time.
        sudo "$ROOT/build/bin/ext4dump" "/dev/$DEVICE" format 4 2>&1 | tee -a "$REPORT"
        if [ "${PIPESTATUS[0]}" -ne 0 ]; then
          note "        format failed"
          return 1
        fi
        sudo "$ROOT/build/bin/ext4dump" "/dev/$DEVICE" label KILLTEST >/dev/null 2>&1
        note "  formatted"
      fi
      diskutil list "$DEVICE" >/dev/null 2>&1
      FORMATTED=1
    fi
  else
    rm -f "$WORK/k.img"
    dd if=/dev/zero of="$WORK/k.img" bs=1m count="$IMAGE_MB" 2>/dev/null
    "$ROOT/build/bin/ext4dump" "$WORK/k.img" format 4 >/dev/null 2>&1
    DEV=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount "$WORK/k.img" \
          2>/dev/null | head -1 | awk '{print $1}')
  fi
  [ -n "$DEV" ]
}

# Run something with a deadline, because on real media the thing most likely to
# go wrong is that nothing goes wrong -- it simply never returns.
#
# Killing the driver while it holds a physical device can leave the device not
# answering reads at all. The next e2fsck then sits in uninterruptible wait,
# where no signal reaches it: pkill -9 is a genuine no-op, Ctrl-C does not stop
# the suite because its child is wedged, and only unplugging the disk clears
# it. That happened six times in one afternoon, and each time the suite gave no
# indication of it -- it just stopped, indistinguishable from slow work on a
# volume that takes minutes to check.
#
# There is no timeout(1) on macOS, so: background, poll, and give up loudly.
# No attempt is made to clean up. A process in that state cannot be cleaned up,
# and pretending otherwise is how the last version wasted an afternoon.
FSCK_TIMEOUT="${EXT4_FSCK_TIMEOUT:-300}"

with_deadline() {   # with_deadline <seconds> <command...>
  local secs="$1"; shift
  "$@" &
  local pid=$! waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$secs" ]; then
      kill -9 "$pid" 2>/dev/null
      return 124
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$pid"
}

wedged() {
  note ""
  note "  the device stopped answering after ${FSCK_TIMEOUT}s."
  note ""
  note "  This is not a slow check. Killing the driver while it holds physical"
  note "  media can leave the device serving no reads at all, and a process"
  note "  waiting on it is in uninterruptible sleep -- no signal reaches it, so"
  note "  kill -9 does nothing. Unplug the disk and replug it; the pending I/O"
  note "  then fails, the process becomes killable, and it usually exits on its"
  note "  own. Expect the BSD name to change."
  note ""
  note "  Stopping here rather than hanging."
}

# Output goes to a file, never through a command substitution.
#
# $( ) blocks until every writer closes the pipe, and when the deadline fires
# the process holding it is exactly the one that cannot be killed -- so the
# capture would hang in place of the check, which is the same hang with extra
# steps. A file has no such problem.
fsck_target() {   # fsck_target <outfile>
  if [ -n "$DEVICE" ]; then sudo e2fsck -fn "/dev/$DEVICE" > "$1" 2>&1
  else e2fsck -fn "$WORK/k.img" > "$1" 2>&1; fi
}

# The device path runs e2fsck under sudo. In a shell that cannot ask for a
# password, sudo fails, e2fsck never runs -- and the round then reported
# "inconsistent after recovery", which is a verdict about the filesystem,
# for a failure that was about the terminal. Five rounds of that produced a
# report claiming five recovery failures on a volume that was never checked
# once. Refuse to start instead: a credential either cached or promptable is
# a precondition, not something to discover at round one's verdict.
require_sudo() {
  [ -n "$DEVICE" ] || return 0
  if ! sudo -n true 2>/dev/null && ! [ -t 0 ]; then
    note "this run needs sudo for e2fsck on /dev/$DEVICE, and there is no"
    note "terminal to ask for a password. Run it from an interactive shell,"
    note "or pre-authorise with: sudo -v"
    exit 1
  fi
}

# Put the volume back in a known-good state, so the next round measures its own
# kill and not the last one's wreckage.
#
# Without this every round after a failure re-reports the first round's damage
# -- identical text, same inode numbers, same directory -- and five rounds look
# like five independent results when there is only one. That is exactly what
# the first run against real hardware produced.
repair_target() {
  if [ -n "$DEVICE" ]; then sudo e2fsck -fy "/dev/$DEVICE" >/dev/null 2>&1
  else e2fsck -fy "$WORK/k.img" >/dev/null 2>&1; fi
  return 0
}

detach_target() {
  [ -z "$DEVICE" ] && [ -n "$DEV" ] && hdiutil detach "$DEV" -force >/dev/null 2>&1
  DEV=""
  return 0
}

require_sudo

for round in $(seq 1 "$ROUNDS"); do
  prepare || { bad "round $round: could not prepare the volume"; continue; }
  if ! mount_target; then
    bad "round $round: did not mount" \
        "$(diskutil mount "$DEVICE" 2>&1 | head -1)"
    detach_target; continue
  fi

  # A workload that touches every kind of metadata: directory entries, inode
  # allocation, block allocation, link counts, and an xattr apiece. The
  # directory name carries the run's PID as well as the round, so damage
  # reported by e2fsck can never be confused with an earlier run's.
  ROUND_DIR="k$$-r$round"
  ( for i in $(seq 1 300); do
      mkdir -p "$MOUNTED_AT/$ROUND_DIR/d$i/inner" 2>/dev/null
      echo x > "$MOUNTED_AT/$ROUND_DIR/d$i/f" 2>/dev/null
      xattr -w user.k v "$MOUNTED_AT/$ROUND_DIR/d$i/f" 2>/dev/null
    done ) >/dev/null 2>&1 &
  WORKLOAD=$!

  # Somewhere in the middle of it, at no particular boundary.
  sleep "$(python3 -c 'import random; print(round(random.uniform(0.8, 2.2), 2))')"
  pkill -9 -f "$EXT_PATTERN" 2>/dev/null
  sleep 2
  kill "$WORKLOAD" 2>/dev/null; wait "$WORKLOAD" 2>/dev/null

  unmount_target
  release_device
  if [ -z "$DEVICE" ]; then hdiutil detach "$DEV" -force >/dev/null 2>&1; DEV=""; fi

  # Recovery is what is being tested, so let the driver do it: mounting
  # replays the journal, exactly as it would after any crash.
  if [ -n "$DEVICE" ]; then DEV="/dev/$DEVICE"
  else DEV=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount "$WORK/k.img" \
             2>/dev/null | head -1 | awk '{print $1}'); fi
  note "  round $round: driver killed; waiting for the device to be released"
  mounted=0
  for attempt in 1 2 3 4 5; do
    mount_target && { mounted=1; break; }
    sleep 3
  done
  if [ "$mounted" -eq 0 ]; then
    bad "round $round: did not mount after the kill -- recovery could not run" \
        "$(diskutil mount "$DEVICE" 2>&1 | head -1)"
    release_device; detach_target; continue
  fi
  sleep 1
  unmount_target
  detach_target
  sleep 1

  note "  round $round: replayed; checking with e2fsck"
  with_deadline "$FSCK_TIMEOUT" fsck_target "$WORK/fsck.out"
  if [ $? -eq 124 ]; then
    bad "round $round: the check never returned"
    wedged
    exit 1
  fi
  out=$(cat "$WORK/fsck.out" 2>/dev/null)

  # A verdict requires the check to have actually run. e2fsck output always
  # carries its own banner; sudo's complaints do not.
  if ! grep -q "^e2fsck" <<<"$out"; then
    bad "round $round: e2fsck did not run -- no verdict" \
        "$(head -1 <<<"$out")"
    exit 1
  fi

  with_deadline "$FSCK_TIMEOUT" repair_target
  if [ $? -eq 124 ]; then
    bad "round $round: the repair never returned"
    wedged
    exit 1
  fi
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
