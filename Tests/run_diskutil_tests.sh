#!/usr/bin/env bash
# Can Disk Utility erase a real disk as ext4, with nothing asked of the user?
#
# Until now it could not. `storagekitd` runs a .fs bundle's formatter as root,
# and ours -- Packaging/ext4.fs/Contents/Resources/newfs_ext4 -- gives that root
# away: FSKit module enablement is per user, so the wrapper re-dispatches to the
# console user with `launchctl asuser` + `sudo`. But newfs_fskit opens the device
# in its own process, and a physical disk's node is root:operator mode 0640, so
# the open returns EACCES before this driver is ever asked. Disk Utility says
# "File system formatter failed (-69832)"; the log says errno 13.
#
# The difference between a disk image (works) and a physical disk (fails) is
# exactly the ownership of the device node, so the whole failure is reproducible
# here on an image whose nodes have been chowned to root:operator. Those cells
# need root and skip without a cached sudo credential; everything else runs
# unattended.
#
# Two layers on purpose. The cells that run OUR wrapper out of the tree test the
# code being changed. The cells that go through `diskutil eraseVolume` test what
# is installed in /Library/Filesystems, which is a different file and can be
# older than this tree.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/Tests/lib.sh"

BUNDLE="$ROOT/Packaging/ext4.fs"
NEWFS="$BUNDLE/Contents/Resources/newfs_ext4"
FSCK="$BUNDLE/Contents/Resources/fsck_ext4"
INSTALLED="/Library/Filesystems/ext4.fs"
DUMP="$ROOT/build/bin/ext4dump"
WORK="$ROOT/build/diskutil"
rm -rf "$WORK"; mkdir -p "$WORK"

case "$(uname -s)" in
  Darwin) ;;
  *) echo "macOS only (needs diskutil and hdiutil)"; echo "SKIPPED"; exit 77 ;;
esac

echo "########## DISK UTILITY ##########"
echo ""

# Every device this suite attaches, detached on the way out whatever happens.
# A leaked image survives the run; a failed cell does not.
ATTACHED=()
cleanup() {
  for dev in ${ATTACHED[@]+"${ATTACHED[@]}"}; do
    diskutil unmountDisk force "$dev" >/dev/null 2>&1
    for _ in 1 2 3 4 5; do
      hdiutil detach "$dev" -force >/dev/null 2>&1 && break
      sleep 1
    done
  done
  return 0
}
trap cleanup EXIT

# Sets DEV; it does NOT echo the device. A function whose output is captured
# runs in a subshell, so the ATTACHED entry it appends is lost the moment it
# returns -- which left five copies of one image attached to this machine, one
# of them pointing at a backing file the next run had already deleted. Exactly
# the leak scripts/check_extension.sh has retried against since 2026.
DEV=""
attach() {  # attach <img> -> sets DEV
  DEV=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount "$1" 2>/dev/null \
        | awk '/^\/dev\/disk/ { print $1; exit }')
  [ -n "$DEV" ] || return 1
  ATTACHED+=("$DEV")
  return 0
}

blank() {  # blank <name> <MiB> -> echoes the image path
  local img="$WORK/$1.img"
  dd if=/dev/zero of="$img" bs=1m count="$2" 2>/dev/null
  echo "$img"
}

owner() { /usr/bin/stat -f '%Su:%Sg' "$1" 2>/dev/null; }

# --------------------------------------------------------------- offline --
echo "the two wrappers, as files"
echo ""

out=$("$NEWFS" --wat /dev/disk99 2>&1); rc=$?
[ "$rc" -ne 0 ] && grep -qi "unsupported option" <<<"$out" \
  && ok "the formatter refuses an unknown option instead of dropping it" \
  || bad "the formatter refuses an unknown option instead of dropping it" "rc=$rc"

