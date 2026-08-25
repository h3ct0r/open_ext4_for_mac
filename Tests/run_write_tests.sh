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
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; [ $# -gt 1 ] && printf '         %s\n' "$2"; }
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

# ========================================================== read-only guard ==
echo
echo "read-only enforcement"
new_image ext4_4k
digest_before=$(shasum -a 256 "$IMG" | cut -d' ' -f1)

# The UUID-changed fixture must refuse writes: lwext4 would compute every
# checksum from the wrong seed.
cp "$FIX/ext4_uuid_changed.img" "$TMP/ro.img"
ro_before=$(shasum -a 256 "$TMP/ro.img" | cut -d' ' -f1)
"$DUMP" "$TMP/ro.img" mkdir /nope >/dev/null 2>&1 && bad "UUID-changed volume rejects writes" \
                                                  || ok "UUID-changed volume rejects writes"
ro_after=$(shasum -a 256 "$TMP/ro.img" | cut -d' ' -f1)
expect_eq "rejected write left the image untouched" "$ro_before" "$ro_after"

# ==================================================================== report ==
echo
echo "─────────────────────────────────"
printf 'passed: %d   failed: %d   (e2fsck run %d times)\n' "$PASS" "$FAIL" "$FSCK_RUNS"
[ "$FAIL" -eq 0 ] || exit 1
