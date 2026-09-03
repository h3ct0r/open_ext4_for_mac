#!/usr/bin/env bash
# Is the FSKit extension installed, approved, and answering?
#
# The failures here are opaque and inconsistent: a disabled module produces
# "Module ... is disabled!", or "Unable to invoke task", or exit 22 with no
# output at all, depending on which tool asked. Worse, `pluginkit` lists the
# module as present either way, and `pluginkit -e use` reports success without
# changing anything -- approval only happens in System Settings.
#
# A plain `make install` does NOT revoke approval -- that was measured. What
# does is any Info.plist change FSKit dislikes: the module is dropped from
# FSClient.installedExtensions, and when a later build restores it, it comes
# back unapproved.
set -uo pipefail

BUNDLE_ID="dev.h3ct0r.ext4mac.Ext4FS"
APP="/Applications/Ext4Mac.app"

step() { printf '  %-34s %s\n' "$1" "$2"; }

echo "ext4 FSKit extension"
echo

if [ ! -d "$APP" ]; then
    step "installed" "NO — $APP is missing"
    echo
    echo "  Build and install it:"
    echo "      make install SIGN_ID=\"Developer ID Application: ...\""
    exit 1
fi
step "installed" "yes ($APP)"

# pluginkit is not authoritative and misreports this badly: it happily lists
# the module with a "+" (enabled) while FSKit has dropped it entirely. The
# container app asks FSClient.installedExtensions, which is the same source
# System Settings uses.
# `status` explicitly. Without an argument the binary decides for itself
# whether it was opened from Finder, and a script has no business relying on
# that guess -- an earlier version of it launched the menu-bar agent here and
# this line never returned.
status=$("$APP/Contents/MacOS/Ext4Mac" status 2>/dev/null | sed -n 's/^status: //p')

case "$status" in
    "")
        step "known to FSKit" "cannot tell — the container app printed nothing"
        exit 1
        ;;
    *"not registered"*)
        step "known to FSKit" "NO"
        echo
        echo "  FSKit does not list this module, so it will not appear in"
        echo "  System Settings at all and every mount fails with"
        echo "  \"Unable to invoke task\"."
        echo
        echo "  The usual cause is Extension/Info.plist: FSKit silently drops a"
        echo "  module whose manifest it dislikes. FSSupportsKernelOffloadedIO"
        echo "  must be present and true -- both <false/> and omitting it"
        echo "  deregister the module."
        exit 1
        ;;
esac
step "known to FSKit" "yes"
step "FSKit status" "$status"

# The only trustworthy test is to ask it to do something. A scratch image
# avoids touching any real disk.
work=$(mktemp -d)

# The extension does not always release the device the moment umount returns,
# so a detach issued immediately after can lose that race and fail. That
# failure used to be swallowed, and the backing file was deleted anyway --
# which turns a transient failure into an attached image pointing at a file
# that no longer exists, visible in `diskutil list` forever and cleanable only
# by hand. One such PROBE device was found still attached days later.
#
# So: retry, and if it still will not detach, keep the backing file and say
# what to run. A leak that announces itself can be cleaned up; a silent one
# accumulates.
cleanup() {
    umount "$work/mnt" 2>/dev/null
    if [ -n "${dev:-}" ]; then
        for _ in 1 2 3 4 5; do
            if hdiutil detach "$dev" -force >/dev/null 2>&1; then
                dev=""
                break
            fi
            sleep 1
        done
        if [ -n "${dev:-}" ]; then
            echo "  note: $dev is still attached (detach lost the race)."
            echo "        run: hdiutil detach $dev -force"
            echo "        backing file kept: $work/probe.img"
            return 0
        fi
    fi
    rm -rf "$work"
}
trap cleanup EXIT

export PATH="/opt/homebrew/opt/e2fsprogs/sbin:/opt/homebrew/opt/e2fsprogs/bin:$PATH"
if ! command -v mke2fs >/dev/null; then
    step "answering" "cannot tell — mke2fs not found (brew install e2fsprogs)"
    exit 1
fi

dd if=/dev/zero of="$work/probe.img" bs=1M count=16 2>/dev/null
mke2fs -q -t ext4 -L PROBE -F "$work/probe.img" 2>/dev/null
dev=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount "$work/probe.img" \
      | head -1 | awk '{print $1}')
mkdir -p "$work/mnt"

out=$(mount -F -t ext4 "${dev#/dev/}" "$work/mnt" 2>&1)
if mount | grep -q "$work/mnt"; then
    umount "$work/mnt" 2>/dev/null
    step "enabled and answering" "YES"
    echo
    echo "  Everything is ready."
    exit 0
fi

step "enabled and answering" "NO"
echo "  mount said: $out"
echo
echo "  Turn it on:"
echo "      System Settings > General > Login Items & Extensions"
echo "        > File System Extensions  ->  open_ext4 (ext2/3/4)"
echo
echo "  Note: installing the app does not enable the extension. A plain"
echo "  reinstall keeps an existing approval; a manifest change that"
echo "  deregisters the module loses it. pluginkit cannot grant approval."
exit 1