# The dispatch is the part that decides whether a format can reach the device
# at all, and it has to be identical in both wrappers. Marker-delimited and
# diffed, so the checker cannot quietly keep the broken version.
extract() {  # extract <file> -> the marked block
  awk '/# >>> ext4.fs dispatch/ { p = 1 } p { print } /# <<< ext4.fs dispatch/ { p = 0 }' "$1"
}
n_block=$(extract "$NEWFS"); f_block=$(extract "$FSCK")
if [ -n "$n_block" ] && [ -n "$f_block" ]; then
  ok "both wrappers carry a marked dispatch block"
  [ "$n_block" = "$f_block" ] \
    && ok "and the two blocks are identical, so they cannot drift" \
    || bad "and the two blocks are identical, so they cannot drift" \
           "$(diff <(echo "$n_block") <(echo "$f_block") | head -3 | tr '\n' '|')"
else
  bad "both wrappers carry a marked dispatch block" \
      "newfs: $(wc -l <<<"$n_block") lines, fsck: $(wc -l <<<"$f_block") lines"
  bad "and the two blocks are identical, so they cannot drift" "no blocks to compare"
fi

# The mechanism this rests on: newfs_fskit changes its REAL uid to $SUDO_UID
# when it is root, keeping the effective uid, so one process can both find a
# per-user module and open a root-owned device. If a macOS update removes it,
# this cell is where that shows up rather than in a user's failed erase.
if strings /sbin/newfs_fskit 2>/dev/null | grep -q "SUDO_UID" \
   && nm -u /sbin/newfs_fskit 2>/dev/null | grep -q "_setreuid"; then
  ok "newfs_fskit still reads SUDO_UID and calls setreuid"
else
  bad "newfs_fskit still reads SUDO_UID and calls setreuid" \
      "the dispatch below depends on it; macOS may have changed"
fi

if plutil -p "$BUNDLE/Contents/Info.plist" | grep -q '"FSFormatExecutable" => "newfs_ext4"' \
   && plutil -p "$BUNDLE/Contents/Info.plist" | grep -q '"FSRepairExecutable" => "fsck_ext4"'; then
  ok "the plist still names both wrappers"
else
  bad "the plist still names both wrappers"
fi
[ -x "$NEWFS" ] && [ -x "$FSCK" ] \
  && ok "and both are executable in the tree" \
  || bad "and both are executable in the tree"

# The installed bundle is a different file from this tree's, and a stale one
# makes a fixed tree look broken.
if [ -d "$INSTALLED" ]; then
  if diff -r "$BUNDLE/Contents/Resources" "$INSTALLED/Contents/Resources" >/dev/null 2>&1; then
    ok "the installed bundle matches this tree"
  else
    bad "the installed bundle matches this tree" \
        "run: sudo make install-diskutil (or update it from the Setup Assistant)"
  fi
fi

# ------------------------------------------------------------ the images --
echo ""
echo "an image erased through Disk Utility's own path"
echo ""

if [ ! -d "$INSTALLED" ]; then
  echo "  (skipped: /Library/Filesystems/ext4.fs is not installed)"
elif ! bash "$ROOT/scripts/check_extension.sh" >/dev/null 2>&1; then
  echo "  (skipped: the FSKit extension is not installed and enabled)"
else
  img=$(blank plain 64)
  attach "$img" || DEV=""
  dev="$DEV"
  if [ -z "$dev" ]; then
    bad "an image can be erased as ext4 by diskutil" "could not attach the image"
  else
    out=$(run_deadline 180 diskutil eraseVolume EXT4 SUITEPLAIN "$dev" 2>&1); rc=$?
    if [ "$rc" -eq 0 ] && grep -qi "finished erase" <<<"$out"; then
      ok "an image can be erased as ext4 by diskutil (the path that already worked)"
    else
      bad "an image can be erased as ext4 by diskutil" \
          "rc=$rc: $(grep -iE 'error|fail|denied' <<<"$out" | head -1)"
    fi
    diskutil unmountDisk "$dev" >/dev/null 2>&1
    if [ -x "$DUMP" ]; then
      "$DUMP" "$dev" probe 2>/dev/null | grep -q "^verdict: *USABLE" \
        && ok "and the volume it wrote is one this driver will mount" \
        || bad "and the volume it wrote is one this driver will mount"
    fi
  fi
fi

