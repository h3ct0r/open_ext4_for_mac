#!/usr/bin/env bash
# Correctness suite for the ext4 core.
#
# Runs entirely against image files via ext4dump — no FSKit, no code signing,
# no mounting, no root. Every content assertion is checked against e2fsprogs
# (debugfs/e2fsck) rather than against our own output, so the suite cannot
# agree with a bug in the driver.
set -uo pipefail

export PATH="/opt/homebrew/opt/e2fsprogs/sbin:/opt/homebrew/opt/e2fsprogs/bin:$PATH"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DUMP="$ROOT/build/bin/ext4dump"
FIX="$ROOT/Tests/fixtures"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; [ $# -gt 1 ] && printf '         %s\n' "$2"; }

expect_eq() { # desc expected actual
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi
}

[ -x "$DUMP" ] || { echo "build first: make tools"; exit 1; }
[ -f "$FIX/ext4_4k.img" ] || bash "$ROOT/Tests/make_fixtures.sh"

# ------------------------------------------------------------------ probe --
echo "probe / feature gating"

for img in ext4_4k ext4_1k ext3_4k ext2_4k; do
  v=$("$DUMP" "$FIX/$img.img" probe | awk '/^verdict:/{print $2}')
  expect_eq "$img probes USABLE" "USABLE" "$v"
done

v=$("$DUMP" "$FIX/ext4_uuid_changed.img" probe | awk '/^verdict:/{print $2}')
expect_eq "UUID-changed volume is refused write access" "READ_ONLY" "$v"

gen=$("$DUMP" "$FIX/ext2_4k.img" probe | awk '/^generation:/{print $2}')
expect_eq "ext2 detected as ext2" "ext2" "$gen"
gen=$("$DUMP" "$FIX/ext3_4k.img" probe | awk '/^generation:/{print $2}')
expect_eq "ext3 detected as ext3" "ext3" "$gen"

# Random data must not be mistaken for a filesystem.
dd if=/dev/urandom of="$TMP/noise.img" bs=1m count=2 2>/dev/null
v=$("$DUMP" "$TMP/noise.img" probe | awk '/^verdict:/{print $2}')
expect_eq "random data is not recognised as ext" "NOT_EXT" "$v"

# A truncated/corrupt superblock must be rejected, not crash.
cp "$FIX/ext4_4k.img" "$TMP/corrupt.img"
# Claim an absurd block count (offset 0x404 == 1024 + 0x04).
printf '\xff\xff\xff\xff' | dd of="$TMP/corrupt.img" bs=1 seek=$((1024+4)) conv=notrunc 2>/dev/null
v=$("$DUMP" "$TMP/corrupt.img" probe | awk '/^verdict:/{print $2}')
expect_eq "oversized block count is rejected" "UNSUPPORTED" "$v"

# ------------------------------------------------------------- structure --
echo
echo "directory structure"

for img in ext4_4k ext4_1k ext3_4k ext2_4k; do
  out="$("$DUMP" "$FIX/$img.img" ls 2>/dev/null)"
  counts=$(echo "$out" | awk '/^# [0-9]+ dirs/{print $2, $4, $6}')
  expect_eq "$img: 6 dirs, 505 files, 2 symlinks" "6 505 2" "$counts"
done

out="$("$DUMP" "$FIX/ext4_4k.img" ls 2>/dev/null)"
echo "$out" | grep -q 'link_to_hello -> docs/hello.txt' \
  && ok "symlink target resolved" || bad "symlink target resolved"

# A hard link must report the *same* inode from both paths.
i1=$(echo "$out" | awk '/\/docs\/hello.txt$/{print $5}')
i2=$(echo "$out" | awk '/\/hardlink_hello$/{print $5}')
expect_eq "hard link shares an inode" "$i1" "$i2"

nlink=$("$DUMP" "$FIX/ext4_4k.img" stat /docs/hello.txt | awk '/^links:/{print $2}')
expect_eq "hard link count is 2" "2" "$nlink"

# 500 entries forces an HTree-indexed directory.
n=$(echo "$out" | grep -c '/manyfiles/file_')
expect_eq "HTree directory enumerates all 500 entries" "500" "$n"

# ------------------------------------------------------------------ data --
echo
echo "data integrity (checked against debugfs)"

for img in ext4_4k ext4_1k ext3_4k ext2_4k; do
  for f in /docs/hello.txt /docs/medium.bin /docs/nested/deeper/large.bin; do
    "$DUMP" "$FIX/$img.img" cat "$f" > "$TMP/ours.bin" 2>/dev/null
    debugfs -R "dump $f $TMP/ref.bin" "$FIX/$img.img" >/dev/null 2>&1
    if cmp -s "$TMP/ours.bin" "$TMP/ref.bin"; then
      ok "$img $f byte-identical"
    else
      bad "$img $f byte-identical" \
          "ours=$(shasum -a256 "$TMP/ours.bin"|cut -c1-16) ref=$(shasum -a256 "$TMP/ref.bin"|cut -c1-16)"
    fi
  done
done

sz=$("$DUMP" "$FIX/ext4_4k.img" stat /docs/empty.txt | awk '/^size:/{print $2}')
expect_eq "empty file has size 0" "0" "$sz"

# --------------------------------------------------------------- extents --
echo
echo "extent mapping"

# ext4 uses extent trees; ext2/ext3 use indirect blocks. Both must map.
lay=$("$DUMP" "$FIX/ext4_4k.img" stat /docs/nested/deeper/large.bin | awk '/^layout:/{print $2}')
expect_eq "ext4 large file uses extents" "extents" "$lay"
lay=$("$DUMP" "$FIX/ext2_4k.img" stat /docs/nested/deeper/large.bin | awk '/^layout:/{print $2}')
expect_eq "ext2 large file uses indirect blocks" "indirect" "$lay"

for img in ext4_4k ext2_4k; do
  ext_out="$("$DUMP" "$FIX/$img.img" extents /docs/nested/deeper/large.bin 2>/dev/null)"
  total=$(echo "$ext_out" | awk '{for(i=1;i<=NF;i++) if($i=="len") s+=$(i+1)} END{print s+0}')
  size=$(echo "$ext_out" | awk -F'size=' '/size=/{split($2,a," "); print a[1]}')
  # Mapped length must cover the whole file.
  if [ "$total" -ge "$size" ]; then
    ok "$img extent map covers the file ($total >= $size)"
  else
    bad "$img extent map covers the file" "mapped $total of $size"
  fi
done

# ----------------------------------------------------------------- xattr --
echo
echo "extended attributes"

xa="$("$DUMP" "$FIX/ext4_4k.img" xattr /docs/hello.txt 2>/dev/null | tr -d ' ' | sort | tr '\n' ',')"
expect_eq "xattrs listed" "user.another,user.testattr," "$xa"

# ------------------------------------------------------------------- ro ---
echo
echo "read-only guarantee"

# Nothing we do may modify the image. Compare digests before and after a full
# traversal — this is the property the read-only release depends on.
for img in ext4_4k ext3_4k; do
  before=$(shasum -a 256 "$FIX/$img.img" | cut -d' ' -f1)
  "$DUMP" "$FIX/$img.img" ls >/dev/null 2>&1
  "$DUMP" "$FIX/$img.img" cat /docs/medium.bin >/dev/null 2>&1
  after=$(shasum -a 256 "$FIX/$img.img" | cut -d' ' -f1)
  expect_eq "$img unmodified after read-only use" "$before" "$after"
done

# e2fsck must still be happy.
for img in ext4_4k ext4_1k ext3_4k ext2_4k; do
  if e2fsck -fn "$FIX/$img.img" >/dev/null 2>&1; then
    ok "$img still passes e2fsck"
  else
    bad "$img still passes e2fsck"
  fi
done

# ---------------------------------------------------------------- report --
echo
echo "─────────────────────────────────"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
