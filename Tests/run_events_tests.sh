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
# The other half -- the extension actually writing one of these from a real
# refused mount -- is a mounted-path suite and is not here yet. See the commit
# that added this file for why.
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
  n=$("$APP" events 5 "$D" 2>/dev/null | wc -l | tr -d ' ')
  [ "$n" = "5" ] && ok "the recent list prints what was asked for" \
                 || bad "the recent list prints what was asked for" "got $n lines"
fi

echo ""
echo "─────────────────────────────────"
finish
