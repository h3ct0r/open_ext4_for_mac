#!/usr/bin/env bash
# Build the fuzzing seed corpus into .fuzz/seeds.
#
# A fuzzer that starts from random bytes never sees an ext4 superblock: the
# magic alone is two bytes it would have to guess in the right place, and
# everything interesting is gated behind a checksum it would then have to
# recompute. So the corpus is real mke2fs output, small enough to mutate
# quickly and shaped so that every parser the driver owns is reachable from
# something in it.
#
# Small on purpose. `mke2fs -g <blocks_per_group>` is the size lever: -b 1024
# -g 1024 puts two block groups in 2 MiB, and -N keeps the inode tables from
# dominating the image. A 3 MiB seed mutates ~100x faster than a 128 MiB
# fixture and reaches the same code.
#
# Idempotent: a seed that already exists and still passes its check is left
# alone, so this is cheap to call from every campaign. FORCE=1 rebuilds.
#
# Exits 77 (SKIP) when e2fsprogs is not installed -- a machine without mke2fs
# has not failed anything, it just cannot build fixtures.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

export PATH="/opt/homebrew/opt/e2fsprogs/sbin:/opt/homebrew/opt/e2fsprogs/bin:$PATH"

if ! command -v mke2fs >/dev/null 2>&1 || ! command -v debugfs >/dev/null 2>&1; then
  echo "seeds: mke2fs/debugfs not found; brew install e2fsprogs"
  exit 77
fi

OUT="$ROOT/.fuzz/seeds"
DUMP="$ROOT/build/bin/ext4dump"
mkdir -p "$OUT"

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/ext4-seeds.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

MADE=0; KEPT=0; SKIPPED=0
note() { echo "  $*"; }

# A seed is rebuilt unless it exists and is non-empty. There is no checksum
# over the recipe: the recipes are in this file, and FORCE=1 is the lever when
# one changes. (A cache keyed on this script's hash lives in CI, which is the
# right place for it.)
want() {  # want <name> -> 0 if it must be built
  local f="$OUT/$1.img"
  if [ -z "${FORCE:-}" ] && [ -s "$f" ]; then KEPT=$((KEPT+1)); return 1; fi
  return 0
}

blank() {  # blank <path> <MiB>
  rm -f "$1"; dd if=/dev/zero of="$1" bs=1m count="$2" 2>/dev/null
}

# ---------------------------------------------------------------- content --
printf 'hello from a seed\n'                   > "$STAGE/small.txt"
head -c 300000 /dev/urandom                    > "$STAGE/mid.bin"
head -c 700    /dev/urandom | base64 | head -c 700 > "$STAGE/big.xattr"
printf 'x%.0s' $(seq 1 60)                     > "$STAGE/slowlink"

