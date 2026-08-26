#!/usr/bin/env bash
# Encrypted volumes against the *mounted* FSKit driver.
#
# Tests/run_luks_tests.sh proves the crypto layer offline, through ext4dump on
# a plain file. That says nothing about the path a real mount takes: the
# decrypting device is rebuilt inside a sandboxed extension, on top of
# FSBlockDeviceResource, driven by the kernel's VFS. This suite tests that.
#
# The oracle is never our own reader. Fixtures are made by real cryptsetup, and
# everything macOS writes is handed back to `cryptsetup luksOpen` and the Linux
# kernel to read -- because a decryption bug that is wrong the same way in both
# directions passes every test run against itself.
#
#   stage 1  recognition   a locked container is claimed, not declined
#   stage 2  refusal       no key means a clean EAUTH, and no writes
#   stage 3  LUKS1/512     read what Linux wrote, write it back for Linux
#   stage 4  LUKS2/4096    the same, through argon2id and 4096-byte sectors
#   stage 5  the whole flow unlock in the container app, mount, forget
#
# Stage 4 exists for one bug in particular. With a 4096-byte encryption sector,
# dm-crypt still counts the XTS tweak in 512-byte units; getting that wrong
# still decrypts sector 0 correctly, so the volume mounts and its label reads
# while every other byte is garbage. Only a file large enough to span many
# sectors catches it, which is why a 400 KB payload is compared byte-for-byte.
#
# Needs the extension signed, installed and enabled, plus Docker. Runs
# unattended. Writes a report to build/mount-luks-report.txt.
set -uo pipefail

export PATH="/opt/homebrew/opt/e2fsprogs/sbin:/opt/homebrew/opt/e2fsprogs/bin:$PATH"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/build/mount-luks"
REPORT="$ROOT/build/mount-luks-report.txt"
MNT="/tmp/ext4-mount-luks"
DOCKER_IMAGE="ext4luks:cryptsetup-attr"

BUNDLE_ID="dev.h3ct0r.ext4mac.Ext4FS"
# Where the extension looks for a passphrase. Inside its sandbox this is
# .applicationSupportDirectory; from out here it is a path under the container.
KEYDIR="$HOME/Library/Containers/$BUNDLE_ID/Data/Library/Application Support/luks"

PASSPHRASE="correct horse battery staple"

