#!/usr/bin/env bash
# Is everything this run depends on actually switched on?
#
# Three separate things have to be granted by hand before the driver has a
# write barrier: the extension enabled in System Settings, the barrier daemon
# installed and loaded, and Full Disk Access granted to that daemon. Each is a
# toggle somewhere different, none of them announces itself when it lapses, and
# the driver keeps working without them -- just without ordering.
#
# That combination cost three consecutive five-round runs against real
# hardware. Every one of them completed, reported a result, and measured
# nothing, because the barrier under test was not there. The failure looked
# exactly like the bug it was supposed to be measuring.
#
# So this refuses to let a run start until it has *observed* a barrier, rather
# than checking that the pieces which should produce one are present. The only
# evidence that counts is the driver saying so during a real mount of the real
# device.
#
#   scripts/preflight.sh            check what can be checked without a device
#   scripts/preflight.sh diskNsM    also mount it and watch for a live barrier
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE="${1:-}"
TEAM_ID="${TEAM_ID:-BDLYXW7QMN}"
LABEL="dev.h3ct0r.ext4mac.barrier"
PROGRAM="/Library/PrivilegedHelperTools/ext4barrierd"
APP="/Applications/Ext4Mac.app"

FAIL=0
ok()   { printf "  \033[32mok\033[0m    %s\n" "$1"; }
bad()  { FAIL=$((FAIL+1)); printf "  \033[31mNO\033[0m    %s\n" "$1"; [ $# -gt 1 ] && printf "        %s\n" "$2"; return 0; }
note() { printf "        %s\n" "$1"; }

echo "########## PREFLIGHT ##########"
echo ""

# ---------------------------------------------------------- the extension --
if bash "$ROOT/scripts/check_extension.sh" >/dev/null 2>&1; then
  ok "the FSKit extension is installed and enabled"
else
  bad "the FSKit extension is not enabled" \
      "System Settings > General > Login Items & Extensions > File System Extensions"
fi

# ------------------------------------------------------------- the daemon --
if [ -x "$PROGRAM" ]; then
  ok "the barrier daemon is installed"
else
  bad "the barrier daemon is not installed" "make sign && sudo make install-barrier"
fi

# An ad-hoc signature is the specific trap: TCC grants Full Disk Access against
# a code identity, and an ad-hoc binary has none that survives a rebuild. The
# grant lapses silently on the next install and the daemon goes back to being
# denied the device.
if [ -x "$PROGRAM" ]; then
  # Capture, then match. The piped form of this check once reported a
  # correctly signed daemon as ad-hoc -- exactly once, unreproducibly -- and a
  # preflight that cries wolf trains people to override it. Failing this
  # check blocks a run (annoying, safe); it can never pass wrongly, so the
  # hardening only needs to remove the flake.
  sig="$(codesign -dv "$PROGRAM" 2>&1)"
  if printf '%s\n' "$sig" | grep -q "TeamIdentifier=$TEAM_ID"; then
    ok "the daemon is signed with team $TEAM_ID"
  else
    bad "the daemon is not signed with team $TEAM_ID, so its Full Disk Access grant cannot persist" \
        "make sign && sudo make install-barrier, then re-grant Full Disk Access"
    echo "        codesign says: $(printf '%s' "$sig" | head -1)"
  fi
fi

if launchctl print "system/$LABEL" >/dev/null 2>&1; then
  ok "launchd has the daemon"
else
  bad "launchd does not have the daemon" "sudo make install-barrier"
fi

# ------------------------------------------------- writes to removable media --
# Not pass/fail any more: with the barrier-conditional policy, read-write on
# removable media is granted automatically when the barrier works, and the
# live-barrier check below is what proves that end to end. The marker only
# matters as the force-writes-without-barrier override, worth naming when set.
if [ -x "$APP/Contents/MacOS/Ext4Mac" ]; then
  if "$APP/Contents/MacOS/Ext4Mac" removable-writes 2>/dev/null | grep -q FORCED; then
    ok "removable writes FORCED without barrier (marker set) -- the test below still checks for one"
  else
    ok "removable writes: automatic, read-write when the barrier works"
  fi
fi

# ------------------------------------------------------- the only real test --
#
# Everything above says the parts are present. None of it says a barrier will
# happen. Mount the device and watch.
if [ -n "$DEVICE" ]; then
  echo ""
  echo "  checking for a live barrier on $DEVICE"

  started=$(date +%s)
  diskutil unmount "$DEVICE" >/dev/null 2>&1

  # Is it even ours? A device carrying some other filesystem mounts perfectly
  # well through that filesystem's driver, writes nothing through ours, and
  # produces no barrier -- and an unqualified search of the log then matches
  # some other volume's barrier and reports success. That happened, on a FAT32
  # stick, and the check said everything was ready.
  fs=$(diskutil info "$DEVICE" 2>/dev/null | sed -n 's/.*Type (Bundle): *//p' | head -1)
  if [ -n "$fs" ] && [ "$fs" != "ext4" ]; then
    bad "$DEVICE carries a $fs filesystem, not ext4" \
        "the barrier cannot be observed until this driver owns the volume;"
    note "format it first, or point the check at an ext4 volume:"
    note "  sudo build/bin/ext4dump /dev/$DEVICE format 4"
    echo ""
    echo "$FAIL thing(s) not ready."
    exit 1
  fi

  if ! diskutil mount "$DEVICE" >/dev/null 2>&1; then
    bad "$DEVICE did not mount, so the barrier could not be observed" \
        "$(diskutil mount "$DEVICE" 2>&1 | head -1)"
  else
    mp=$(mount | sed -n "s|^/dev/$DEVICE on \(.*\) (ext4.*|\1|p" | head -1)
    if [ -z "$mp" ]; then
      bad "$DEVICE mounted, but not as ext4" \
          "$(mount | grep "/dev/$DEVICE" | head -1)"
      diskutil unmount "$DEVICE" >/dev/null 2>&1
      echo ""
      echo "$FAIL thing(s) not ready."
      exit 1
    fi
    # A write, so that a journal transaction actually commits: the barrier is
    # issued at commit points and nowhere else, so a mount alone proves nothing.
    if [ -n "$mp" ]; then
      mkdir -p "$mp/.preflight" 2>/dev/null && echo x > "$mp/.preflight/f" 2>/dev/null
      sync; sleep 1
      rm -rf "$mp/.preflight" 2>/dev/null
    fi
    diskutil unmount "$DEVICE" >/dev/null 2>&1

    since=$(( $(date +%s) - started + 5 ))
    log_out=$(log show --last "${since}s" --predicate 'subsystem == "dev.h3ct0r.ext4"' --info 2>/dev/null)

    # Match the device, not just the words. See above.
    if grep -q "write barrier active.*on $DEVICE\$" <<<"$log_out"; then
      ok "the driver issued a write barrier on $DEVICE"
    elif grep -q "barrier unavailable" <<<"$log_out"; then
      reason=$(grep "barrier unavailable" <<<"$log_out" | tail -1 | sed 's/.*unavailable: //')
      bad "the driver could not get a write barrier on $DEVICE" "$reason"
      note ""
      note "Almost always Full Disk Access. The daemon runs as root, and root"
      note "is not enough to open removable media -- that is gated by TCC, and"
      note "a daemon has no UI so it is never prompted, only denied."
      note ""
      note "  System Settings > Privacy & Security > Full Disk Access"
      note "  +, then Cmd-Shift-G, and add:"
      note "  $PROGRAM"
      note ""
      note "If an entry for it is already there, remove it and add it again:"
      note "a grant made against an earlier build does not carry over."
    else
      bad "no barrier either way in the log for $DEVICE" \
          "the mount may not have written anything; check the driver log"
    fi
  fi
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "everything this run needs is switched on."
  exit 0
fi

echo "$FAIL thing(s) not ready. Fix the above before running; a suite that runs"
echo "without them will finish, report a result, and have measured nothing."
exit 1