# The shared population script. Everything here is reachable from the root, so
# the harness's walk finds all of it:
#
#   /many        300 short names. At 1 KiB blocks that is ~7 leaf blocks, so
#                the directory is indexed and the dx root has real entries --
#                which is what makes ext4b_lookup descend rather than scan.
#   /docs        an in-inode xattr and one whose 700-byte value cannot fit in
#                the inode, so it lands in an xattr BLOCK. Two different
#                parsers; a corpus with only the first never reaches the
#                second.
#   fast + slow symlink, a hardlink, a character device, an empty directory.
populate() {  # populate <img> <name-count> [linear]
  local img="$1" names="${2:-300}" many_style="${3:-indexed}"
  {
    echo "mkdir /docs"
    echo "mkdir /empty"
    echo "cd /docs"
    echo "write $STAGE/small.txt small.txt"
    echo "write $STAGE/mid.bin mid.bin"
    echo "cd /"
    echo "symlink /fastlink docs/small.txt"
    echo "symlink /slowlink /$(cat "$STAGE/slowlink")"
    echo "ln /docs/small.txt /hardlink"
    echo "sif /docs/small.txt links_count 2"
    # Relative, deliberately. debugfs's symlink strips a leading slash and
    # its mknod does not, so "mknod /chardev" creates an entry whose NAME is
    # "/chardev" -- which e2fsck then reports as illegal characters.
    echo "mknod chardev c 1 3"
    echo "quit"
  } | debugfs -w -f /dev/stdin "$img" >/dev/null 2>&1

  # xattrs, separately: ea_set needs the file to exist already, and an ibody
  # entry and a block entry have to be set one at a time to land in different
  # places.
  {
    echo "ea_set /docs/small.txt user.small tiny"
    echo "ea_set -f $STAGE/big.xattr /docs/mid.bin user.big"
    echo "quit"
  } | debugfs -w -f /dev/stdin "$img" >/dev/null 2>&1

  # /many goes in through OUR tool, not debugfs.
  #
  # debugfs adds directory entries without ever building an htree: 300 names
  # from it give a linear directory of seven blocks with the INDEX flag
  # clear. A corpus built that way never reaches ext4_dir_idx.c at all --
  # ext4_dir_find_entry only takes the dx path on an indexed directory -- and
  # the coverage gate is what said so: the read-only pass covered
  # ext4_dir_find_in_block and not one dx function, on a corpus whose whole
  # point was the htree. lwext4 does build the index, so the seed is built by
  # the thing being tested. e2fsck is still the judge of the result.
  if [ -x "$DUMP" ] && [ "$many_style" != "linear" ]; then
    {
      echo "mkdir /many"
      local i
      for i in $(seq 1 "$names"); do echo "create /many/n$i"; done
    } | "$DUMP" "$img" script - >/dev/null 2>&1
  else
    {
      echo "mkdir /many"
      echo "cd /many"
      local i
      for i in $(seq 1 "$names"); do echo "write $STAGE/small.txt n$i"; done
      echo "quit"
    } | debugfs -w -f /dev/stdin "$img" >/dev/null 2>&1
  fi
}

# EXT4_INODE_FLAG_INDEX is 0x1000. A directory without it is a linear one,
# and a corpus of linear directories tests half of what it claims to.
check_indexed() {  # check_indexed <name> <img>
  local flags
  flags=$(debugfs -R "stat /many" "$2" 2>/dev/null | sed -nE 's/.*Flags: (0x[0-9a-f]+).*/\1/p')
  if [ -z "$flags" ]; then
    note "$1: /many is missing entirely"; return 1
  fi
  if [ $(( flags & 0x1000 )) -ne 0 ]; then
    note "$1: /many is an indexed directory (flags $flags)"; return 0
  fi
  note "$1: /many is NOT indexed (flags $flags) -- the htree code is unreachable"
  return 1
}

# An extent tree one level deep needs more extents than the 60-byte inode
# array holds (four). Interleaved writes through our own tool produce that
# without needing a mounted filesystem; if the tool is not built, the seed is
# still valid, just shallower, and says so.
deepen_extents() {  # deepen_extents <img>
  [ -x "$DUMP" ] || { note "(no ext4dump: extent depth stays 0 in $(basename "$1"))"; return 0; }
  # Two 1 MiB files written 16 KiB at a time, round-robin: each ends up with
  # dozens of extents, which is more than the inode's 60-byte array holds, so
  # the tree grows an index node. Two and not four, because four megabytes do
  # not fit in a three-megabyte seed and the failure is silent.
  "$DUMP" "$1" interleave 2 1 16 round >/dev/null 2>&1 || true
}

# Did the population actually take?
#
# debugfs reports nothing when a command fails: it prints its prompt and moves
# on. The first version of this script produced an s01 with no symlinks, no
# hardlink and no device node -- the inode table was full and every one of
# those commands failed silently -- and e2fsck called the result clean,
# because a filesystem missing things you meant to put in it is a perfectly
# valid filesystem. A corpus like that is worse than a small one: the symlink
# and xattr parsers would never be reached and the campaign would still look
# like it was covering them.
check_content() {  # check_content <name> <img> <expected-name>...
  local name="$1" img="$2"; shift 2
  local listing missing=""
  listing=$(debugfs -R "ls -l /" "$img" 2>/dev/null)
  local want
  for want in "$@"; do
    grep -qE "[[:space:]]$want\$" <<<"$listing" || missing="$missing $want"
  done
  if [ -n "$missing" ]; then
    note "$name: MISSING from the root:$missing"
    printf '%s\n' "$listing" | sed 's/^/        /' | head -12
    return 1
  fi
  note "$name: content present ($# names checked)"
  return 0
}