PASS=0; FAIL=0
note() { echo "$*" | tee -a "$REPORT"; }
ok()   { PASS=$((PASS+1)); note "  ok    $1"; }
# Must end in a success status; see the note in run_mount_crash_tests.sh.
bad()  { FAIL=$((FAIL+1)); note "  FAIL  $1"; [ $# -gt 1 ] && note "        $2"; return 0; }

DEV=""
PLACED_KEYS=()
UUID1=""
UUID2=""

cleanup() {
  umount "$MNT" 2>/dev/null
  [ -n "$DEV" ] && hdiutil detach "$DEV" -force >/dev/null 2>&1
  # Never leave a passphrase behind in the extension's container.
  for k in "${PLACED_KEYS[@]:-}"; do [ -n "$k" ] && rm -f "$KEYDIR/$k".*; done
  # And anything the app stored, wherever it put it.
  APP="/Applications/Ext4Mac.app/Contents/MacOS/Ext4Mac"
  for u in "${UUID1:-}" "${UUID2:-}"; do
    [ -n "$u" ] && { rm -f "$KEYDIR/$u".*; [ -x "$APP" ] && "$APP" forget "$u" >/dev/null 2>&1; }
  done
  rmdir "$KEYDIR" 2>/dev/null
  return 0
}
trap cleanup EXIT

# ------------------------------------------------------------ preflight ----
if ! docker info >/dev/null 2>&1; then
  echo "docker is not running; cryptsetup is the only way to make a LUKS fixture"
  echo "SKIPPED"; exit 77
fi
if ! bash "$ROOT/scripts/check_extension.sh" >/dev/null 2>&1; then
  echo "the FSKit extension is not enabled; see scripts/check_extension.sh"
  echo "SKIPPED"; exit 77
fi

rm -rf "$WORK"; mkdir -p "$WORK" "$KEYDIR"; mkdir -p "$MNT"
: > "$REPORT"

if ! docker image inspect "$DOCKER_IMAGE" >/dev/null 2>&1; then
  echo "building $DOCKER_IMAGE (one-off, needs network)"
  docker build -q -t "$DOCKER_IMAGE" - >/dev/null <<'DOCKERFILE'
FROM debian:stable-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    cryptsetup-bin e2fsprogs attr && rm -rf /var/lib/apt/lists/*
DOCKERFILE
fi

in_linux() { docker run --rm --privileged -v "$WORK:/w" "$DOCKER_IMAGE" bash -c "$1"; }

printf '%s' "$PASSPHRASE" > "$WORK/pass.txt"

note "########## ENCRYPTED VOLUMES, MOUNTED ##########"
note ""
note "building fixtures with real cryptsetup"

in_linux '
set -e
mk() {  # mk <name> <mb> <luksFormat args...>
  local name="$1" mb="$2"; shift 2
  dd if=/dev/zero of=/w/$name.img bs=1M count=$mb status=none
  cryptsetup luksFormat --batch-mode --key-file /w/pass.txt "$@" /w/$name.img
  cryptsetup luksOpen --key-file /w/pass.txt /w/$name.img $name
  mkfs.ext4 -q -L ${name^^} /dev/mapper/$name
  mkdir -p /mnt/$name && mount /dev/mapper/$name /mnt/$name
  echo -n "written by linux inside $name" > /mnt/$name/hello.txt
  dd if=/dev/urandom of=/mnt/$name/wide.bin bs=1k count=400 status=none
  sha256sum /mnt/$name/wide.bin | cut -d" " -f1 > /w/$name.wide.sha
  sync; umount /mnt/$name; cryptsetup luksClose $name
  cryptsetup luksUUID /w/$name.img > /w/$name.uuid
  chmod 666 /w/$name.img
}
mk luks1 64 --type luks1
mk luks2 96 --type luks2 --sector-size 4096
' >/dev/null 2>&1 || { note "  fixtures were not built"; exit 1; }

[ -f "$WORK/luks1.img" ] || { note "  fixtures were not built"; exit 1; }
note ""

place_key() {  # place_key <uuid>
  printf '%s' "$PASSPHRASE" > "$KEYDIR/$1.pass"
  PLACED_KEYS+=("$1")
}

attach() {  # attach <img> -> sets DEV
  DEV=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount "$1" 2>/dev/null \
        | head -1 | awk '{print $1}')
  [ -n "$DEV" ]
}

# --------------------------------------------------- stage 1: recognition --
note "stage 1: a locked container is recognised"

UUID1=$(tr -d '\r\n' < "$WORK/luks1.uuid")
UUID2=$(tr -d '\r\n' < "$WORK/luks2.uuid")

attach "$WORK/luks1.img" || { note "  could not attach"; exit 1; }
NAME=$(diskutil info "$DEV" 2>/dev/null | sed -n 's/.*Volume Name: *//p' | head -1)
case "$NAME" in
  *"LUKS1 Encrypted Volume"*) ok "claimed as \"$NAME\"" ;;
  *) bad "locked LUKS1 container not claimed" "diskutil says: ${NAME:-<nothing>}" ;;
esac

# ------------------------------------------------------ stage 2: refusal --
note ""
note "stage 2: without a key it refuses, and changes nothing"

# The two refusals are deliberately different errors, because they are
# different problems: nobody has unlocked this volume yet (ENEEDAUTH, "Need
# authenticator") versus what was offered does not open it (EAUTH,
# "Authentication error"). Collapsing them would leave someone retyping a
# passphrase that was never going to be consulted.
BEFORE=$(shasum -a 256 "$WORK/luks1.img" | cut -d' ' -f1)
OUT=$(mount -F -t ext4 "${DEV#/dev/}" "$MNT" 2>&1)
case "$OUT" in
  *"Need authenticator"*) ok "mount without a key fails with ENEEDAUTH" ;;
  *) bad "mount without a key did not report ENEEDAUTH" "$OUT" ;;
esac
mount | grep -q "$MNT " && bad "volume mounted without a key" || ok "nothing was mounted"

