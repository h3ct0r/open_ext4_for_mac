#!/usr/bin/env bash
# ext4 inside a LUKS container.
#
# LUKS is a block layer underneath the filesystem, so this suite is about one
# question: does our decryption produce exactly the bytes cryptsetup would? A
# cipher is unforgiving about that in a specific way -- there is no such thing
# as *nearly* the right key. Either the plaintext is exact or it is noise, and
# noise that lands in a superblock field looks like a corrupt filesystem rather
# than a crypto mistake.
#
# So the oracle is never our own reader. Fixtures are made by real cryptsetup;
# what we decrypt is checked with e2fsck and debugfs; and what we *write* is
# handed back to cryptsetup and the Linux kernel to read. A bug that is
# symmetric -- encrypting and decrypting consistently wrongly -- would pass
# every test we could run against ourselves, and fails this one immediately.
#
# Needs Docker for cryptsetup; skips with exit 77 if it is not running.
# Runs unattended. Writes a report to build/luks-report.txt.
set -uo pipefail

export PATH="/opt/homebrew/opt/e2fsprogs/sbin:/opt/homebrew/opt/e2fsprogs/bin:$PATH"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DUMP="$ROOT/build/bin/ext4dump"
WORK="$ROOT/build/luks"
REPORT="$ROOT/build/luks-report.txt"
# Bump the tag when the package list changes, or a stale image from an earlier
# run is reused and the new checks quietly skip.
DOCKER_IMAGE="ext4luks:cryptsetup-attr"