check_fsck() {  # check_fsck <img> <name> [expect]
  local out rc
  out=$(e2fsck -fn "$2" 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then note "$1: e2fsck clean"; return 0; fi
  if [ -n "${3:-}" ] && grep -qi "$3" <<<"$out"; then
    note "$1: e2fsck reports exactly its condition ($3)"; return 0
  fi
  note "$1: UNEXPECTED e2fsck result (rc=$rc)"
  printf '%s\n' "$out" | head -6 | sed 's/^/        /'
  return 1
}

# An xattr big enough to need its own block is a different parser from one
# that fits in the inode. Both must exist, or the corpus covers half of it.
check_xattrs() {  # check_xattrs <name> <img>
  local name="$1" img="$2" small big
  small=$(debugfs -R "ea_list /docs/small.txt" "$img" 2>/dev/null)
  big=$(debugfs -R "ea_list /docs/mid.bin" "$img" 2>/dev/null)
  if grep -q "user.small" <<<"$small" && grep -q "user.big" <<<"$big"; then
    note "$name: xattrs present (one in the inode, one in a block)"
    return 0
  fi
  note "$name: MISSING xattrs (ibody: $(grep -c . <<<"$small"), block: $(grep -c . <<<"$big"))"
  return 1
}

FAILED=0

# ------------------------------------------------------- s01 ext4 1k, csum --
# The workhorse. metadata_csum on, so raw mutation is gated by checksums and
# only the restamping mutator gets past them -- which is the realistic case.
if want s01; then
  img="$OUT/s01.img"; blank "$img" 5
  mke2fs -q -t ext4 -b 1024 -g 1024 -N 512 -I 256 -L s01 \
    -O metadata_csum,64bit,flex_bg,extent,dir_index,^resize_inode \
    -J size=1 "$img" 2>/dev/null
  populate "$img"
  deepen_extents "$img"
  check_content s01 "$img" docs empty many fastlink slowlink hardlink chardev || FAILED=1
  check_indexed s01 "$img" || FAILED=1
  check_xattrs s01 "$img" || FAILED=1
  check_fsck s01 "$img" || FAILED=1
  MADE=$((MADE+1))
fi

# ------------------------------------------- s02 ext4 1k, no metadata_csum --
# The same volume with the gate off, so a raw byte flip reaches the inode,
# directory, extent and xattr parsers directly. Half the value of the corpus
# is here: it is the seed the dumb mutator can actually get past.
if want s02; then
  img="$OUT/s02.img"; blank "$img" 5
  mke2fs -q -t ext4 -b 1024 -g 1024 -N 512 -I 256 -L s02 \
    -O ^metadata_csum,^64bit,flex_bg,extent,dir_index,^resize_inode \
    -J size=1 "$img" 2>/dev/null
  populate "$img"
  deepen_extents "$img"
  check_content s02 "$img" docs empty many fastlink slowlink hardlink chardev || FAILED=1
  check_indexed s02 "$img" || FAILED=1
  check_xattrs s02 "$img" || FAILED=1
  check_fsck s02 "$img" || FAILED=1
  MADE=$((MADE+1))
fi

# ----------------------------------------------------------- s03 ext4 4 KiB --
# 4 KiB is the production block size, and every byte offset in the driver is
# computed differently for it. 200 entries is past one leaf at 4 KiB.
# No journal here, and not by preference: e2fsprogs will not build one
# smaller than 1024 blocks, which at a 4 KiB block size is 4 MiB, and it
# refuses a filesystem that is mostly journal. A 4 KiB seed with a journal
# would have to be ~32 MiB, which is four times -max_len and would mutate
# four times slower than the whole rest of the corpus put together. So jbd2
# is exercised at 1 KiB (s01, s05, s06) and the 4 KiB journal offsets are a
# stated gap, not an oversight.
if want s03; then
  img="$OUT/s03.img"; blank "$img" 6
  mke2fs -q -t ext4 -b 4096 -g 512 -N 512 -I 256 -L s03 \
    -O metadata_csum,64bit,flex_bg,extent,dir_index,^resize_inode,^has_journal \
    "$img" 2>/dev/null
  populate "$img" 200
  deepen_extents "$img"
  check_content s03 "$img" docs empty many fastlink slowlink hardlink chardev || FAILED=1
  check_indexed s03 "$img" || FAILED=1
  check_xattrs s03 "$img" || FAILED=1
  check_fsck s03 "$img" || FAILED=1
  MADE=$((MADE+1))
fi

# ------------------------------------------------------------- s04 ext2 1k --
# No extents and no journal: a 300 KiB file at 1 KiB blocks fills the twelve
# direct entries, the single indirect block and reaches into the double, which
# is the indirect mapper in ext4_fs.c -- code no ext4 seed touches at all.
if want s04; then
  img="$OUT/s04.img"; blank "$img" 2
  mke2fs -q -t ext2 -b 1024 -g 1024 -N 128 -L s04 "$img" 2>/dev/null
  {
    echo "mkdir /docs"
    echo "cd /docs"
    echo "write $STAGE/mid.bin mid.bin"
    echo "write $STAGE/small.txt small.txt"
    echo "cd /"
    echo "symlink /fastlink docs/small.txt"
    echo "quit"
  } | debugfs -w -f /dev/stdin "$img" >/dev/null 2>&1
  check_fsck s04 "$img" || FAILED=1
  MADE=$((MADE+1))
fi

# ------------------------------------------------------------- s05 ext3 1k --
# A journal without extents, and an indexed directory: the combination the
# ext4-only seeds never produce.
if want s05; then
  img="$OUT/s05.img"; blank "$img" 4
  mke2fs -q -t ext3 -b 1024 -g 1024 -N 512 -L s05 -O dir_index -J size=1 "$img" 2>/dev/null
  populate "$img"
  check_content s05 "$img" docs empty many fastlink slowlink hardlink chardev || FAILED=1
  check_indexed s05 "$img" || FAILED=1
  check_xattrs s05 "$img" || FAILED=1
  check_fsck s05 "$img" || FAILED=1
  MADE=$((MADE+1))
fi

# -------------------------------------------------------- s06 dirty journal --
# The only seed that makes a read-write mount run jbd2 recovery. debugfs's
# journal verbs write a transaction into the log and leave the superblock
# needing recovery, which is exactly what a power cut leaves.
if want s06; then
  img="$OUT/s06.img"; blank "$img" 4
  mke2fs -q -t ext4 -b 1024 -g 1024 -N 512 -I 256 -L s06 \
    -O metadata_csum,64bit,flex_bg,extent,dir_index,^resize_inode \
    -J size=1 "$img" 2>/dev/null
  populate "$img"
  # journal_write takes a FILE whose contents become the block data; without
  # it the command is a no-op that reports nothing, which is how the first
  # version of this produced a perfectly clean "dirty" seed.
  #
  # And the payload has to be the blocks' OWN current contents, not random
  # bytes. The first version staged /dev/urandom for blocks 1, 2 and 3 --
  # block 1 is the superblock on a 1 KiB volume -- so replaying this seed
  # wrote garbage over the superblock and the very next thing the driver did
  # was shift by a 955-million-bit log_block_size. That is a real finding (a
  # journal that replays a superblock is trusted rather than re-validated)
  # but it is not what this seed is for: s06 is meant to be a volume with an
  # ordinary unreplayed journal, so that recovery RUNS. A seed that destroys
  # the volume in its first millisecond tests recovery's error path and
  # nothing else. The hostile version is kept as a fixture instead.
  #
  # Blocks 24 and 25 are inode-table blocks here, well clear of the
  # superblock and the descriptors; staging their own bytes makes the replay
  # a no-op that still has to be performed.
  dd if="$img" of="$STAGE/jpayload" bs=1024 skip=24 count=2 2>/dev/null
  {
    echo "journal_open"
    echo "journal_write -b 24,25 $STAGE/jpayload"
    echo "journal_write -r 40,41 $STAGE/jpayload"
    echo "journal_close"
    echo "ssv state 0"          # not cleanly unmounted
    echo "quit"
  } | debugfs -w -f /dev/stdin "$img" >/dev/null 2>&1
  # The precise question is whether INCOMPAT_RECOVER is set, not what e2fsck
  # says about it: `e2fsck -fn` on a dirty volume prints "skipping journal
  # recovery because doing a read-only filesystem check" and then exits 0.
  if dumpe2fs -h "$img" 2>/dev/null | grep -q "needs_recovery"; then
    note "s06: e2fsck reports exactly its condition (needs recovery)"
  else
    # Fallback: cut a real write stream mid-transaction with our own tool.
    if [ -x "$DUMP" ]; then
      EXT4DUMP_FAIL_AFTER=40 "$DUMP" "$img" script - >/dev/null 2>&1 <<'SCRIPT'
mkdir /dirty
create /dirty/a
write /dirty/a some-bytes
SCRIPT
    fi
    if dumpe2fs -h "$img" 2>/dev/null | grep -q "needs_recovery"; then
      note "s06: dirtied by a cut write stream (debugfs route did not take)"
    else
      note "s06: COULD NOT make an unreplayed journal"
      FAILED=1
    fi
  fi
  MADE=$((MADE+1))
fi

# -------------------------------------------------------------- s07 orphans --
# Two inodes on the orphan list with no directory entry: what an interrupted
# unlink leaves, and the only thing that makes mount-time orphan cleanup run.
if want s07; then
  # ^orphan_file matters: e2fsprogs 1.47 turns the orphan_file feature on by
  # default, and with it the classic s_last_orphan chain is not what an
  # interrupted unlink leaves. This seed is about the chain, so the feature
  # is off and the chain is built by hand.
  img="$OUT/s07.img"; blank "$img" 4
  mke2fs -q -t ext4 -b 1024 -g 1024 -N 512 -I 256 -L s07 \
    -O metadata_csum,64bit,flex_bg,extent,dir_index,^resize_inode,^orphan_file \
    -J size=1 "$img" 2>/dev/null
  populate "$img"
  # Two files, unlinked from their directory but left allocated, chained
  # through i_dtime the way ext4's orphan list does it.
  a=$(debugfs -R "stat /many/n1" "$img" 2>/dev/null | sed -n 's/^Inode: \([0-9]*\).*/\1/p')
  b=$(debugfs -R "stat /many/n2" "$img" 2>/dev/null | sed -n 's/^Inode: \([0-9]*\).*/\1/p')
  if [ -n "$a" ] && [ -n "$b" ]; then
    {
      echo "unlink /many/n1"
      echo "unlink /many/n2"
      echo "sif <$a> links_count 0"
      echo "sif <$b> links_count 0"
      echo "sif <$a> dtime $b"      # a -> b
      echo "sif <$b> dtime 0"       # b -> end of list
      echo "ssv last_orphan $a"
      echo "quit"
    } | debugfs -w -f /dev/stdin "$img" >/dev/null 2>&1
    if dumpe2fs -h "$img" 2>/dev/null | grep -qi "First orphan inode:"; then
      note "s07: superblock names the orphan list head ($(dumpe2fs -h "$img" 2>/dev/null | sed -n 's/First orphan inode: *//p'))"
    else
      note "s07: COULD NOT build an orphan list"
      FAILED=1
    fi
  else
    note "s07: could not resolve the inodes to orphan"
    FAILED=1
  fi
  MADE=$((MADE+1))
fi

# ----------------------------------------------------- s08 refused features --
# The named-refusal and read-only-downgrade paths in ext4b_probe are code too,
# and nothing else in the corpus reaches them. Whatever the local mke2fs can
# build gets a seed; the rest are skipped by name rather than silently.
for feat in inline_data encrypt casefold quota project; do
  name="s08_$feat"
  if want "$name"; then
    img="$OUT/$name.img"; blank "$img" 3
    if mke2fs -q -t ext4 -b 1024 -g 1024 -N 256 -I 256 -L "${name:0:16}" \
         -O "metadata_csum,64bit,extent,dir_index,^resize_inode,$feat" \
         -J size=1 "$img" 2>/dev/null; then
      note "$name: built"
      MADE=$((MADE+1))
    else
      rm -f "$img"
      note "$name: this mke2fs cannot create it; skipped"
      SKIPPED=$((SKIPPED+1))
    fi
  fi
done
if want s08_bigalloc; then
  img="$OUT/s08_bigalloc.img"; blank "$img" 8
  if mke2fs -q -t ext4 -b 4096 -C 32768 -N 128 -L s08_bigalloc \
       -O metadata_csum,64bit,extent,dir_index,bigalloc,^resize_inode \
       -J size=1 "$img" 2>/dev/null; then
    note "s08_bigalloc: built"; MADE=$((MADE+1))
  else
    rm -f "$img"; note "s08_bigalloc: this mke2fs cannot create it; skipped"
    SKIPPED=$((SKIPPED+1))
  fi
fi

# --------------------------------------------------------------- s09 meta_bg --
# Descriptors spread through the volume instead of following the superblock.
# Both statfs helpers return ENOTSUP on it by design, so this seed is about
# whether the refusal holds under mutation rather than about the walk.
if want s09; then
  img="$OUT/s09.img"; blank "$img" 5
  if mke2fs -q -t ext4 -b 1024 -g 1024 -N 512 -I 256 -L s09 \
       -O metadata_csum,64bit,extent,dir_index,meta_bg,^resize_inode \
       -J size=1 "$img" 2>/dev/null; then
    # "linear": /many goes in through debugfs here, not through our own tool.
    #
    # Not a preference. Creating files on a meta_bg volume WITH THIS DRIVER
    # produces a filesystem e2fsck rejects: 150 creates give 59 complaints of
    # the form "references inode N in group 1 where _INODE_UNINIT is set".
    # The identical volume without meta_bg is clean, so it is the feature and
    # not the tool. ext4b_probe lists META_BG in INCOMPAT_SUPPORTED and
    # returns USABLE, so the driver will mount such a volume read-write and
    # damage it -- an open finding for A8, with the corrupted image kept at
    # .fuzz/min/hostile-meta-bg-uninit.img. Until that is fixed, this seed is
    # about descriptor placement, which is what it was always for.
    populate "$img" 300 linear
    check_content s09 "$img" docs empty many fastlink slowlink hardlink chardev || FAILED=1
  check_xattrs s09 "$img" || FAILED=1
  check_fsck s09 "$img" || FAILED=1
    MADE=$((MADE+1))
  else
    rm -f "$img"; note "s09: this mke2fs cannot create meta_bg; skipped"
    SKIPPED=$((SKIPPED+1))
  fi
fi

# ------------------------------------------------------- s10 128-byte inodes --
# No extra_isize, so there is no room in the inode body for an xattr at all
# and every one has to go to a block. The "no ibody space" path.
if want s10; then
  img="$OUT/s10.img"; blank "$img" 4
  mke2fs -q -t ext4 -b 1024 -g 1024 -N 512 -I 128 -L s10 \
    -O ^metadata_csum,^64bit,extent,dir_index,^resize_inode \
    -J size=1 "$img" 2>/dev/null
  populate "$img"
  check_content s10 "$img" docs empty many fastlink slowlink hardlink chardev || FAILED=1
  check_indexed s10 "$img" || FAILED=1
  check_xattrs s10 "$img" || FAILED=1
  check_fsck s10 "$img" || FAILED=1
  MADE=$((MADE+1))
fi

# ------------------------------------------------------------------ report --
echo ""
echo "  seeds: $MADE built, $KEPT kept, $SKIPPED skipped -> $OUT"
ls -1 "$OUT" 2>/dev/null | sed 's/^/    /'
[ "$FAILED" -eq 0 ]
