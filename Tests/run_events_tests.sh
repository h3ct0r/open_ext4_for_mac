#!/usr/bin/env bash
# What the extension has to say about a volume, and whether it survives the
# trip to somebody who can read it.
#
# The extension cannot talk to anybody. It has no window, no notification, and
# FSKit's failure vocabulary reaches the user as one sentence -- "The disk you
# inserted was not readable by this computer." -- whether the volume uses a
# feature this driver does not implement, carries a journal it would not
# replay, or is a LUKS container nobody has unlocked yet. The last of those is
# not a fault at all; it is a volume waiting for a passphrase, and it looks
# exactly like a broken disk.
#
# So the extension writes an event into its own container and the app reads it
# back out. This suite is the offline half of that channel: the store, the
# schema, the rotation, the sanitising, and the app's reader. It needs no
# mounted volume, no installed extension and nobody to approve anything --
# which is the point, because those are precisely the things that are not
# always available, and none of them are what usually breaks.
#
# The other half -- the installed extension actually writing one of these
# from a real refused, degraded, locked or pulled volume -- is at the end,
# and runs only where the extension is installed and enabled. It says so
# when it cannot; the offline cells count either way.
#
# Runs unattended. Exit 77 (SKIP) without the probe binary.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/Tests/lib.sh"

PROBE="$ROOT/build/bin/event_probe"
APP="$ROOT/build/Ext4Mac.app/Contents/MacOS/Ext4Mac"
WORK="$ROOT/build/events"

if [ ! -x "$PROBE" ]; then
  echo "build/bin/event_probe is not built (macOS only; needs swiftc)"
  echo "SKIPPED"
  exit 77
fi

rm -rf "$WORK"; mkdir -p "$WORK"

# One directory per cell. These are cheap, and a cell that inherits another
# cell's files is a cell whose failure means two things at once.
newdir() { local d="$WORK/$1"; rm -rf "$d"; mkdir -p "$d"; echo "$d"; }

echo "########## VOLUME EVENTS ##########"
echo ""

# ------------------------------------------------------------ round trip --
echo "the store"
echo ""

D=$(newdir roundtrip)
"$PROBE" write "$D" locked disk9s1 11111111-2222-3333-4444-555555555555 \
  "the container is locked" "core line one" "core line two" >/dev/null
json=$("$PROBE" latest "$D" 11111111-2222-3333-4444-555555555555)

case "$json" in
  *'"kind":"locked"'*)   ok "an event comes back with the kind it was written with" ;;
  *) bad "an event comes back with the kind it was written with" "$json" ;;
esac
case "$json" in
  *'"schema":1'*) ok "and its schema version" ;;
  *) bad "and its schema version" "$json" ;;
esac
case "$json" in
  *'"bridge":["core line one","core line two"]'*)
    ok "and the core's own lines, in order" ;;
  *) bad "and the core's own lines, in order" "$json" ;;
esac

# A volume that could not be read far enough to have a UUID is exactly the
# volume somebody needs to be told about, so the BSD name has to work as a key.
D=$(newdir nouuid)
"$PROBE" write "$D" unformatted disk12s3 "" "nothing recognisable here" >/dev/null
if "$PROBE" latest "$D" disk12s3 | grep -q '"kind":"unformatted"'; then
  ok "a volume with no UUID is keyed by its BSD name"
else
  bad "a volume with no UUID is keyed by its BSD name"
fi