PASS=0; FAIL=0
note() { echo "$*" | tee -a "$REPORT"; }
ok()   { PASS=$((PASS+1)); note "  ok    $1"; }
# `bad` must end in a success status; see the note in the other suites.
bad()  { FAIL=$((FAIL+1)); note "  FAIL  $1"; [ $# -gt 1 ] && note "        $2"; return 0; }
expect_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }

[ -x "$DUMP" ] || { echo "build first: make tools"; exit 1; }
command -v e2fsck >/dev/null || { echo "e2fsck not found; brew install e2fsprogs"; exit 1; }

if ! docker info >/dev/null 2>&1; then
  echo "docker is not running; cryptsetup is the only way to make a LUKS fixture"
  echo "SKIPPED"
  exit 77
fi

rm -rf "$WORK"; mkdir -p "$WORK"
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

PASSPHRASE="correct horse battery staple"
printf '%s' "$PASSPHRASE"  > "$WORK/pass.txt"
printf 'not the passphrase' > "$WORK/wrong.txt"
printf 'second slot key'    > "$WORK/pass2.txt"

note "########## LUKS ##########"
note ""
note "building fixtures with real cryptsetup"
note ""

in_linux '
set -e
mk() {  # mk <name> <luksFormat args...>
  local name="$1"; shift
  dd if=/dev/zero of=/w/$name.img bs=1M count=48 status=none
  cryptsetup luksFormat --batch-mode --key-file /w/pass.txt "$@" /w/$name.img
}

# The ordinary case: LUKS1, aes-xts-plain64, sha256.
mk luks1 --type luks1
cryptsetup luksOpen --key-file /w/pass.txt /w/luks1.img v1
mkfs.ext4 -q -L LUKSVOL /dev/mapper/v1
mkdir -p /mnt/v && mount /dev/mapper/v1 /mnt/v
echo -n "written by linux inside luks" > /mnt/v/hello.txt
mkdir -p /mnt/v/sub
head -c 300000 /dev/urandom > /mnt/v/sub/blob.bin
sha256sum /mnt/v/sub/blob.bin | cut -d" " -f1 > /w/blob.sha
sync; umount /mnt/v; cryptsetup luksClose v1
# A second passphrase in another key slot: unlocking must try them all.
cryptsetup luksAddKey --batch-mode --key-file /w/pass.txt /w/luks1.img /w/pass2.txt

# sha512 in the header, to prove the hash is read rather than assumed.
mk luks1_sha512 --type luks1 --hash sha512
cryptsetup luksOpen --key-file /w/pass.txt /w/luks1_sha512.img v2
mkfs.ext4 -q -L SHA512VOL /dev/mapper/v2 && cryptsetup luksClose v2

# A cipher we do not implement. Must be refused by name, never guessed at.
mk luks1_cbc --type luks1 --cipher aes-cbc-essiv:sha256

# LUKS2, the modern default: 4096-byte encryption sectors and argon2id.
mk luks2 --type luks2 --sector-size 4096
cryptsetup luksOpen --key-file /w/pass.txt /w/luks2.img v3
mkfs.ext4 -q -L LUKS2VOL /dev/mapper/v3
mkdir -p /mnt/w && mount /dev/mapper/v3 /mnt/w
echo -n "luks2 payload" > /mnt/w/two.txt
# Deliberately larger than one encryption sector, and larger than one
# filesystem block: the tweak has to advance correctly across both.
head -c 400000 /dev/urandom > /mnt/w/wide.bin
sha256sum /mnt/w/wide.bin | cut -d" " -f1 > /w/wide.sha
sync; umount /mnt/w; cryptsetup luksClose v3

# The same format with 512-byte sectors, where the tweak advances one unit per
# sector instead of eight. Both conventions have to be right.
mk luks2_512 --type luks2 --sector-size 512
cryptsetup luksOpen --key-file /w/pass.txt /w/luks2_512.img v4
mkfs.ext4 -q -L LUKS2SMALL /dev/mapper/v4
mkdir -p /mnt/x && mount /dev/mapper/v4 /mnt/x
head -c 400000 /dev/urandom > /mnt/x/wide.bin
sha256sum /mnt/x/wide.bin | cut -d" " -f1 > /w/wide512.sha
sync; umount /mnt/x; cryptsetup luksClose v4

# pbkdf2 instead of argon2id, to prove the KDF is read from the header rather
# than assumed.
mk luks2_pbkdf2 --type luks2 --pbkdf pbkdf2 --pbkdf-force-iterations 1000
cryptsetup luksOpen --key-file /w/pass.txt /w/luks2_pbkdf2.img v5
mkfs.ext4 -q -L LUKS2PBKDF /dev/mapper/v5 && cryptsetup luksClose v5
echo BUILT
' 2>&1 | tail -2 | sed 's/^/  /'

[ -f "$WORK/luks1.img" ] || { note "  fixtures were not built"; exit 1; }

# ================================================================== probing ==
note ""
note "a container is not mistaken for anything else"
note ""

expect_eq "a locked container does not look like ext4" "NOT_EXT" \
  "$("$DUMP" "$WORK/luks1.img" probe 2>/dev/null | sed -n 's/^verdict: *//p')"

luks_line=$(EXT4DUMP_LUKS_KEYFILE="$WORK/pass.txt" "$DUMP" "$WORK/luks1.img" probe 2>&1 >/dev/null | grep '^\[luks')
case "$luks_line" in
  *"[luks1]"*"512-byte sectors"*) ok "the header is read: $luks_line" ;;
  *) bad "the header is read" "got [$luks_line]" ;;
esac

# ================================================================ unlocking ==
note ""
note "unlocking"
note ""

before=$(shasum -a 256 "$WORK/luks1.img" | cut -d' ' -f1)
out=$(EXT4DUMP_LUKS_KEYFILE="$WORK/wrong.txt" "$DUMP" "$WORK/luks1.img" ls / 2>&1)
if grep -q "no key slot accepted" <<<"$out"; then
  ok "a wrong passphrase is refused, and says so"
else
  bad "a wrong passphrase is refused, and says so" "got: $(head -1 <<<"$out")"
fi
expect_eq "and the container is left untouched" "$before" \
  "$(shasum -a 256 "$WORK/luks1.img" | cut -d' ' -f1)"

