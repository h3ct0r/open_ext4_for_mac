#!/usr/bin/env bash
# Everything an install leaves behind, in the order it has to go.
#
#   DRY_RUN=1 bash scripts/uninstall.sh           # names every step: "would: ..."
#   EXT4_UNINSTALL_FOR_REAL=1 bash scripts/uninstall.sh   # does it
#
# Without either it refuses, because a script that deletes an application, a
# container full of keys and a system filesystem bundle should not run by
# accident. The dry run is what Tests/run_uninstall_tests.sh checks: every
# path below has to be named, so an artifact added to the install and not to
# this list is a red cell rather than a leftover.
#
# What it cannot do: the approval toggle in System Settings > General > Login
# Items & Extensions > File System Extensions is the user's, and no command
# resets it. After this runs the entry disappears from that list on its own
# once the app is gone; nothing here needs to touch it.
set -uo pipefail

DRY_RUN="${DRY_RUN:-}"
REAL="${EXT4_UNINSTALL_FOR_REAL:-}"
APP=/Applications/Ext4Mac.app
BIN="$APP/Contents/MacOS/Ext4Mac"
APPEX="$APP/Contents/Extensions/Ext4FS.appex"
EXT_CONTAINER="$HOME/Library/Containers/dev.h3ct0r.ext4mac.Ext4FS"
APP_CONTAINER="$HOME/Library/Containers/dev.h3ct0r.ext4mac"
FS_BUNDLE=/Library/Filesystems/ext4.fs
BARRIER_PLIST=/Library/LaunchDaemons/dev.h3ct0r.ext4mac.barrier.plist
BARRIER_PROGRAM=/Library/PrivilegedHelperTools/ext4barrierd
BARRIER_OLD=/usr/local/libexec/ext4barrierd

if [ -z "$DRY_RUN" ] && [ -z "$REAL" ]; then
  echo "refusing to uninstall without being told twice."
  echo "  DRY_RUN=1 bash scripts/uninstall.sh            shows what would go"
  echo "  EXT4_UNINSTALL_FOR_REAL=1 bash scripts/uninstall.sh   removes it"
  exit 2
fi

step() {  # step <description> <command...>
  local what="$1"; shift
  if [ -n "$DRY_RUN" ]; then
    echo "would: $what"
    return 0
  fi
  echo "doing: $what"
  "$@" || echo "       (that step reported a failure; continuing)"
}
sudo_step() {  # sudo_step <description> <command...>  -- a root step
  local what="$1"; shift
  if [ -n "$DRY_RUN" ]; then
    echo "would (as root): $what"
    return 0
  fi
  echo "doing (as root): $what"
  sudo "$@" || echo "       (that step reported a failure; continuing)"
}

echo "ext4 for macOS: uninstall${DRY_RUN:+ (dry run)}"
echo ""

# 1. Nothing mounted through the driver may be in use while it goes.
eject_ext_volumes() {
  mount | awk '/\(ext4|\(ext3|\(ext2|fskit/ && /ext[234]/ {print $3}' | while read -r mp; do
    diskutil unmount "$mp" >/dev/null 2>&1 || diskutil unmount force "$mp" >/dev/null 2>&1 || true
  done
}
step "eject every ext2/3/4 volume the driver has mounted" eject_ext_volumes

# 2. The login item is what keeps the extension registered across reboots.
step "turn the login item off: $BIN login-item off" \
  bash -c "[ -x '$BIN' ] && '$BIN' login-item off || true"

# 3. Key material, both stores, with the verifying verb. --yes because this
#    script is the confirmation.
step "forget every stored LUKS key: $BIN forget --all --yes" \
  bash -c "[ -x '$BIN' ] && '$BIN' forget --all --yes || true"

# 4. Deregister the appex. pluginkit does not register an ExtensionKit
#    extension, but it does list and remove one, and a stale registration is
#    how a deleted module keeps appearing in System Settings.
step "deregister the extension: pluginkit -r $APPEX" \
  bash -c "[ -d '$APPEX' ] && pluginkit -r '$APPEX' 2>/dev/null || true"

# 5. The application, and with it the extension inside it.
step "remove $APP" rm -rf "$APP"

# 6. The extension's container: cached keys, exported headers, volume events.
step "remove the extension's container $EXT_CONTAINER" rm -rf "$EXT_CONTAINER"

# 7. The app's own container, if one was made.
step "remove the app's container $APP_CONTAINER" rm -rf "$APP_CONTAINER"

# 8. Preferences.
step "remove preferences: defaults delete dev.h3ct0r.ext4mac" \
  bash -c "defaults delete dev.h3ct0r.ext4mac 2>/dev/null; defaults delete dev.h3ct0r.ext4mac.luks 2>/dev/null; true"

# 9. The diskutil-facing bundle, which is root's.
sudo_step "remove $FS_BUNDLE" rm -rf "$FS_BUNDLE"

# 10. Remnants of the retired barrier daemon, if this machine ever had it.
sudo_step "remove the retired barrier daemon: $BARRIER_PLIST, $BARRIER_PROGRAM, $BARRIER_OLD" \
  bash -c "launchctl bootout system '$BARRIER_PLIST' 2>/dev/null; rm -f '$BARRIER_PLIST' '$BARRIER_PROGRAM' '$BARRIER_OLD'; true"

echo ""
echo "not done, because it cannot be: the approval toggle in System Settings >"
echo "General > Login Items & Extensions is yours; the entry disappears once the"
echo "app is gone."
