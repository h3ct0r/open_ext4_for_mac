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

# ---------------------------------------------------------- the extension --
if bash "$ROOT/scripts/check_extension.sh" >/dev/null 2>&1; then
  ok "the FSKit extension is installed and enabled"
else
  bad "the FSKit extension is not enabled" \
      "System Settings > General > Login Items & Extensions > File System Extensions"
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
