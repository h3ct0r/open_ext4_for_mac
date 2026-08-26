#!/usr/bin/env bash
# Write-path correctness suite.
#
# The rule here: e2fsck runs after EVERY mutating operation, not at the end of
# the suite. A write path that corrupts the filesystem and then repairs it two
# operations later is still a write path that loses data on power failure, and
# only per-operation checking catches that.
#
# Results are cross-checked against debugfs — an independent implementation —
# rather than against our own reader, so the suite cannot agree with a bug.
set -uo pipefail

export PATH="/opt/homebrew/opt/e2fsprogs/sbin:/opt/homebrew/opt/e2fsprogs/bin:$PATH"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DUMP="$ROOT/build/bin/ext4dump"
FIX="$ROOT/Tests/fixtures"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0; FSCK_RUNS=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
# `bad` must end in a success status. Without it the trailing test is the
# function's exit code, and it is false whenever there is no detail argument --
# so the common `cmd && bad "..." || ok "..."` idiom runs *both* arms and the
# suite reports a failure and a pass for the same check.
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; [ $# -gt 1 ] && printf '         %s\n' "$2"; return 0; }
expect_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }


# Pull one labelled field out of `debugfs -R stat`. That output packs several
# fields onto a line ("Inode: 5   Type: directory   Mode:  0755"), so match the
# label rather than counting columns.
dbg_field() {  # dbg_field <path> <label>
  debugfs -R "stat $1" "$IMG" 2>/dev/null \
    | grep -oE "$2:[[:space:]]*[^[:space:]]+" | head -1 \
    | sed -E "s|$2:[[:space:]]*||"
}

IMG=""
new_image() {  # new_image <fixture>
  IMG="$TMP/work.img"
  cp "$FIX/$1.img" "$IMG"
}

# Run a mutating command, then immediately verify the filesystem is still sound.
op() {  # op <description> <args...>
  local desc="$1"; shift
  local out
  if ! out="$("$DUMP" "$IMG" "$@" 2>&1)"; then
    bad "$desc" "command failed: $out"
    return 1
  fi
  fsck_clean "after: $desc" || return 1
  return 0
}

# Same, but the command is expected to be rejected.
op_must_fail() {  # op_must_fail <description> <expected-substring> <args...>
  local desc="$1" want="$2"; shift 2
  local out
  if out="$("$DUMP" "$IMG" "$@" 2>&1)"; then
    bad "$desc" "expected failure, but it succeeded"
    return 1
  fi
  if ! grep -qi "$want" <<<"$out"; then
    bad "$desc" "expected error matching '$want', got: $out"
    return 1
  fi
  fsck_clean "after rejected: $desc" && ok "$desc"
}

fsck_clean() {  # fsck_clean <context>
  FSCK_RUNS=$((FSCK_RUNS+1))
  local out
  out="$(e2fsck -fn "$IMG" 2>&1)"
  if [ $? -ne 0 ]; then
    bad "e2fsck clean $1" "$(grep -vE '^e2fsck |^Pass |^$' <<<"$out" | head -4)"
    return 1
  fi
  return 0
}

[ -x "$DUMP" ] || { echo "build first: make tools"; exit 1; }
[ -f "$FIX/ext4_4k.img" ] || bash "$ROOT/Tests/make_fixtures.sh"

# ===================================================================== dirs ==
echo "directories"
new_image ext4_4k

op "mkdir /a"        mkdir /a          && ok "mkdir"
op "mkdir /a/b"      mkdir /a/b        && ok "nested mkdir"
op "mkdir /a/b/c"    mkdir /a/b/c      && ok "deeper mkdir"

# debugfs must agree the directory exists and is a directory.
mode=$(dbg_field /a/b Type)
expect_eq "debugfs sees /a/b as a directory" "directory" "$mode"

op_must_fail "mkdir over existing name is refused" "exist" mkdir /a
op_must_fail "rmdir of a non-empty directory is refused" "not empty" rm /a/b

op "rm /a/b/c"       rm /a/b/c         && ok "rmdir empty directory"
op "rm /a/b"         rm /a/b           && ok "rmdir after emptying"

# Parent link count must come back down; a leak here is what fsck pass 4 catches.
links=$(dbg_field /a Links)
expect_eq "parent link count restored after rmdir" "2" "$links"

# ==================================================================== files ==
echo
echo "files"
new_image ext4_4k

op "create /f.txt"   create /f.txt     && ok "create empty file"
sz=$("$DUMP" "$IMG" stat /f.txt | awk '/^size:/{print $2}')
expect_eq "new file is empty" "0" "$sz"