# The UUID is the key when there is one, because it survives being replugged
# into a different port and coming back as a different disk number.
D=$(newdir uuidkey)
"$PROBE" write "$D" refused disk4s1 abcd-0001 "unsupported feature" >/dev/null
"$PROBE" write "$D" refused disk7s1 abcd-0001 "unsupported feature" >/dev/null
n=$(ls "$D"/*.json 2>/dev/null | wc -l | tr -d ' ')
[ "$n" = "1" ] && ok "the same volume on a different port is one record, not two" \
                || bad "the same volume on a different port is one record" "found $n"

# The latest replaces; the history keeps both.
D=$(newdir replace)
"$PROBE" write "$D" locked disk5s1 e-1 "first" >/dev/null
"$PROBE" write "$D" keyRejected disk5s1 e-1 "second" >/dev/null
if "$PROBE" latest "$D" e-1 | grep -q '"reason":"second"'; then
  ok "the latest event replaces the one before it"
else
  bad "the latest event replaces the one before it"
fi
if [ "$("$PROBE" count "$D")" = "2" ]; then
  ok "and the history keeps both"
else
  bad "and the history keeps both" "count=$("$PROBE" count "$D")"
fi

# ------------------------------------------------------- hostile input --
echo ""
echo "input that came off somebody else's disk"
echo ""

# A label and a UUID are attacker-controlled: they are bytes on a volume
# somebody else formatted, and the app turns them into a file name. A key of
# "../../../../evil" must not write outside the directory.
D=$(newdir traversal)
"$PROBE" write "$D" refused ../../../../evil "" "hostile device name" >/dev/null 2>&1
escaped=0
[ -e "$WORK/../../../../evil.json" ] && escaped=1
[ -e "$D/../evil.json" ] && escaped=1
[ "$escaped" = "0" ] && ok "a device name full of ../ does not escape the directory" \
                     || bad "a device name full of ../ does not escape the directory"
inside=$(ls "$D"/*.json 2>/dev/null | wc -l | tr -d ' ')
[ "$inside" = "1" ] && ok "and it still records the event, under a safe name" \
                    || bad "and it still records the event, under a safe name" "$inside files"

D=$(newdir slashes)
"$PROBE" write "$D" refused 'a/b/c' "" "slashes in the device name" >/dev/null 2>&1
if [ "$(ls "$D"/*.json 2>/dev/null | wc -l | tr -d ' ')" = "1" ] && [ ! -d "$D/a" ]; then
  ok "a device name with slashes makes a file, not a directory tree"
else
  bad "a device name with slashes makes a file, not a directory tree"
fi

# ------------------------------------------------------------- rotation --
echo ""
echo "a log that stops growing"
echo ""

D=$(newdir rotate)
"$PROBE" flood "$D" 900 disk3s1 >/dev/null
size=$("$PROBE" logsize "$D")
if [ "$size" -lt 262144 ]; then
  ok "events.log stays under 256 KiB (${size} bytes after 900 events)"
else
  bad "events.log stays under 256 KiB" "${size} bytes"
fi
[ -f "$D/events.log.1" ] && ok "and the previous generation is kept" \
                         || bad "and the previous generation is kept"
# Exactly one generation: a stick that has been refused four thousand times
# has said what it has to say.
gens=$(ls "$D"/events.log* 2>/dev/null | wc -l | tr -d ' ')
[ "$gens" = "2" ] && ok "exactly one older generation, not a growing pile" \
                  || bad "exactly one older generation" "$gens files"
recent=$("$PROBE" recent "$D" 10 | wc -l | tr -d ' ')
[ "$recent" = "10" ] && ok "and the recent history still reads across the rotation" \
                     || bad "the recent history reads across the rotation" "got $recent"

# ------------------------------------------------------------ atomicity --
echo ""
echo "a reader that never sees half a file"
echo ""

# The app watches this directory and reads a file the instant it appears, so a
# partially written one is not theoretical. Write continuously in one process
# while reading continuously in another; every read must either find nothing or
# find a complete, decodable event. A torn read shows up as a decode failure
# with the file present.
D=$(newdir atomic)
"$PROBE" write "$D" refused disk8s1 atomic-1 "seed" >/dev/null
( "$PROBE" flood "$D" 6000 disk8s1 atomic-1 >/dev/null 2>&1 ) &
writer=$!
# The reader has to be a loop inside one process. The first version of this
# cell spawned event_probe once per read, and a process launch is milliseconds
# against a write of microseconds -- so it never landed inside the window, and
# a deliberately torn writer passed it. That is what an injection is for.
counts=$("$PROBE" hammer "$D" atomic-1 4)
kill -9 "$writer" 2>/dev/null; wait "$writer" 2>/dev/null
torn=$(sed -nE 's/.*torn=([0-9]+).*/\1/p' <<<"$counts")
complete=$(sed -nE 's/.*complete=([0-9]+).*/\1/p' <<<"$counts")
if [ "${torn:-1}" = "0" ] && [ "${complete:-0}" -gt 100 ]; then
  ok "$complete concurrent reads during 6000 writes, none of them torn"
else
  bad "concurrent reads are never torn" "$counts"
fi

# ---------------------------------------------------------- permissions --
echo ""
echo "who can read it"
echo ""

D=$(newdir perms)
"$PROBE" write "$D" locked disk6s1 perm-1 "locked" >/dev/null
dmode=$(stat -f %Lp "$D" 2>/dev/null || stat -c %a "$D")
fmode=$(stat -f %Lp "$D/perm-1.json" 2>/dev/null || stat -c %a "$D/perm-1.json")
[ "$dmode" = "700" ] && ok "the events directory is 0700" \
                     || bad "the events directory is 0700" "got $dmode"
[ "$fmode" = "600" ] && ok "and each event file is 0600" \
                     || bad "and each event file is 0600" "got $fmode"
# No temporary file left behind. The atomic write makes one in the same
# directory; if it survives, the rename did not happen and somebody is reading
# a file nothing will ever replace.
leftover=$(ls -a "$D" | grep -c '\.tmp$' || true)
[ "$leftover" = "0" ] && ok "no temporary file is left behind" \
                      || bad "no temporary file is left behind" "$leftover found"

# --------------------------------------------------------- the app side --
echo ""
echo "what a person actually sees"
echo ""

# The reader cells run the app itself, so build it if it is not there -- the
# same bargain the other suites make with their fixtures. 16 seconds, cached
# afterwards. If it will not build, say which cells are not running rather
# than quietly running fewer of them.
if [ ! -x "$APP" ]; then
  echo "  (building the app for the reader cells)"
  make -C "$ROOT" app >/dev/null 2>&1
fi

if [ ! -x "$APP" ]; then
  bad "the app builds, so the reader cells can run" \
      "build/Ext4Mac.app is not there and \`make app\` did not produce it"
else
  D=$(newdir app)
  "$PROBE" write "$D" locked disk9s1 app-uuid-1 "no key for this container" \
      "read-only mount of an unreplayed journal: contents predate the last crash" >/dev/null

  out=$("$APP" last-error app-uuid-1 "$D" 2>&1)
  case "$out" in
    *"disk9s1"*) ok "last-error names the volume" ;;
    *) bad "last-error names the volume" "$out" ;;
  esac
  case "$out" in
    *"no key for this container"*) ok "and says why" ;;
    *) bad "and says why" "$out" ;;
  esac
  # The whole reason this channel exists: "not readable by this computer" is
  # the same sentence for a locked container and a broken disk, and only one
  # of them has anything the person can do about it.
  case "$out" in
    *"encrypted and locked, not broken"*) ok "and says what to do about it" ;;
    *) bad "and says what to do about it" "$out" ;;
  esac
  case "$out" in
    *"unreplayed journal"*) ok "and carries the core's own line through" ;;
    *) bad "and carries the core's own line through" "$out" ;;
  esac

  # People paste all three spellings.
  "$PROBE" write "$D" refused disk11s2 "" "unsupported feature" >/dev/null
  if "$APP" last-error /dev/disk11s2 "$D" 2>&1 | grep -q "unsupported feature"; then
    ok "a /dev/diskN path finds the same record a bare name does"
  else
    bad "a /dev/diskN path finds the same record a bare name does"
  fi

  # A volume nobody has had trouble with must not produce an invented answer.
  "$APP" last-error never-seen-before "$D" >/dev/null 2>&1
  rc=$?
  [ "$rc" = "1" ] && ok "an unknown volume reports nothing, and says so (rc=1)" \
                  || bad "an unknown volume reports nothing" "rc=$rc"

  # Six in this directory by now, so asking for five must give five: a reader
  # that ignores the count and prints everything is the failure here.
  for i in 1 2 3 4; do
    "$PROBE" write "$D" refused "disk20s$i" "" "filler $i" >/dev/null
  done
  # A negative count used to trap inside Collection.suffix -- a stack trace
  # from the verb somebody runs because something already went wrong.
  "$APP" events -1 "$D" >/dev/null 2>&1; rc=$?
  [ "$rc" = "2" ] && ok "a negative count is a usage error, not a crash (rc=2)" \
                  || bad "a negative count is a usage error, not a crash" "rc=$rc"

  n=$("$APP" events 5 "$D" 2>/dev/null | wc -l | tr -d ' ')
  [ "$n" = "5" ] && ok "the recent list prints what was asked for" \
                 || bad "the recent list prints what was asked for" "got $n lines"
