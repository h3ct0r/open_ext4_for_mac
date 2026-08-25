#!/usr/bin/env bash
# Differential testing against the real Linux ext4 driver.
#
# e2fsck only proves a volume is structurally valid. It says nothing about
# whether Linux *interprets* it the way we intended. This suite closes that gap
# in both directions:
#
#   mac -> linux : we perform operations, then Linux mounts the volume and must
#                  see exactly the tree, contents and metadata we intended, with
#                  no complaint in the kernel log.
#   linux -> mac : Linux performs operations, and our driver must read back the
#                  same thing.
#
# Runs unattended. Writes a report to build/diff-report.txt.
set -uo pipefail

export PATH="/opt/homebrew/opt/e2fsprogs/sbin:/opt/homebrew/opt/e2fsprogs/bin:$PATH"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DUMP="$ROOT/build/bin/ext4dump"
FIX="$ROOT/Tests/fixtures"
WORK="$ROOT/build/diff"
REPORT="$ROOT/build/diff-report.txt"
DOCKER_IMAGE="ext4diff:latest"

# debian:stable-slim ships without setfattr/getfattr, so the xattr checks would
# quietly pass over a missing binary. Build a small image once that has them.
if ! docker image inspect "$DOCKER_IMAGE" >/dev/null 2>&1; then
  echo "building $DOCKER_IMAGE (one-off, needs network)"
  docker build -q -t "$DOCKER_IMAGE" - >/dev/null <<'DOCKERFILE'