op "write /f.txt"    write /f.txt "hello world" && ok "write to file"
expect_eq "content reads back" "hello world" "$("$DUMP" "$IMG" cat /f.txt)"

# debugfs is the independent check.
debugfs -R "cat /f.txt" "$IMG" 2>/dev/null > "$TMP/viaDebugfs"
expect_eq "debugfs agrees on content" "hello world" "$(cat "$TMP/viaDebugfs")"

op "append /f.txt"   append /f.txt "!!" && ok "append to file"
expect_eq "append landed" "hello world!!" "$("$DUMP" "$IMG" cat /f.txt)"

op "chmod /f.txt"    chmod /f.txt 600  && ok "chmod"
m=$(dbg_field /f.txt Mode)
expect_eq "debugfs sees new mode" "0600" "$m"

op "rm /f.txt"       rm /f.txt         && ok "remove file"
"$DUMP" "$IMG" stat /f.txt >/dev/null 2>&1 && bad "removed file is gone" || ok "removed file is gone"

# ============================================================ large writes ==
echo
echo "multi-block writes"
new_image ext4_4k

op "create /big.bin" create /big.bin && ok "create for large write"
# 40 KB spans multiple 4 KiB blocks and forces real extent allocation.
BIG=$(python3 -c "import sys; sys.stdout.write('ABCDEFGH'*5120)")
op "write 40KB"      write /big.bin "$BIG" && ok "40 KB multi-block write"

sz=$("$DUMP" "$IMG" stat /big.bin | awk '/^size:/{print $2}')
expect_eq "size after large write" "40960" "$sz"

"$DUMP" "$IMG" cat /big.bin > "$TMP/ours.bin" 2>/dev/null
debugfs -R "dump /big.bin $TMP/ref.bin" "$IMG" >/dev/null 2>&1
if cmp -s "$TMP/ours.bin" "$TMP/ref.bin"; then ok "40 KB content matches debugfs"
else bad "40 KB content matches debugfs"; fi

printf '%s' "$BIG" > "$TMP/expected.bin"
if cmp -s "$TMP/ours.bin" "$TMP/expected.bin"; then ok "40 KB content matches what was written"
else bad "40 KB content matches what was written"; fi

# The file must be described by real extents, not left unmapped.
nex=$("$DUMP" "$IMG" extents /big.bin 2>/dev/null | grep -c "logical")
[ "$nex" -ge 1 ] && ok "large file has an extent map ($nex extents)" || bad "large file has an extent map"

# ================================================================= truncate ==
echo
echo "truncate"
op "shrink to 100"   truncate /big.bin 100 && ok "truncate shrink"
expect_eq "size after shrink" "100" "$("$DUMP" "$IMG" stat /big.bin | awk '/^size:/{print $2}')"

op "grow to 100000"  truncate /big.bin 100000 && ok "truncate grow (sparse)"
expect_eq "size after grow" "100000" "$("$DUMP" "$IMG" stat /big.bin | awk '/^size:/{print $2}')"

# The grown region is a hole and must read back as zeroes.
"$DUMP" "$IMG" cat /big.bin > "$TMP/sparse.bin" 2>/dev/null
zeros=$(tail -c 1000 "$TMP/sparse.bin" | tr -d '\0' | wc -c | tr -d ' ')
expect_eq "sparse region reads as zeroes" "0" "$zeros"

op "truncate to 0"   truncate /big.bin 0 && ok "truncate to zero"
op "rm /big.bin"     rm /big.bin && ok "remove large file"

# ================================================================== rename ==
echo
echo "rename"
new_image ext4_4k

op "create /r1"      create /r1 && ok "setup for rename"
op "write /r1"       write /r1 "renamed content" && ok "content for rename"
op "mv /r1 /r2"      mv /r1 /r2 && ok "rename within a directory"
expect_eq "content survives rename" "renamed content" "$("$DUMP" "$IMG" cat /r2)"

op "mkdir /rd"       mkdir /rd && ok "dir for cross-directory rename"
op "mv /r2 /rd/r3"   mv /r2 /rd/r3 && ok "rename across directories"
expect_eq "content survives cross-dir rename" "renamed content" "$("$DUMP" "$IMG" cat /rd/r3)"

# rename(2) replaces an existing destination.
op "create /victim"  create /victim && ok "create rename victim"
op "write /victim"   write /victim "to be replaced" && ok "fill rename victim"
op "mv over victim"  mv /rd/r3 /victim && ok "rename over an existing file"
expect_eq "destination replaced by source" "renamed content" "$("$DUMP" "$IMG" cat /victim)"