# A wrong passphrase must be refused just as cleanly, and distinguishably.
printf '%s' "not the passphrase" > "$KEYDIR/$UUID1.pass"; PLACED_KEYS+=("$UUID1")
OUT=$(mount -F -t ext4 "${DEV#/dev/}" "$MNT" 2>&1)
case "$OUT" in
  *"Authentication error"*) ok "a wrong passphrase fails with EAUTH, not ENEEDAUTH" ;;
  *) bad "a wrong passphrase did not report EAUTH" "$OUT" ;;
esac

# A refusal must not wedge the device: FSKit holds a resource for as long as an
# extension instance owns it, and a load that fails halfway leaves every later
# probe of the same media reporting "Resource busy" -- through a detach and
# re-attach both. This is the check that catches that regression.
OUT=$(mount -F -t ext4 "${DEV#/dev/}" "$MNT" 2>&1)
case "$OUT" in
  *"Resource busy"*) bad "a refused mount left the resource held" "$OUT" ;;
  *) ok "the device is still usable after two refusals" ;;
esac

AFTER=$(shasum -a 256 "$WORK/luks1.img" | cut -d' ' -f1)
[ "$BEFORE" = "$AFTER" ] && ok "the container is byte-identical after both refusals" \
                         || bad "a refused mount modified the container"

hdiutil detach "$DEV" -force >/dev/null 2>&1; DEV=""