expect_eq "the right passphrase opens it" "USABLE" \
  "$(EXT4DUMP_LUKS_KEYFILE="$WORK/pass.txt" "$DUMP" "$WORK/luks1.img" probe 2>/dev/null | sed -n 's/^verdict: *//p')"
expect_eq "and the volume label is the one Linux set" "LUKSVOL" \
  "$(EXT4DUMP_LUKS_KEYFILE="$WORK/pass.txt" "$DUMP" "$WORK/luks1.img" probe 2>/dev/null | sed -n 's/^label: *//p')"

# A passphrase in a different key slot has to work too, which means every
# enabled slot is tried rather than only the first.
expect_eq "a passphrase in the second key slot also opens it" "USABLE" \
  "$(EXT4DUMP_LUKS_KEYFILE="$WORK/pass2.txt" "$DUMP" "$WORK/luks1.img" probe 2>/dev/null | sed -n 's/^verdict: *//p')"

expect_eq "a sha512 header is honoured, not assumed to be sha256" "SHA512VOL" \
  "$(EXT4DUMP_LUKS_KEYFILE="$WORK/pass.txt" "$DUMP" "$WORK/luks1_sha512.img" probe 2>/dev/null | sed -n 's/^label: *//p')"

# ============================================================== refusals ==
note ""
note "what we do not implement is refused by name"
note ""

out=$(EXT4DUMP_LUKS_KEYFILE="$WORK/pass.txt" "$DUMP" "$WORK/luks1_cbc.img" ls / 2>&1)
if grep -q "cbc-essiv" <<<"$out"; then
  ok "an unsupported cipher is named, not guessed at"
else
  bad "an unsupported cipher is named, not guessed at" "got: $(head -1 <<<"$out")"
fi

# ================================================================= reading ==
note ""
note "reading what Linux wrote"
note ""

expect_eq "file content matches" "written by linux inside luks" \
  "$(EXT4DUMP_LUKS_KEYFILE="$WORK/pass.txt" "$DUMP" "$WORK/luks1.img" cat /hello.txt 2>/dev/null)"

EXT4DUMP_LUKS_KEYFILE="$WORK/pass.txt" "$DUMP" "$WORK/luks1.img" cat /sub/blob.bin > "$WORK/blob.out" 2>/dev/null
expect_eq "a 300 KB file is byte-identical across many sectors" \
  "$(cat "$WORK/blob.sha")" "$(shasum -a 256 "$WORK/blob.out" | cut -d' ' -f1)"

# The oracle cannot see inside a container, so hand it the plaintext.
EXT4DUMP_LUKS_KEYFILE="$WORK/pass.txt" "$DUMP" "$WORK/luks1.img" decrypt "$WORK/plain.img" >/dev/null 2>&1
if e2fsck -fn "$WORK/plain.img" >/dev/null 2>&1; then
  ok "the decrypted payload is e2fsck-clean"
else
  bad "the decrypted payload is e2fsck-clean" \
      "$(e2fsck -fn "$WORK/plain.img" 2>&1 | grep -m1 -vE '^e2fsck|^Pass|^$' | cut -c1-60)"
fi

# ================================================================= writing ==
#
# The half that cannot be checked against ourselves. If encryption and
# decryption are wrong in the same way, everything above still passes.

note ""
note "writing, judged by cryptsetup and the Linux kernel"
note ""

cp "$WORK/luks1.img" "$WORK/rw.img"
K="$WORK/pass.txt"
EXT4DUMP_LUKS_KEYFILE=$K "$DUMP" "$WORK/rw.img" mkdir /from-macos       >/dev/null 2>&1
EXT4DUMP_LUKS_KEYFILE=$K "$DUMP" "$WORK/rw.img" create /from-macos/note.txt >/dev/null 2>&1
EXT4DUMP_LUKS_KEYFILE=$K "$DUMP" "$WORK/rw.img" write /from-macos/note.txt "written through AES-XTS on macOS" >/dev/null 2>&1
EXT4DUMP_LUKS_KEYFILE=$K "$DUMP" "$WORK/rw.img" create /big.bin         >/dev/null 2>&1
EXT4DUMP_LUKS_KEYFILE=$K "$DUMP" "$WORK/rw.img" write /big.bin "$(python3 -c "import sys; sys.stdout.write('Q'*250000)")" >/dev/null 2>&1
# An unaligned, partial-sector overwrite: the bytes we do not touch have to
# re-encrypt to exactly what they were.
EXT4DUMP_LUKS_KEYFILE=$K "$DUMP" "$WORK/rw.img" symlink /big.bin /link  >/dev/null 2>&1
EXT4DUMP_LUKS_KEYFILE=$K "$DUMP" "$WORK/rw.img" setxattr /from-macos/note.txt user.origin macos >/dev/null 2>&1