fi

# ------------------------------------------------------- the mounted half --
echo ""
echo "what the installed extension actually writes"
echo ""

# Everything above drives the store directly. These cells attach real images
# and let the installed extension refuse, degrade, lock and fail them, then
# read what it wrote back through the installed app with no directory
# argument -- the exact path a person takes. They need the extension enabled,
# so on a machine where it is not (a CI runner, a fresh install) they say so
# and the offline cells above still count.
EVENTS="$HOME/Library/Containers/dev.h3ct0r.ext4mac.Ext4FS/Data/Library/Application Support/events"
INSTALLED="/Applications/Ext4Mac.app/Contents/MacOS/Ext4Mac"
export PATH="/opt/homebrew/opt/e2fsprogs/sbin:/opt/homebrew/opt/e2fsprogs/bin:$PATH"

MDEV=""
MNT="$WORK/mnt"
mounted_cleanup() {
  umount "$MNT" 2>/dev/null
  [ -n "$MDEV" ] && hdiutil detach "$MDEV" -force >/dev/null 2>&1
  return 0
}
trap mounted_cleanup EXIT

attach_img() {  # attach_img <img> [hdiutil flags...] -> MDEV
  local img="$1"; shift
  MDEV=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount "$@" "$img" 2>/dev/null \
         | head -1 | awk '{print $1}')
  [ -n "$MDEV" ]
}
detach_img() {
  # DiskArbitration is still probing a freshly attached image for a few
  # seconds, and a detach issued into that loses; a refused volume gets
  # probed more than once. Keep asking.
  local i
  for i in $(seq 1 20); do
    hdiutil detach "$MDEV" -force >/dev/null 2>&1 && { MDEV=""; return 0; }
    sleep 1
  done
  return 1
}
# The extension's own file, if it wrote one during THIS run. Keyed by UUID
# when the volume had a readable one, by BSD name when it did not -- the
# same rule the store uses -- and it must be newer than the run's start, or
# a leftover from last week would pass today's cell.
event_file() {  # event_file <uuid> <bsd-name>
  local f
  for f in "$EVENTS/$1.json" "$EVENTS/$2.json"; do
    [ -f "$f" ] && [ "$f" -nt "$WORK/started" ] && { echo "$f"; return 0; }
  done
  return 1
}
# Wait for the extension to get round to it: a probe runs on attach, but on
# DiskArbitration's schedule, not ours.
wait_event() {  # wait_event <uuid> <bsd-name> [secs]
  local i n="${3:-15}"
  for (( i = 0; i < n * 2; i++ )); do
    event_file "$1" "$2" >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  return 1
}
mkimg() {  # mkimg <name> <mb> <mke2fs args...> -> prints uuid
  local name="$1" mb="$2"; shift 2
  dd if=/dev/zero of="$WORK/$name.img" bs=1M count="$mb" 2>/dev/null
  mke2fs -q -t ext4 -F "$@" "$WORK/$name.img" >/dev/null 2>&1 || return 1
  dumpe2fs -h "$WORK/$name.img" 2>/dev/null | sed -n 's/^Filesystem UUID: *//p'
}