# ------------------------------------------ stages 3 and 4: the round trip --
round_trip() {  # round_trip <name> <uuid> <label>
  local name="$1" uuid="$2" label="$3"
  note ""
  note "$label"

  place_key "$uuid"
  attach "$WORK/$name.img" || { bad "could not attach $name"; return 0; }

  if ! mount -F -t ext4 "${DEV#/dev/}" "$MNT" 2>/dev/null; then
    bad "$name did not mount"
    hdiutil detach "$DEV" -force >/dev/null 2>&1; DEV=""
    return 0
  fi
  ok "mounted"

  # What Linux wrote, read through the cipher.
  local got want
  got=$(cat "$MNT/hello.txt" 2>/dev/null)
  [ "$got" = "written by linux inside $name" ] \
    && ok "small file matches what Linux wrote" \
    || bad "small file differs" "got: $got"

  want=$(cat "$WORK/$name.wide.sha")
  got=$(shasum -a 256 "$MNT/wide.bin" 2>/dev/null | cut -d' ' -f1)
  [ "$got" = "$want" ] \
    && ok "400 KB file is byte-identical across many sectors" \
    || bad "400 KB file differs -- the XTS tweak is wrong past sector 0" \
           "want $want, got $got"

  # Now write, for Linux to check.
  mkdir -p "$MNT/from-macos/nested" 2>/dev/null
  echo -n "written by macos inside $name" > "$MNT/from-macos/nested/mac.txt"
  ln -s /nested/mac.txt "$MNT/from-macos/link" 2>/dev/null
  xattr -w user.macos encrypted "$MNT/from-macos/nested/mac.txt" 2>/dev/null
  dd if=/dev/urandom of="$MNT/from-macos/blob.bin" bs=1k count=700 status=none 2>/dev/null
  want=$(shasum -a 256 "$MNT/from-macos/blob.bin" | cut -d' ' -f1)

  umount "$MNT" 2>/dev/null || bad "$name did not unmount cleanly"
  hdiutil detach "$DEV" -force >/dev/null 2>&1; DEV=""

  # The oracle: real cryptsetup and the real kernel.
  local out
  out=$(in_linux "
    dmesg -C >/dev/null 2>&1
    cryptsetup luksOpen --key-file /w/pass.txt /w/$name.img v || exit 1
    e2fsck -fn /dev/mapper/v > /w/$name.fsck 2>&1; echo \"FSCK=\$?\"
    mkdir -p /mnt/v && mount /dev/mapper/v /mnt/v || exit 1
    echo \"TXT=\$(cat /mnt/v/from-macos/nested/mac.txt)\"
    echo \"LINK=\$(readlink /mnt/v/from-macos/link)\"
    echo \"XATTR=\$(getfattr -n user.macos --only-values /mnt/v/from-macos/nested/mac.txt 2>/dev/null)\"
    echo \"SHA=\$(sha256sum /mnt/v/from-macos/blob.bin | cut -d' ' -f1)\"
    umount /mnt/v; cryptsetup luksClose v
    echo \"DMESG=\$(dmesg 2>/dev/null | grep -icE 'EXT4-fs (error|warning)|I/O error')\"
  " 2>/dev/null)

  grep -q "FSCK=0" <<<"$out" && ok "e2fsck is clean, with no journal replay" \
                             || bad "e2fsck is not clean" "$(tail -5 "$WORK/$name.fsck" 2>/dev/null)"
  grep -q "TXT=written by macos inside $name" <<<"$out" \
    && ok "Linux reads back the file macOS wrote" || bad "file content differs on Linux" "$out"
  grep -q "LINK=/nested/mac.txt" <<<"$out" && ok "symlink survives" || bad "symlink differs"
  grep -q "XATTR=encrypted" <<<"$out" && ok "xattr survives" || bad "xattr differs"
  grep -q "SHA=$want" <<<"$out" \
    && ok "700 KB written by macOS is byte-identical on Linux" \
    || bad "700 KB payload differs on Linux" "want $want"
  grep -q "DMESG=0" <<<"$out" && ok "the kernel logged no complaints" \
                              || bad "the kernel complained about the volume"
}

round_trip luks1 "$UUID1" "stage 3: LUKS1, 512-byte sectors, PBKDF2"
round_trip luks2 "$UUID2" "stage 4: LUKS2, 4096-byte sectors, argon2id"

# ------------------------------------------------- stage 5: the whole flow --
# What a person actually does: unlock once in the app, mount, forget. The app
# is the only place a passphrase is ever typed, and the only place that can
# afford argon2id -- FSKit loads a resource twice per mount, in two separate
# extension processes, so deriving there costs the derivation twice.
note ""
note "stage 5: unlock in the container app, mount, forget"

APP="/Applications/Ext4Mac.app/Contents/MacOS/Ext4Mac"
if [ ! -x "$APP" ]; then
  note "  skipped: Ext4Mac is not installed in /Applications"
else
  # Start from nothing: no passphrase file, no stored key.
  rm -f "$KEYDIR/$UUID2".* 2>/dev/null
  "$APP" forget "$UUID2" >/dev/null 2>&1

  attach "$WORK/luks2.img" || bad "could not attach for the app flow"

  OUT=$(mount -F -t ext4 "${DEV#/dev/}" "$MNT" 2>&1)
  case "$OUT" in
    *"Need authenticator"*) ok "locked before the app is used" ;;
    *) bad "a volume with no key did not report ENEEDAUTH" "$OUT" ;;
  esac

  if printf '%s\n' "$PASSPHRASE" | "$APP" unlock "$DEV" >/dev/null 2>&1; then
    ok "the app unlocked the container"
  else
    bad "the app could not unlock the container"
  fi

  # The mount must now be immediate: the key is already derived, so nothing
  # here should be running argon2id again.
  START=$SECONDS
  if mount -F -t ext4 "${DEV#/dev/}" "$MNT" 2>/dev/null; then
    ELAPSED=$(( SECONDS - START ))
    ok "mounted with the key the app stored"
    [ "$ELAPSED" -le 2 ] && ok "mount was immediate (${ELAPSED}s: no derivation)" \
                         || bad "mount took ${ELAPSED}s -- the key was derived again"
    want=$(cat "$WORK/luks2.wide.sha")
    got=$(shasum -a 256 "$MNT/wide.bin" 2>/dev/null | cut -d' ' -f1)
    [ "$got" = "$want" ] && ok "contents are correct through the stored key" \
                         || bad "contents differ through the stored key"
    umount "$MNT" 2>/dev/null
  else
    bad "could not mount with the key the app stored"
  fi

  "$APP" forget "$UUID2" >/dev/null 2>&1
  OUT=$(mount -F -t ext4 "${DEV#/dev/}" "$MNT" 2>&1)
  case "$OUT" in
    *"Need authenticator"*) ok "locked again after forget" ;;
    *) bad "the volume still mounted after forget" "$OUT" ;;
  esac

  hdiutil detach "$DEV" -force >/dev/null 2>&1; DEV=""
fi

note ""
note "─────────────────────────────────"
note "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