FROM debian:stable-slim
RUN apt-get update && apt-get install -y --no-install-recommends attr \
    && rm -rf /var/lib/apt/lists/*
DOCKERFILE
fi

rm -rf "$WORK"; mkdir -p "$WORK"
: > "$REPORT"

PASS=0; FAIL=0
note() { echo "$*" | tee -a "$REPORT"; }
ok()   { PASS=$((PASS+1)); note "  ok    $1"; }
bad()  { FAIL=$((FAIL+1)); note "  FAIL  $1"; [ $# -gt 1 ] && note "        $2"; }
expect_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }

[ -x "$DUMP" ] || { echo "build first: make tools"; exit 1; }
[ -f "$FIX/ext4_4k.img" ] || bash "$ROOT/Tests/make_fixtures.sh"
docker info >/dev/null 2>&1 || { echo "docker is not running; cannot reach a Linux kernel"; exit 1; }

in_linux() {  # in_linux <script>
  docker run --rm --privileged -v "$WORK:/work" "$DOCKER_IMAGE" bash -c "$1" 2>&1
}

# =========================================================== mac -> linux ==
note "mac writes, Linux reads"
note ""

IMG="$WORK/m2l.img"
cp "$FIX/ext4_4k.img" "$IMG"

"$DUMP" "$IMG" mkdir /frommac                                  >/dev/null 2>&1
"$DUMP" "$IMG" create /frommac/plain.txt                       >/dev/null 2>&1
"$DUMP" "$IMG" write /frommac/plain.txt "content from macOS"   >/dev/null 2>&1
"$DUMP" "$IMG" chmod /frommac/plain.txt 640                    >/dev/null 2>&1
"$DUMP" "$IMG" symlink /frommac/plain.txt /frommac/sym         >/dev/null 2>&1
"$DUMP" "$IMG" ln /frommac/plain.txt /frommac/hard             >/dev/null 2>&1
"$DUMP" "$IMG" mkdir /frommac/sub                              >/dev/null 2>&1
"$DUMP" "$IMG" create /frommac/sub/nested.txt                  >/dev/null 2>&1
"$DUMP" "$IMG" setxattr /frommac/plain.txt user.origin macos   >/dev/null 2>&1

# A multi-block file, to exercise extent allocation rather than a single block.
python3 -c "import sys; sys.stdout.write('L'*90000)" > "$WORK/big.txt"
"$DUMP" "$IMG" create /frommac/big.bin >/dev/null 2>&1
"$DUMP" "$IMG" write /frommac/big.bin "$(cat "$WORK/big.txt")" >/dev/null 2>&1

in_linux '
  dmesg -C 2>/dev/null || true
  mkdir -p /mnt/t
  mount -o loop /work/m2l.img /mnt/t || { echo "MOUNT-FAILED"; exit 1; }
  {
    echo "content=$(cat /mnt/t/frommac/plain.txt)"
    echo "mode=$(stat -c %a /mnt/t/frommac/plain.txt)"
    echo "links=$(stat -c %h /mnt/t/frommac/plain.txt)"
    echo "symtarget=$(readlink /mnt/t/frommac/sym)"
    echo "hardsame=$([ /mnt/t/frommac/plain.txt -ef /mnt/t/frommac/hard ] && echo yes || echo no)"
    echo "nested=$([ -f /mnt/t/frommac/sub/nested.txt ] && echo yes || echo no)"
    echo "xattr=$(getfattr -n user.origin --only-values /mnt/t/frommac/plain.txt 2>/dev/null)"
    echo "bigsize=$(stat -c %s /mnt/t/frommac/big.bin)"
    echo "bigsum=$(sha256sum /mnt/t/frommac/big.bin | cut -d" " -f1)"
    echo "dirents=$(ls -1 /mnt/t/frommac | wc -l)"
  } > /work/m2l.result
  umount /mnt/t
  dmesg | grep -iE "EXT4|JBD2" > /work/m2l.dmesg || true
' >/dev/null

if [ ! -f "$WORK/m2l.result" ]; then
  bad "Linux mounted the volume we wrote" "mount failed"
else
  ok "Linux mounted the volume we wrote"
  # shellcheck disable=SC1090
  declare -A R
  while IFS='=' read -r k v; do R["$k"]="$v"; done < "$WORK/m2l.result"

  expect_eq "Linux reads our file content"      "content from macOS" "${R[content]:-}"
  expect_eq "Linux sees the mode we set"        "640"                "${R[mode]:-}"
  expect_eq "Linux sees link count 2"           "2"                  "${R[links]:-}"
  expect_eq "Linux resolves our symlink"        "/frommac/plain.txt" "${R[symtarget]:-}"
  expect_eq "Linux agrees the hard link shares an inode" "yes"       "${R[hardsame]:-}"
  expect_eq "Linux sees the nested file"        "yes"                "${R[nested]:-}"
  expect_eq "Linux reads our xattr"             "macos"              "${R[xattr]:-}"
  expect_eq "Linux sees the multi-block size"   "90000"              "${R[bigsize]:-}"
  expect_eq "Linux counts every directory entry" "5"                 "${R[dirents]:-}"

  want=$(shasum -a 256 "$WORK/big.txt" | cut -d' ' -f1)
  expect_eq "multi-block content is byte-identical in Linux" "$want" "${R[bigsum]:-}"
fi

# The kernel must not log a single complaint about a filesystem we produced.
if [ -s "$WORK/m2l.dmesg" ] && grep -qiE "error|warning|corrupt|bad |invalid" "$WORK/m2l.dmesg"; then
  bad "kernel log is clean" "$(head -3 "$WORK/m2l.dmesg")"
else
  ok "kernel log is clean"
fi

# =========================================================== linux -> mac ==
note ""
note "Linux writes, mac reads"
note ""

IMG2="$WORK/l2m.img"
cp "$FIX/ext4_4k.img" "$IMG2"

in_linux '
  mkdir -p /mnt/t
  mount -o loop /work/l2m.img /mnt/t || { echo "MOUNT-FAILED"; exit 1; }
  mkdir -p /mnt/t/fromlinux/deep
  echo -n "content from Linux" > /mnt/t/fromlinux/plain.txt
  chmod 604 /mnt/t/fromlinux/plain.txt
  ln -s /fromlinux/plain.txt /mnt/t/fromlinux/sym
  ln /mnt/t/fromlinux/plain.txt /mnt/t/fromlinux/hard
  head -c 90000 /dev/zero | tr "\0" "K" > /mnt/t/fromlinux/big.bin
  setfattr -n user.origin -v linux /mnt/t/fromlinux/plain.txt 2>/dev/null || true
  # A directory big enough to be HTree-indexed by the kernel.
  mkdir -p /mnt/t/fromlinux/many
  for i in $(seq 1 300); do echo x > /mnt/t/fromlinux/many/f_$i.txt; done
  sha256sum /mnt/t/fromlinux/big.bin | cut -d" " -f1 > /work/l2m.bigsum
  sync
  umount /mnt/t
' >/dev/null

if "$DUMP" "$IMG2" ls /fromlinux >/dev/null 2>&1; then
  ok "our driver mounted the volume Linux wrote"
else
  bad "our driver mounted the volume Linux wrote"
fi

expect_eq "we read Linux's file content" "content from Linux" "$("$DUMP" "$IMG2" cat /fromlinux/plain.txt 2>/dev/null)"
mode_ours=$("$DUMP" "$IMG2" stat /fromlinux/plain.txt 2>/dev/null | awk '/^mode:/{print $2}')
expect_eq "we see the mode Linux set" "604" "$(printf '%o' "$((8#${mode_ours:-0}))")"
expect_eq "we see link count 2"          "2"    "$("$DUMP" "$IMG2" stat /fromlinux/plain.txt 2>/dev/null | awk '/^links:/{print $2}')"
expect_eq "we resolve Linux's symlink"   "/fromlinux/plain.txt" \
          "$("$DUMP" "$IMG2" ls /fromlinux 2>/dev/null | awk '$0 ~ / -> / {print $NF}' | head -1)"

"$DUMP" "$IMG2" cat /fromlinux/big.bin > "$WORK/l2m_big.bin" 2>/dev/null
expect_eq "multi-block content matches Linux" "$(cat "$WORK/l2m.bigsum" 2>/dev/null)" \
          "$(shasum -a 256 "$WORK/l2m_big.bin" | cut -d' ' -f1)"

"$DUMP" "$IMG2" xattr /fromlinux/plain.txt 2>/dev/null | grep -q "user.origin" \
  && ok "we see the xattr Linux set" || bad "we see the xattr Linux set"

n=$("$DUMP" "$IMG2" ls /fromlinux/many 2>/dev/null | grep -c "f_")
expect_eq "we enumerate the kernel's HTree directory" "300" "$n"

# ===================================================== interleaved editing ==
note ""
note "interleaved: both sides edit the same volume"
note ""

IMG3="$WORK/mixed.img"
cp "$FIX/ext4_4k.img" "$IMG3"

"$DUMP" "$IMG3" mkdir /shared               >/dev/null 2>&1
"$DUMP" "$IMG3" create /shared/a.txt        >/dev/null 2>&1
"$DUMP" "$IMG3" write /shared/a.txt "mac1"  >/dev/null 2>&1

in_linux '
  mkdir -p /mnt/t && mount -o loop /work/mixed.img /mnt/t
  echo -n "linux1" > /mnt/t/shared/b.txt
  echo -n "mac1+linux" > /mnt/t/shared/a.txt
  mkdir /mnt/t/shared/ldir
  sync; umount /mnt/t' >/dev/null

expect_eq "Linux's edit to our file is visible to us" "mac1+linux" "$("$DUMP" "$IMG3" cat /shared/a.txt 2>/dev/null)"
expect_eq "Linux's new file is visible to us"         "linux1"     "$("$DUMP" "$IMG3" cat /shared/b.txt 2>/dev/null)"

"$DUMP" "$IMG3" create /shared/c.txt       >/dev/null 2>&1
"$DUMP" "$IMG3" write /shared/c.txt "mac2" >/dev/null 2>&1
"$DUMP" "$IMG3" rm /shared/b.txt           >/dev/null 2>&1

in_linux '
  mkdir -p /mnt/t && mount -o loop /work/mixed.img /mnt/t
  {
    echo "c=$(cat /mnt/t/shared/c.txt)"
    echo "bgone=$([ -e /mnt/t/shared/b.txt ] && echo no || echo yes)"
    echo "ldir=$([ -d /mnt/t/shared/ldir ] && echo yes || echo no)"
  } > /work/mixed.result
  umount /mnt/t' >/dev/null

if [ -f "$WORK/mixed.result" ]; then
  declare -A M
  while IFS='=' read -r k v; do M["$k"]="$v"; done < "$WORK/mixed.result"
  expect_eq "our later write is visible to Linux"   "mac2" "${M[c]:-}"
  expect_eq "our delete is visible to Linux"        "yes"  "${M[bgone]:-}"
  expect_eq "Linux's directory survived our edits"  "yes"  "${M[ldir]:-}"
else
  bad "interleaved round trip"
fi

# Everything must still be structurally sound at the end.
for img in "$IMG" "$IMG2" "$IMG3"; do
  n=$(basename "$img")
  e2fsck -fn "$img" >/dev/null 2>&1 && ok "e2fsck clean: $n" || bad "e2fsck clean: $n"
done

note ""
note "─────────────────────────────────"
note "passed: $PASS   failed: $FAIL"
note "report: $REPORT"
[ "$FAIL" -eq 0 ] || exit 1