in_linux '
set -e
cryptsetup luksOpen --key-file /w/pass.txt /w/rw.img rw || { echo "OPEN-FAILED"; exit 0; }
e2fsck -fn /dev/mapper/rw >/dev/null 2>&1 && echo "FSCK-CLEAN" || echo "FSCK-DIRTY"
mkdir -p /mnt/rw && mount /dev/mapper/rw /mnt/rw || { echo "MOUNT-FAILED"; exit 0; }
echo "NOTE:$(cat /mnt/rw/from-macos/note.txt)"
echo "BIGSHA:$(sha256sum /mnt/rw/big.bin | cut -d" " -f1)"
echo "BIGSIZE:$(stat -c %s /mnt/rw/big.bin)"
echo "LINK:$(readlink /mnt/rw/link)"
command -v getfattr >/dev/null || { echo "XATTR:NO-GETFATTR"; }
echo "XATTR:$(getfattr -n user.origin --only-values /mnt/rw/from-macos/note.txt 2>/dev/null)"
echo -n "written by linux afterwards" > /mnt/rw/from-linux.txt
sync; umount /mnt/rw; cryptsetup luksClose rw
' > "$WORK/linux.out" 2>/dev/null

grep -q FSCK-CLEAN "$WORK/linux.out" && ok "cryptsetup opens what we wrote, and e2fsck is clean" \
                                     || bad "cryptsetup opens what we wrote, and e2fsck is clean" \
                                            "$(head -3 "$WORK/linux.out" | tr '\n' ' ')"
expect_eq "the Linux kernel reads our file back" "written through AES-XTS on macOS" \
  "$(sed -n 's/^NOTE://p' "$WORK/linux.out")"
expect_eq "a 250 KB file we wrote is the size we wrote" "250000" \
  "$(sed -n 's/^BIGSIZE://p' "$WORK/linux.out")"
expect_eq "our symlink resolves on Linux" "/big.bin" \
  "$(sed -n 's/^LINK://p' "$WORK/linux.out")"
expect_eq "our extended attribute survives" "macos" \
  "$(sed -n 's/^XATTR://p' "$WORK/linux.out")"
expect_eq "and Linux's later write is readable by us" "written by linux afterwards" \
  "$(EXT4DUMP_LUKS_KEYFILE=$K "$DUMP" "$WORK/rw.img" cat /from-linux.txt 2>/dev/null)"

# ==================================================================== LUKS2 ==
note ""
note "LUKS2"
note ""

K="$WORK/pass.txt"

luks_line=$(EXT4DUMP_LUKS_KEYFILE=$K "$DUMP" "$WORK/luks2.img" probe 2>&1 >/dev/null | grep '^\[luks')
case "$luks_line" in
  *"[luks2]"*"4096-byte sectors"*) ok "the LUKS2 header and its JSON metadata are read" ;;
  *) bad "the LUKS2 header and its JSON metadata are read" "got [$luks_line]" ;;
esac

expect_eq "argon2id at cryptsetup's own cost parameters derives the key" "LUKS2VOL" \
  "$(EXT4DUMP_LUKS_KEYFILE=$K "$DUMP" "$WORK/luks2.img" probe 2>/dev/null | sed -n 's/^label: *//p')"
