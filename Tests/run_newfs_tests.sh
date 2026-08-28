#!/usr/bin/env bash
# newfs_fskit and fsck_fskit against the live extension.
#
# This is the one path where macOS itself drives our formatter: fskitd loads
# the resource, hands startFormat a task, and the module builds the volume.
# The offline format suite proves what lands on disk; this proves the road to
# it -- which was broken for most of the project's history by our own
# loadResource refusing the unformatted media a format begins with.
#
# Needs the extension installed and enabled. The mounted suites' gate applies.
set -uo pipefail
export PATH="/opt/homebrew/opt/e2fsprogs/sbin:/opt/homebrew/opt/e2fsprogs/bin:$PATH"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/build/newfs"
IMG="$WORK/newfs.img"
MNT="/tmp/ext4-newfs-test"
DEV=""

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok    $*"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $*"; shift; [ $# -gt 0 ] && echo "        $*"; }

cleanup() {
  umount "$MNT" 2>/dev/null
  [ -n "$DEV" ] && hdiutil detach "$DEV" -force >/dev/null 2>&1
}
trap cleanup EXIT

BUNDLE_ID="dev.h3ct0r.ext4mac.Ext4FS"
if ! pluginkit -m -p com.apple.fskit.fsmodule 2>/dev/null | grep -q "$BUNDLE_ID"; then
  echo "the FSKit extension is not installed; nothing to test"
  exit 1
fi

rm -rf "$WORK"; mkdir -p "$WORK" "$MNT"

echo "########## NEWFS THROUGH FSKIT ##########"
echo ""

# The device starts with a FAT signature planted on it, so the run also
# proves the foreign-signature wipe on the real path, not just offline.
dd if=/dev/zero of="$IMG" bs=1m count=64 2>/dev/null
printf '\xeb\x3c\x90MSDOS5.0' | dd of="$IMG" conv=notrunc 2>/dev/null
printf '\x55\xaa' | dd of="$IMG" bs=1 seek=510 conv=notrunc 2>/dev/null

DEV=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount "$IMG" \
      | awk 'NR==1{print $1}')
[ -n "$DEV" ] || { echo "attach failed"; exit 1; }
RDEV="/dev/r${DEV#/dev/}"

# --- ext4 ------------------------------------------------------------------
out=$(newfs_fskit -t ext4 -L NEWFS4 "$DEV" 2>&1); rc=$?
[ $rc -eq 0 ] && ok "newfs_fskit -t ext4 exits 0" \
              || bad "newfs_fskit -t ext4 exits 0" "$out"
grep -q "startFormat entered" <<<"$out" \
  && ok "startFormat was reached (the task logged it)" \
  || bad "startFormat was reached (the task logged it)"

e2fsck -fn "$RDEV" >/dev/null 2>&1 \
  && ok "e2fsck accepts the ext4 volume" || bad "e2fsck accepts the ext4 volume"
feats=$(dumpe2fs -h "$RDEV" 2>/dev/null)
grep -q "volume name:   NEWFS4" <<<"$feats" \
  && ok "the label made it through" || bad "the label made it through"
grep -q "metadata_csum" <<<"$feats" \
  && ok "metadata_csum is on, as our format promises" \
  || bad "metadata_csum is on, as our format promises"
[ "$(dd if="$RDEV" bs=512 count=1 2>/dev/null | tr -d '\0' | wc -c | tr -d ' ')" = "0" ] \
  && ok "the planted FAT boot sector is gone" \
  || bad "the planted FAT boot sector is gone"

# --- the volume actually works ---------------------------------------------
if mount -F -t ext4 "${DEV#/dev/}" "$MNT" 2>/dev/null; then
  ok "the freshly formatted volume mounts"
  echo "newfs made me" > "$MNT/proof.txt" 2>/dev/null
  [ "$(cat "$MNT/proof.txt" 2>/dev/null)" = "newfs made me" ] \
    && ok "and takes a write" || bad "and takes a write"
  umount "$MNT" && ok "and unmounts" || bad "and unmounts"
  e2fsck -fn "$RDEV" >/dev/null 2>&1 \
    && ok "e2fsck clean after the mounted session" \
    || bad "e2fsck clean after the mounted session"
else
  bad "the freshly formatted volume mounts"
fi

# --- fsck_fskit ------------------------------------------------------------
out=$(fsck_fskit -t ext4 "$DEV" 2>&1); rc=$?
[ $rc -eq 0 ] && ok "fsck_fskit -t ext4 exits 0" \
              || bad "fsck_fskit -t ext4 exits 0" "$out"
grep -q "startCheck entered" <<<"$out" \
  && ok "startCheck was reached" || bad "startCheck was reached"

# --- the other generations, over the previous filesystem -------------------
out=$(newfs_fskit -t ext4 -g 3 -L NEWFS3 "$DEV" 2>&1) \
  && ok "reformat as ext3 over the ext4 volume" \
  || bad "reformat as ext3 over the ext4 volume" "$out"
out=$(newfs_fskit -t ext4 -g 2 -b 1024 -L NEWFS2 "$DEV" 2>&1) \
  && ok "reformat as ext2 with 1 KiB blocks" \
  || bad "reformat as ext2 with 1 KiB blocks" "$out"
feats=$(dumpe2fs -h "$RDEV" 2>/dev/null)
grep -q "volume name:   NEWFS2" <<<"$feats" && grep -q "Block size:               1024" <<<"$feats" \
  && ok "the last format's label and block size are on disk" \
  || bad "the last format's label and block size are on disk"
grep -q "has_journal" <<<"$feats" \
  && bad "ext2 has no journal" || ok "ext2 has no journal"
e2fsck -fn "$RDEV" >/dev/null 2>&1 \
  && ok "e2fsck accepts the ext2 volume" || bad "e2fsck accepts the ext2 volume"

echo ""
echo "passed: $PASS failed: $FAIL"
[ "$FAIL" -eq 0 ]