if ! bash "$ROOT/scripts/check_extension.sh" >/dev/null 2>&1; then
  echo "  (mounted cells skipped: the FSKit extension is not installed and enabled)"
elif ! command -v mke2fs >/dev/null 2>&1; then
  echo "  (mounted cells skipped: mke2fs not found; brew install e2fsprogs)"
else
  bash "$ROOT/scripts/check_install_freshness.sh" || exit 1
  touch "$WORK/started"; sleep 1
  mkdir -p "$MNT"

  # (a) A feature the driver refuses by name. inline_data is in the table as
  # refused, so the probe declines the volume -- and until now that was an
  # os_log line and "not readable by this computer".
  uuid=$(mkimg inline 16 -O inline_data)
  if [ -n "$uuid" ] && attach_img "$WORK/inline.img"; then
    bsd=${MDEV#/dev/}
    if wait_event "$uuid" "$bsd"; then
      out=$("$INSTALLED" last-error "$uuid" 2>&1)
      case "$out" in
        *"kind:     refused"*) ok "a volume with inline_data is recorded as refused" ;;
        *) bad "a volume with inline_data is recorded as refused" "$out" ;;
      esac
      case "$out" in
        *inline*) ok "and the reason names the feature" ;;
        *) bad "and the reason names the feature" "$out" ;;
      esac
    else
      bad "a volume with inline_data is recorded as refused" "no event for $uuid or $bsd in $EVENTS"
      bad "and the reason names the feature" "no event"
    fi
    # A refused volume used to stay busy for as long as the idle probe
    # process lived: FSKit hands the module a resource with the device open,
    # and a module that answers "not recognised" and does nothing else
    # keeps that descriptor. Eject then fails with "Resource busy" for a
    # disk this driver had just declined to touch. The probe now revokes
    # the resource it declines, and this is the cell that noticed.
    detach_img && ok "the declined image can be ejected straight away" || bad "the declined image can be ejected straight away"
  else
    bad "a volume with inline_data is recorded as refused" "could not make or attach the image"
    bad "and the reason names the feature" "no image"
  fi

  # (b) A damaged superblock. One byte of the label changed and the checksum
  # left alone: lwext4 folds that into "unsupported feature", which sends a
  # person looking for a driver when e2fsck is the fix. The probe says which.
  uuid=$(mkimg damaged 16 -O metadata_csum -L GOODLABEL)
  if [ -n "$uuid" ]; then
    printf 'X' | dd of="$WORK/damaged.img" bs=1 seek=$((1024 + 0x78)) conv=notrunc 2>/dev/null
    if attach_img "$WORK/damaged.img"; then
      bsd=${MDEV#/dev/}
      if wait_event "$uuid" "$bsd"; then
        out=$("$INSTALLED" last-error "$uuid" 2>&1 || "$INSTALLED" last-error "$bsd" 2>&1)
        case "$out" in
          *"superblock checksum mismatch"*) ok "an unstamped superblock edit is reported as damage, not a feature" ;;
          *) bad "an unstamped superblock edit is reported as damage, not a feature" "$out" ;;
        esac
      else
        bad "an unstamped superblock edit is reported as damage, not a feature" "no event for $uuid or $bsd"
      fi
      detach_img && ok "the damaged image can be ejected straight away" || bad "the damaged image can be ejected straight away"
    else
      bad "an unstamped superblock edit is reported as damage, not a feature" "could not attach"
    fi
  else
    bad "an unstamped superblock edit is reported as damage, not a feature" "could not make the image"
  fi

  # (c) A dirty journal on read-only media. Mounted read-only, so no replay:
  # the files predate the crash, and the one line that says so was a level-2
  # log line nobody was streaming. It has to arrive in the event.
  uuid=$(mkimg dirty 16 -O has_journal); dirty_uuid=$uuid; dirty_bsd=""
  if [ -n "$uuid" ] && debugfs -w -R "feature +needs_recovery" "$WORK/dirty.img" >/dev/null 2>&1 \
     && attach_img "$WORK/dirty.img" -readonly; then
    bsd=${MDEV#/dev/}; dirty_bsd=$bsd
    if mount -F -r -t ext4 "$MDEV" "$MNT" >/dev/null 2>&1; then
      umount "$MNT" 2>/dev/null
      if wait_event "$uuid" "$bsd" 5; then
        out=$("$INSTALLED" last-error "$uuid" 2>&1)
        case "$out" in
          *"kind:     degradedReadOnly"*) ok "a read-only mount of a dirty journal is recorded as degraded" ;;
          *) bad "a read-only mount of a dirty journal is recorded as degraded" "$out" ;;
        esac
        case "$out" in
          *"unreplayed journal"*) ok "and carries the core's own line about the unreplayed journal" ;;
          *) bad "and carries the core's own line about the unreplayed journal" "$out" ;;
        esac
      else
        bad "a read-only mount of a dirty journal is recorded as degraded" "no event for $uuid or $bsd"
        bad "and carries the core's own line about the unreplayed journal" "no event"
      fi
    else
      bad "a read-only mount of a dirty journal is recorded as degraded" "the read-only mount itself failed"
      bad "and carries the core's own line about the unreplayed journal" "not mounted"
    fi
    detach_img || bad "detached the dirty image"
  else
    bad "a read-only mount of a dirty journal is recorded as degraded" "could not make or attach the image"
    bad "and carries the core's own line about the unreplayed journal" "no image"
  fi

  # (d) A LUKS container nobody has unlocked. The one that most looks like a
  # broken disk and is not. Needs cryptsetup, which lives on Linux.
  if have_linux; then
    ensure_oracle_image ext4luks:cryptsetup-attr <<'DOCKERFILE'