expect_eq "and the payload reads" "luks2 payload" \
  "$(EXT4DUMP_LUKS_KEYFILE=$K "$DUMP" "$WORK/luks2.img" cat /two.txt 2>/dev/null)"

# The regression that matters most. With a 4096-byte encryption sector the XTS
# tweak still counts in 512-byte units. Get it wrong and sector 0 -- the
# superblock -- still decrypts perfectly, because its tweak is zero either way;
# the label reads, the probe says USABLE, and every other byte is garbage. Only
# reading past the first sector catches it.
EXT4DUMP_LUKS_KEYFILE=$K "$DUMP" "$WORK/luks2.img" cat /wide.bin > "$WORK/wide.out" 2>/dev/null
expect_eq "a 4096-sector volume is right past sector 0, not just at it" \
  "$(cat "$WORK/wide.sha")" "$(shasum -a 256 "$WORK/wide.out" | cut -d' ' -f1)"

EXT4DUMP_LUKS_KEYFILE=$K "$DUMP" "$WORK/luks2_512.img" cat /wide.bin > "$WORK/wide512.out" 2>/dev/null
expect_eq "and so is a 512-sector volume, where the tweak advances differently" \
  "$(cat "$WORK/wide512.sha")" "$(shasum -a 256 "$WORK/wide512.out" | cut -d' ' -f1)"

expect_eq "a LUKS2 header using pbkdf2 is honoured, not assumed to be argon2" "LUKS2PBKDF" \
  "$(EXT4DUMP_LUKS_KEYFILE=$K "$DUMP" "$WORK/luks2_pbkdf2.img" probe 2>/dev/null | sed -n 's/^label: *//p')"

out=$(EXT4DUMP_LUKS_KEYFILE="$WORK/wrong.txt" "$DUMP" "$WORK/luks2.img" ls / 2>&1)
if grep -q "no key slot accepted" <<<"$out"; then
  ok "a wrong LUKS2 passphrase is refused"
else
  bad "a wrong LUKS2 passphrase is refused" "got: $(head -1 <<<"$out")"
fi

# Writing, again judged by cryptsetup rather than by us.
cp "$WORK/luks2.img" "$WORK/rw2.img"
EXT4DUMP_LUKS_KEYFILE=$K "$DUMP" "$WORK/rw2.img" create /from-macos.txt >/dev/null 2>&1
EXT4DUMP_LUKS_KEYFILE=$K "$DUMP" "$WORK/rw2.img" write /from-macos.txt "luks2 write from macOS" >/dev/null 2>&1
in_linux '
cryptsetup luksOpen --key-file /w/pass.txt /w/rw2.img rw2 || { echo "OPEN-FAILED"; exit 0; }
e2fsck -fn /dev/mapper/rw2 >/dev/null 2>&1 && echo "FSCK-CLEAN" || echo "FSCK-DIRTY"
mkdir -p /mnt/rw2 && mount /dev/mapper/rw2 /mnt/rw2 && echo "NOTE:$(cat /mnt/rw2/from-macos.txt)"
umount /mnt/rw2; cryptsetup luksClose rw2
' > "$WORK/linux2.out" 2>/dev/null
grep -q FSCK-CLEAN "$WORK/linux2.out" && ok "what we wrote to a LUKS2 volume is e2fsck-clean under cryptsetup" \
                                      || bad "what we wrote to a LUKS2 volume is e2fsck-clean under cryptsetup" \
                                             "$(head -2 "$WORK/linux2.out" | tr '\n' ' ')"
expect_eq "and the Linux kernel reads it back" "luks2 write from macOS" \
  "$(sed -n 's/^NOTE://p' "$WORK/linux2.out")"

# =================================================================== report ==
note ""
note "─────────────────────────────────"
note "passed: $PASS   failed: $FAIL"
note "report: $REPORT"

rm -f "$WORK"/*.img "$WORK"/*.out "$WORK"/pass*.txt "$WORK"/wrong.txt
[ "$FAIL" -eq 0 ]