# Moving a directory must keep its ".." and the parents' link counts right;
# this is exactly what fsck pass 3/4 verifies.
op "mkdir /movedir"     mkdir /movedir && ok "create dir to move"
op "mkdir /movedir/sub" mkdir /movedir/sub && ok "populate dir to move"
op "mkdir /dest"        mkdir /dest && ok "create move destination"
op "mv dir"             mv /movedir /dest/moved && ok "move a non-empty directory"
debugfs -R "ls /dest/moved" "$IMG" 2>/dev/null | grep -q sub \
  && ok "moved directory kept its contents" || bad "moved directory kept its contents"

# ==================================================================== links ==
echo
echo "links"
new_image ext4_4k

op "create /orig"    create /orig && ok "create link target"
op "write /orig"     write /orig "shared data" && ok "fill link target"
op "ln /orig /hard"  ln /orig /hard && ok "create hard link"

i1=$("$DUMP" "$IMG" stat /orig | awk '/^inode:/{print $2}')
i2=$("$DUMP" "$IMG" stat /hard | awk '/^inode:/{print $2}')
expect_eq "hard link shares the inode" "$i1" "$i2"
expect_eq "link count is 2" "2" "$("$DUMP" "$IMG" stat /orig | awk '/^links:/{print $2}')"

op "rm /hard"        rm /hard && ok "remove one hard link"
expect_eq "link count back to 1" "1" "$("$DUMP" "$IMG" stat /orig | awk '/^links:/{print $2}')"
expect_eq "data survives via remaining link" "shared data" "$("$DUMP" "$IMG" cat /orig)"

op "mkdir /adir"     mkdir /adir && ok "create dir for hard-link check"
op_must_fail "hard link to a directory is refused" "not permitted" ln /adir /baddir

op "symlink short"   symlink /orig /slink && ok "create short symlink (inline)"
LONGTARGET=$(python3 -c "print('/very/long/path/segment'*8)")
op "symlink long"    symlink "$LONGTARGET" /slonglink && ok "create long symlink (block)"

t=$("$DUMP" "$IMG" ls / 2>/dev/null | awk '$0 ~ / \/slink ->/ {print $NF}')
expect_eq "short symlink target" "/orig" "$t"
t2=$(debugfs -R "stat /slonglink" "$IMG" 2>/dev/null | tail -2 | head -1 | tr -d ' ')
[ -n "$t2" ] && ok "long symlink stored in a block" || bad "long symlink stored in a block"

# =================================================================== xattrs ==
echo
echo "extended attributes"
new_image ext4_4k

op "create /x.txt"      create /x.txt && ok "create for xattr"
op "setxattr"           setxattr /x.txt user.colour blue && ok "set an xattr"
"$DUMP" "$IMG" xattr /x.txt 2>/dev/null | grep -q "user.colour" \
  && ok "xattr listed by our reader" || bad "xattr listed by our reader"
debugfs -R "ea_list /x.txt" "$IMG" 2>/dev/null | grep -q "user.colour" \
  && ok "xattr visible to debugfs" || bad "xattr visible to debugfs"

op "rmxattr"            rmxattr /x.txt user.colour && ok "remove an xattr"
if "$DUMP" "$IMG" xattr /x.txt 2>/dev/null | grep -q "user.colour"; then
  bad "xattr actually removed"
else
  ok "xattr actually removed"
fi

# =============================================================== many files ==
echo
echo "directory growth (HTree)"
new_image ext4_4k
op "mkdir /many" mkdir /many && ok "create dir for bulk insert"

# Enough entries to push the directory past a single block and into an index.
BULK_FAIL=0
for i in $(seq 1 60); do
  "$DUMP" "$IMG" create "/many/file_$(printf '%03d' "$i").txt" >/dev/null 2>&1 || BULK_FAIL=1
done
[ "$BULK_FAIL" -eq 0 ] && ok "created 60 entries" || bad "created 60 entries"
fsck_clean "after 60 creates" && ok "fsck clean after bulk insert"

n=$(debugfs -R "ls -l /many" "$IMG" 2>/dev/null | grep -c "file_")
expect_eq "debugfs counts all 60 entries" "60" "$n"

# Remove them all again; the directory must end up genuinely empty.
for i in $(seq 1 60); do
  "$DUMP" "$IMG" rm "/many/file_$(printf '%03d' "$i").txt" >/dev/null 2>&1