FROM debian:stable-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    cryptsetup-bin e2fsprogs attr && rm -rf /var/lib/apt/lists/*
DOCKERFILE
    printf 'not the key anybody stored' > "$WORK/pass.txt"
    ORACLE_IMAGE=ext4luks:cryptsetup-attr in_linux "$WORK" '
      set -e
      dd if=/dev/zero of=locked.img bs=1M count=32 status=none
      cryptsetup luksFormat --batch-mode --key-file pass.txt --type luks1 locked.img
      cryptsetup luksUUID locked.img > locked.uuid
      chmod 666 locked.img' >/dev/null 2>&1
    luks_uuid=$(tr -d '\r\n' < "$WORK/locked.uuid" 2>/dev/null)
    if [ -n "$luks_uuid" ] && attach_img "$WORK/locked.img"; then
      bsd=${MDEV#/dev/}
      if wait_event "$luks_uuid" "$bsd"; then
        out=$("$INSTALLED" last-error "$luks_uuid" 2>&1)
        case "$out" in
          *"kind:     locked"*) ok "a LUKS container with no key is recorded as locked, not broken" ;;
          *) bad "a LUKS container with no key is recorded as locked, not broken" "$out" ;;
        esac
      else
        bad "a LUKS container with no key is recorded as locked, not broken" "no event for $luks_uuid or $bsd"
      fi
      detach_img || bad "detached the locked container"
    else
      bad "a LUKS container with no key is recorded as locked, not broken" "could not make or attach the container"
    fi
  else
    echo "  (locked-container cell skipped: $(no_linux_reason))"
  fi

  # There is no (e). The plan asked for an unmount failure provoked by
  # taking the device away, and that was tried three ways: hdiutil detach
  # -force (the kernel unmounts cleanly first, so nothing fails), a shadow
  # file on a full volume (the writes were absorbed), and the image's own
  # backing volume force-detached from under it (a real pull: every read
  # failed with EIO). Even then ext4b_unmount returned 0, because a revoked
  # block device REPORTS SUCCESS for writes on macOS -- only reads fail. The
  # unmountFailed site is in the extension and fires on a non-zero return;
  # no external provocation on this platform makes that return non-zero.

  # (f) The reader with no directory argument reads the file the extension
  # wrote. Every cell above already relies on that; this one says it in as
  # many words, by comparing the default path with the explicit one, on the
  # dirty-journal record from (c).
  if [ -n "$dirty_uuid" ] && f=$(event_file "$dirty_uuid" "$dirty_bsd"); then
    a=$("$INSTALLED" last-error "$dirty_uuid" 2>&1)
    b=$("$INSTALLED" last-error "$dirty_uuid" "$EVENTS" 2>&1)
    [ -n "$a" ] && [ "$a" = "$b" ] && ok "last-error with no directory reads the extension's own file" \
                                   || bad "last-error with no directory reads the extension's own file" "default: $a / explicit: $b"
    if grep -q '"build":"' "$f" && ! grep -q '"build":"unknown"' "$f"; then
      ok "and the event says which build wrote it"
    else
      bad "and the event says which build wrote it" "$(cat "$f")"
    fi
  else
    bad "last-error with no directory reads the extension's own file" "no event to compare"
    bad "and the event says which build wrote it" "no event"
  fi
fi

echo ""
echo "─────────────────────────────────"
finish
