#!/usr/bin/env bash
# Is everything this run depends on actually switched on?
#
# The hand-granted switches -- the extension enabled in System Settings, the
# .fs bundle installed for formatting -- announce nothing when they lapse, and
# a suite that runs without them finishes, reports a result, and has measured
# nothing. That cost three five-round hardware runs once. So check first.
#
# (This script used to gate hardware runs on observing a live write barrier
# from the retired ext4barrierd daemon. The daemon was removed after
# remeasurement -- see docs/STATUS.md -- so the end-to-end check is now the
# simpler true condition: the driver owns the volume and takes writes.)
#
#   scripts/preflight.sh            check what can be checked without a device
#   scripts/preflight.sh diskNsM    also mount it and prove a write goes through
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE="${1:-}"

FAIL=0
ok()   { printf "  \033[32mok\033[0m    %s\n" "$1"; }
bad()  { FAIL=$((FAIL+1)); printf "  \033[31mNO\033[0m    %s\n" "$1"; [ $# -gt 1 ] && printf "        %s\n" "$2"; return 0; }
note() { printf "        %s\n" "$1"; }

echo "########## PREFLIGHT ##########"
echo ""

# --------------------------------------------------------------- the tools --
# The hardware suites format and inspect through ext4dump; after `make clean`
# they used to fail mid-run with a message that blamed the device.
if [ -x "$ROOT/build/bin/ext4dump" ]; then
  ok "ext4dump is built"

  # ...and built from what is checked out right now. The revision is compiled
  # into the core, while the app and extension carry theirs in a plist the
  # Makefile re-stamps every commit. Those are only the same fact if the core
  # was actually rebuilt, and when they drift the accounting lines keep naming
  # an older commit while `Ext4Mac version` names the current one -- so the
  # session looks fresh and measures the previous build. That has cost a day.
  built=$("$ROOT/build/bin/ext4dump" version 2>/dev/null)
  head=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null)
  git -C "$ROOT" diff --quiet 2>/dev/null || head="$head-dirty"
  if [ -z "$built" ] || [ -z "$head" ]; then
    bad "ext4dump reports the revision it was built from" \
        "built='${built:-none}' head='${head:-unknown}'"
  elif [ "$built" = "$head" ]; then
    ok "ext4dump was built from the current tree ($built)"
  else
    bad "ext4dump was built from the current tree" \
        "binary says $built, tree is $head -- run: make tools"
  fi
else
  bad "ext4dump is not built" "run: make tools"
fi

# ---------------------------------------------------------- the extension --
# A reboot leaves the module unregistered -- absent from System Settings, not
# switched off -- until the containing app runs, because that is what registers
# an ExtensionKit extension. So try that once before reporting a problem: it is
# the difference between "your extension is gone" and a working session.
if ! bash "$ROOT/scripts/check_extension.sh" >/dev/null 2>&1; then
  if [ -d /Applications/Ext4Mac.app ]; then
    open -g -j -a /Applications/Ext4Mac.app 2>/dev/null || true
    sleep 4
  fi
fi

if bash "$ROOT/scripts/check_extension.sh" >/dev/null 2>&1; then
  ok "the FSKit extension is installed, enabled, and answers a mount"
  # Registered today is not registered tomorrow. Without the login item the
  # next reboot loses it again, and the failure looks like a broken install.
  if ! /Applications/Ext4Mac.app/Contents/MacOS/Ext4Mac login-item status >/dev/null 2>&1; then
    note "      (not set to start at login: the next reboot will unregister it."
    note "       fix once with: Ext4Mac login-item on)"
  fi
else
  bad "the FSKit extension is not enabled" \
      "System Settings > General > Login Items & Extensions > File System Extensions"
fi

# ---------------------------------------------------------------- freshness --
# Is the installed extension the build in this tree? A stale install runs the
# whole day and measures last week. Always strict here: preflight's whole job
# is refusing to lie.
if EXT4_REQUIRE_FRESH=1 bash "$ROOT/scripts/check_install_freshness.sh" >/dev/null 2>&1; then
  ok "the installed extension matches this tree's build"
else
  bad "the installed extension does not match this tree (or freshness cannot be checked)" \
      "run: make install   (then kill the running Ext4FS process so fskitd relaunches it)"
fi

# Real-media-only requirements, checked only when a device was named: image
# runs need neither, and blocking them on an unprimed sudo would gate offline
# work on a password.
if [ -n "$DEVICE" ]; then
  # Formatting real media routes through /Library/Filesystems/ext4.fs;
  # without it, prepare-device writes a partition type nothing claims.
  if [ -d "/Library/Filesystems/ext4.fs" ]; then
    ok "the ext4.fs bundle is installed"
  else
    bad "the ext4.fs bundle is missing" "run: sudo make install-diskutil"
  fi

  # The device suites need root mid-run; prompting for a password inside a
  # five-round sweep is how a run stalls unattended.
  if sudo -n true 2>/dev/null; then
    ok "sudo is pre-authorized"
  else
    bad "sudo is not pre-authorized" "run: sudo -v   (and keep the terminal open)"
  fi
fi

# ------------------------------------------------------- the only real test --
#
# Everything above says the parts are present. Mount the device and prove the
# driver owns it and takes a write.
if [ -n "$DEVICE" ]; then
  echo ""
  echo "  checking a live mount of $DEVICE"

  diskutil unmount "$DEVICE" >/dev/null 2>&1

  # Is it even ours? A device carrying some other filesystem mounts perfectly
  # well through that filesystem's driver and proves nothing about this one.
  # That happened, on a FAT32 stick, and the old check said everything was
  # ready.
  fs=$(diskutil info "$DEVICE" 2>/dev/null | sed -n 's/.*Type (Bundle): *//p' | head -1)
  if [ -n "$fs" ] && [ "$fs" != "ext4" ]; then
    bad "$DEVICE carries a $fs filesystem, not ext4" \
        "format it first, or point the check at an ext4 volume:"
    note "  sudo build/bin/ext4dump /dev/$DEVICE format 4"
    echo ""
    echo "$FAIL thing(s) not ready."
    exit 1
  fi

  if ! diskutil mount "$DEVICE" >/dev/null 2>&1; then
    bad "$DEVICE did not mount" \
        "$(diskutil mount "$DEVICE" 2>&1 | head -1)"
  else
    mp=$(mount | sed -n "s|^/dev/$DEVICE on \(.*\) (ext4.*|\1|p" | head -1)
    if [ -z "$mp" ]; then
      bad "$DEVICE mounted, but not as ext4" \
          "$(mount | grep "/dev/$DEVICE" | head -1)"
      diskutil unmount "$DEVICE" >/dev/null 2>&1
    elif mkdir -p "$mp/.preflight" 2>/dev/null \
         && echo x > "$mp/.preflight/f" 2>/dev/null; then
      sync; sleep 1
      rm -rf "$mp/.preflight" 2>/dev/null
      diskutil unmount "$DEVICE" >/dev/null 2>&1
      ok "this driver mounted $DEVICE read-write and took a write"
    else
      diskutil unmount "$DEVICE" >/dev/null 2>&1
      bad "$DEVICE mounted through this driver but refused a write" \
          "check the log: log show --last 2m --predicate 'subsystem == \"dev.h3ct0r.ext4\"' --info"
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