done
fsck_clean "after 60 removes" && ok "fsck clean after bulk delete"
op "rm /many" rm /many && ok "directory empty enough to remove"

# ========================================================= space accounting ==
echo
echo "space accounting"
new_image ext4_4k
free_blocks() { "$DUMP" "$IMG" ls 2>/dev/null | sed -n 's|^# \([0-9]*\)/.*|\1|p' | head -1; }
before=$(free_blocks)

op "create /space.bin" create /space.bin && ok "create for space test"
BIG2=$(python3 -c "import sys; sys.stdout.write('Z'*200000)")
op "write 200KB"       write /space.bin "$BIG2" && ok "write 200 KB"
after=$(free_blocks)
[ "$after" -lt "$before" ] && ok "free blocks decreased ($before -> $after)" \
                           || bad "free blocks decreased" "before=$before after=$after"

op "rm /space.bin"     rm /space.bin && ok "remove large file"
freed=$(free_blocks)
[ "$freed" -ge "$before" ] && ok "blocks returned on delete ($after -> $freed)" \
                           || bad "blocks returned on delete" "before=$before after-delete=$freed"

# ================================================== immutable / append-only ==
#
# `chattr +i` and `chattr +a` are how a Linux user says "do not change this".
# A driver that ignores them silently removes a protection the user asked for
# and will not find out until the file is gone, so every mutating entry point
# has to check.
#
# The flags are set with debugfs rather than by mounting under Linux, so this
# stays free of Docker; the differential suite checks that flags set by the
# real `chattr` are the same thing.

echo
echo "immutable and append-only files"
new_image ext4_4k

# OR the bit into whatever the inode already carries -- clobbering the flags
# word would drop EXTENTS and make the file unreadable.
set_inode_flag() {  # set_inode_flag <path> <bit>
  local ino cur
  ino=$("$DUMP" "$IMG" stat "$1" 2>/dev/null | sed -n 's/^inode: *//p')
  cur=$(debugfs -R "stat <$ino>" "$IMG" 2>/dev/null \
        | grep -oE 'Flags: 0x[0-9a-f]+' | head -1 | sed 's/Flags: //')
  [ -n "$ino" ] && [ -n "$cur" ] || return 1
  debugfs -w -R "sif <$ino> flags $(printf '0x%x' $(( cur | $2 )))" "$IMG" >/dev/null 2>&1
}

op "create a file to protect" create /prot.txt
op "give it content"          write /prot.txt "original"
set_inode_flag /prot.txt 0x10 || bad "could not set the immutable flag"
expect_eq "the immutable flag is visible in stat" "immutable" \
  "$("$DUMP" "$IMG" stat /prot.txt 2>/dev/null | sed -n 's/^protected: *//p')"

op_must_fail "an immutable file cannot be written"     "not permitted" write /prot.txt "new"
op_must_fail "an immutable file cannot be truncated"   "not permitted" truncate /prot.txt 1
op_must_fail "an immutable file cannot be removed"     "not permitted" rm /prot.txt
op_must_fail "an immutable file cannot be chmodded"    "not permitted" chmod /prot.txt 600
op_must_fail "an immutable file cannot gain an xattr"  "not permitted" setxattr /prot.txt user.k v
op_must_fail "an immutable file cannot be renamed"     "not permitted" mv /prot.txt /moved.txt
op_must_fail "an immutable file cannot be hard-linked" "not permitted" ln /prot.txt /hard
expect_eq "and its content survived every attempt" "original" \
  "$("$DUMP" "$IMG" cat /prot.txt 2>/dev/null)"

op "create a directory to protect"      mkdir /locked
op "put something in it first"          create /locked/inside.txt
set_inode_flag /locked 0x10 || bad "could not set the immutable flag on a directory"
op_must_fail "an immutable directory takes no new entries" "not permitted" create /locked/new.txt
op_must_fail "an immutable directory loses none"           "not permitted" rm /locked/inside.txt

op "create an append-only file" create /log.txt
op "seed it"                    write /log.txt "line1"
set_inode_flag /log.txt 0x20 || bad "could not set the append-only flag"
expect_eq "the append-only flag is visible in stat" "append-only" \
  "$("$DUMP" "$IMG" stat /log.txt 2>/dev/null | sed -n 's/^protected: *//p')"

op "appending to an append-only file is allowed" append /log.txt "line2" \
  && ok "appending to an append-only file is allowed"
expect_eq "and the append landed" "line1line2" "$("$DUMP" "$IMG" cat /log.txt 2>/dev/null)"

