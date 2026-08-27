#!/usr/bin/env bash
# Generate ext2/3/4 test images using e2fsprogs.
#
# debugfs populates the images, so no ext4 driver is needed to build fixtures --
# which keeps the test suite independent of the thing it is testing.
set -euo pipefail

export PATH="/opt/homebrew/opt/e2fsprogs/sbin:/opt/homebrew/opt/e2fsprogs/bin:$PATH"
command -v mke2fs >/dev/null || { echo "mke2fs not found; brew install e2fsprogs"; exit 1; }

DIR="$(cd "$(dirname "$0")" && pwd)/fixtures"
mkdir -p "$DIR"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# ---------------------------------------------------------------- content --
mkdir -p "$STAGE/content"
printf 'hello from ext4\n' > "$STAGE/content/hello.txt"
printf 'x%.0s' $(seq 1 100000) > "$STAGE/content/medium.bin"     # ~100 KB, multi-block
dd if=/dev/urandom of="$STAGE/content/large.bin" bs=1k count=3000 2>/dev/null  # ~3 MB
printf '' > "$STAGE/content/empty.txt"

# ------------------------------------------------------------------ build --
build_image() {
  local name="$1" type="$2" size_mb="$3" bs="$4" extra="${5:-}"
  local img="$DIR/$name.img"

  rm -f "$img"
  dd if=/dev/zero of="$img" bs=1m count="$size_mb" 2>/dev/null

  # shellcheck disable=SC2086
  mke2fs -q -t "$type" -b "$bs" -L "${name:0:16}" $extra "$img"

  debugfs -w -f /dev/stdin "$img" >/dev/null 2>&1 <<EOF
mkdir /docs
mkdir /docs/nested
mkdir /docs/nested/deeper
mkdir /empty_dir
cd /docs
write $STAGE/content/hello.txt hello.txt
write $STAGE/content/medium.bin medium.bin
write $STAGE/content/empty.txt empty.txt
cd /docs/nested/deeper
write $STAGE/content/large.bin large.bin
cd /
symlink /link_to_hello docs/hello.txt
symlink /broken_link /nonexistent/path
ln /docs/hello.txt /hardlink_hello
sif /docs/hello.txt links_count 2
quit
EOF

  # debugfs's 'ln' adds the directory entry but does not update the target's
  # link count, so it is fixed up explicitly above with 'sif'. Without that,
  # e2fsck reports "ref count is 1, should be 2".

  # A directory with enough entries to force an HTree index.
  {
    echo "cd /"
    echo "mkdir /manyfiles"
    echo "cd /manyfiles"
    for i in $(seq 1 500); do
      echo "write $STAGE/content/hello.txt file_$(printf '%04d' "$i").txt"
    done
    echo "quit"
  } | debugfs -w -f /dev/stdin "$img" >/dev/null 2>&1

  # Extended attributes on a known file.
  debugfs -w -f /dev/stdin "$img" >/dev/null 2>&1 <<EOF
ea_set /docs/hello.txt user.testattr "a-user-value"
ea_set /docs/hello.txt user.another "second"
quit
EOF

  e2fsck -fn "$img" >/dev/null 2>&1 \
    && echo "  built $name.img ($type, ${bs}b blocks, ${size_mb}MB) — fsck clean" \
    || { echo "  ERROR: $name.img failed fsck after creation"; exit 1; }
}

echo "generating fixtures in $DIR"
build_image ext4_4k  ext4 256 4096
build_image ext4_1k  ext4  64 1024
# 64 MB at 4 KiB blocks gets mke2fs's minimum journal -- 1024 blocks, 4 MB.
# That is the geometry where transaction batching corrupted volumes under
# reordering (commit 69ad644) while every suite ran on ext4_4k's 16 MB journal
# and passed: a log that never wraps cannot exercise what wrapping does. The
# assertion below is load-bearing -- if mke2fs's sizing ever changes, the
# reorder suite would silently stop testing the wrap path.
build_image ext4_64m ext4  64 4096
jblocks="$(dumpe2fs -h "$DIR/ext4_64m.img" 2>/dev/null \
           | sed -n 's/^Total journal blocks: *//p')"
if [ "$jblocks" != "1024" ]; then
  echo "  ERROR: ext4_64m.img journal is $jblocks blocks, not 1024 — the"
  echo "  wrap-path geometry is gone; force it with -J size=4 in build_image"
  exit 1
fi
build_image ext3_4k  ext3 128 4096
build_image ext2_4k  ext2 128 4096 "-O ^has_journal"

# A volume whose UUID was changed after creation: must be detected as
# read-only, because lwext4 derives the checksum seed from the UUID.
cp "$DIR/ext4_4k.img" "$DIR/ext4_uuid_changed.img"
tune2fs -U 99999999-8888-7777-6666-555555555555 "$DIR/ext4_uuid_changed.img" >/dev/null 2>&1
echo "  built ext4_uuid_changed.img (negative fixture)"

echo "done."