# ------------------------------------------------------- the real thing --
echo ""
echo "a device node owned by root, which is what a physical disk is"
echo ""

if ! sudo -n true 2>/dev/null; then
  echo "  (root cells skipped: no cached sudo credential. Run 'sudo -v' first,"
  echo "   then this suite, to exercise the physical-disk case.)"
else
  img=$(blank rootowned 64)
  attach "$img" || DEV=""
  dev="$DEV"
  if [ -z "$dev" ]; then
    bad "the physical-disk case can be reproduced" "could not attach the image"
  else
    raw="${dev/disk/rdisk}"
    sudo chown root:operator "$dev" "$raw"
    sudo chmod 640 "$dev" "$raw"
    before="$(owner "$dev")"

    if [ "$before" = "root:operator" ]; then
      ok "the image's nodes now look exactly like a physical disk's ($before)"
    else
      bad "the image's nodes now look exactly like a physical disk's" "$before"
    fi

    # THE CELL. Our own formatter, run as root the way storagekitd runs it.
    out=$(sudo "$NEWFS" -4 -v SUITEROOT "$dev" 2>&1); rc=$?
    if [ "$rc" -eq 0 ]; then
      ok "our formatter writes ext4 to a root-owned node (rc=0)"
    else
      bad "our formatter writes ext4 to a root-owned node" \
          "rc=$rc: $(grep -iE 'denied|error|failed|extension' <<<"$out" | head -1)"
    fi

    # And it does it WITHOUT changing anything about the device. An earlier
    # design lent the node to the console user and handed it back; this one
    # never touches it, and that is worth asserting rather than assuming.
    if [ "$(owner "$dev")" = "root:operator" ] && [ "$(owner "$raw")" = "root:operator" ]; then
      ok "and the node's ownership is untouched ($(owner "$dev"))"
    else
      bad "and the node's ownership is untouched" \
          "$(owner "$dev") / $(owner "$raw") -- something changed it and did not put it back"
    fi

    if [ "$rc" -eq 0 ] && [ -x "$DUMP" ]; then
      sudo "$DUMP" "$dev" probe 2>/dev/null | grep -q "^verdict: *USABLE" \
        && ok "and what it wrote is a volume this driver will mount" \
        || bad "and what it wrote is a volume this driver will mount"
    fi

    # The negative control: why it works. Without SUDO_UID, fskitd looks up
    # root's enabled modules, root has none, and the format fails on the
    # module rather than on the device. If this cell ever goes green, the
    # dispatch is no longer doing anything and the next macOS could break it
    # silently.
    out=$(sudo /usr/bin/env -u SUDO_UID /sbin/newfs_fskit -t ext4 "$dev" 2>&1); rc2=$?
    # It must fail, and it must fail on the MODULE, not on the device: pure
    # root can open the node perfectly well, it just has no enabled FSKit
    # module to hand the job to. A permission error here would mean the
    # effective uid is not what this rests on. (Observed: rc 22, EINVAL, with
    # nothing on stderr -- newfs_fskit does not always name the reason.)
    if [ "$rc2" -ne 0 ] && ! grep -qi "denied" <<<"$out"; then
      ok "and without SUDO_UID the same tool cannot format at all (the control, rc=$rc2)"
    else
      bad "and without SUDO_UID the same tool cannot format at all (the control)" \
          "rc=$rc2: $(head -1 <<<"$out")"
    fi

    # First Aid takes the same road and has the same problem: the console user
    # cannot even read a root:operator node.
    out=$(sudo "$FSCK" -n "$dev" 2>&1); rc=$?
    if ! grep -qi "denied" <<<"$out"; then
      ok "the checker reaches the volume instead of failing on open"
    else
      bad "the checker reaches the volume instead of failing on open" \
          "$(grep -i denied <<<"$out" | head -1)"
    fi
    [ "$(owner "$dev")" = "root:operator" ] \
      && ok "and it leaves the node's ownership alone too" \
      || bad "and it leaves the node's ownership alone too" "$(owner "$dev")"
  fi
fi

echo ""
echo "─────────────────────────────────"
finish