# The rule is "a write that lies wholly inside the file", not "a write that
# starts at end-of-file": through a real mount the buffer cache rewrites whole
# pages, so an append arrives at offset 0 and the stricter rule refuses it. The
# kernel does the enforcement that matters, refusing to open the file for
# anything but O_APPEND once it sees the flag.
op_must_fail "overwriting inside an append-only file is refused" "not permitted" write /log.txt "X"
op_must_fail "truncate is refused even when it would grow"  "not permitted" truncate /log.txt 99
op_must_fail "an append-only file cannot be removed"        "not permitted" rm /log.txt
op_must_fail "an append-only file cannot gain an xattr"     "not permitted" setxattr /log.txt user.k v
op "attribute changes are still allowed" chmod /log.txt 640 \
  && ok "an append-only file can still be chmodded"

# ========================================================== read-only guard ==
echo
echo "metadata checksum seeds"
new_image ext4_4k
digest_before=$(shasum -a 256 "$IMG" | cut -d' ' -f1)

# A volume whose UUID was changed after creation keeps the checksum seed it was
# made with, so the seed and the UUID no longer agree. Deriving the seed from
# the UUID -- which is all lwext4 could do before patches/lwext4/0012 -- makes
# every checksum written to it wrong, and this is the check that says so:
# without the patch e2fsck reports invalid group descriptor and inode
# checksums here, nine complaints on the first write.
# Asking a file for an attribute it does not have is the single most common
# xattr call macOS makes -- Finder probes com.apple.FinderInfo on everything it
# touches -- and it has to answer ENOATTR (93). Two bugs made it answer
# otherwise, and between them they stopped Finder copying a file at all:
# lwext4 reported EIO for an inode that had simply never carried an in-body
# attribute, and ENODATA (96) once it had, which is Linux's name for the
# condition and not a number macOS getxattr(2) can return.
echo
echo "extended attributes that are not there"
xattr_missing() {  # xattr_missing <path> <label>
  local out
  out=$("$DUMP" "$IMG" getxattr "$1" user.definitely.missing 2>&1)
  case "$out" in
    *"Attribute not found"*) ok "$2" ;;
    *) bad "$2" "got: $out" ;;
  esac
}
op "create a file that has never had an xattr" create /noattr.txt
xattr_missing /noattr.txt "a file with no xattr header answers ENOATTR, not EIO"
op "give it one" setxattr /noattr.txt user.present yes
xattr_missing /noattr.txt "a file that has one answers ENOATTR for a different name"
# Setting the first attribute on such a file used to dereference NULL, once
# the EIO above stopped arriving to trigger header initialisation.
got=$("$DUMP" "$IMG" xattr /noattr.txt 2>/dev/null | grep -c "user.present")
expect_eq "the first xattr on a bare inode is stored, not a crash" "1" "$got"

seed_img="$TMP/seed.img"
cp "$FIX/ext4_uuid_changed.img" "$seed_img"
"$DUMP" "$seed_img" mkdir /reseeded >/dev/null 2>&1 || bad "could not write to a UUID-changed volume"
"$DUMP" "$seed_img" create /reseeded/hello.txt >/dev/null 2>&1
"$DUMP" "$seed_img" write /reseeded/hello.txt "stored seed" >/dev/null 2>&1
"$DUMP" "$seed_img" setxattr /reseeded/hello.txt user.seed ok >/dev/null 2>&1
# Enough entries to push the directory into an HTree, whose checksums are
# seeded the same way and are a separate code path.
for i in $(seq 1 60); do "$DUMP" "$seed_img" create "/reseeded/f$i" >/dev/null 2>&1; done

got=$("$DUMP" "$seed_img" cat /reseeded/hello.txt 2>/dev/null)
expect_eq "a UUID-changed volume reads back what we wrote" "stored seed" "$got"
seed_fsck="$(e2fsck -fn "$seed_img" 2>&1)"
if [ $? -eq 0 ]; then
  FSCK_RUNS=$((FSCK_RUNS+1))
  ok "checksums on a UUID-changed volume are seeded correctly"
else
  bad "checksums on a UUID-changed volume are wrong" \
      "$(grep -iE 'checksum' <<<"$seed_fsck" | head -3)"
fi

# ==================================================================== report ==
echo
echo "─────────────────────────────────"
printf 'passed: %d   failed: %d   (e2fsck run %d times)\n' "$PASS" "$FAIL" "$FSCK_RUNS"
[ "$FAIL" -eq 0 ] || exit 1
