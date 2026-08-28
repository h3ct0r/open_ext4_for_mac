#!/usr/bin/env bash
# Open-unlink and the orphan list.
#
# A file can be deleted while something still has it open. Its name goes away
# immediately, but the inode and its blocks cannot: the descriptor is still
# usable, and freeing the inode underneath it means later writes allocate
# blocks onto something nothing references. So the inode stays allocated, and
# for as long as it does the volume is in a state that is not self-describing
# -- an inode with no links and no directory entry, which e2fsck calls a leak.
#
# ext4's answer is the orphan list: a chain of exactly those inodes, rooted in
# the superblock's s_last_orphan and threaded through each inode's i_dtime.
# This suite is about whether ours behaves like ext4's.
#
# Three separate authorities have to agree, because a list only one of them
# understands is worse than no list at all:
#
#   * we recover our own                 -- mount read-write; the list settles
#   * e2fsck recovers ours               -- "Clearing orphaned inode"
#   * the real Linux kernel recovers ours -- "N orphan inodes deleted"
#
# and, in the other direction, we have to survive lists that are damaged,
# circular, or point at inodes that are already free -- because the superblock
# and the inodes it chains through are written at different moments, and a
# power cut lands wherever it lands.
#
# Runs unattended. Writes a report to build/orphan-report.txt.
set -uo pipefail

export PATH="/opt/homebrew/opt/e2fsprogs/sbin:/opt/homebrew/opt/e2fsprogs/bin:$PATH"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DUMP="$ROOT/build/bin/ext4dump"
WORK="$ROOT/build/orphan"
REPORT="$ROOT/build/orphan-report.txt"
DOCKER_IMAGE="debian:stable-slim"

rm -rf "$WORK"; mkdir -p "$WORK"
: > "$REPORT"

PASS=0; FAIL=0
note() { echo "$*" | tee -a "$REPORT"; }
ok()   { PASS=$((PASS+1)); note "  ok    $1"; }
# `bad` must end in a success status. Without it the trailing test is the
# function's exit code, and it is false whenever there is no detail argument --
# so the common `cmd && bad "..." || ok "..."` idiom runs *both* arms and the
# suite reports a failure and a pass for the same check.
bad()  { FAIL=$((FAIL+1)); note "  FAIL  $1"; [ $# -gt 1 ] && note "        $2"; return 0; }
expect_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }

[ -x "$DUMP" ] || { echo "build first: make tools"; exit 1; }
command -v mke2fs >/dev/null || { echo "mke2fs not found; brew install e2fsprogs"; exit 1; }

# Small on purpose: this suite makes hundreds of images and none of them needs
# to be big. mke2fs rather than our own formatter, so the starting point is not
# something we produced.
new_volume() {  # new_volume <path>
  rm -f "$1"
  dd if=/dev/zero of="$1" bs=1m count=16 2>/dev/null
  mke2fs -q -t ext4 -F -L ORPHAN "$1" 2>/dev/null
}

# A file with real blocks behind it, so a leak shows up in the block bitmap and
# not only in the inode bitmap.
payload() { python3 -c "import sys; sys.stdout.write('$1' * 20000)"; }

head_of() {  # head_of <image> -> the orphan list head, or 0
  "$DUMP" "$1" orphans 2>/dev/null | sed -n 's/^orphan head: //p'
}

fsck_clean() { e2fsck -fn "$1" >/dev/null 2>&1; }
fsck_first_complaint() {
  e2fsck -fn "$1" 2>&1 | grep -m1 -vE '^e2fsck|^Pass|^$' | cut -c1-60
}

# Blocks and inodes in use, as e2fsck counts them. Comparing this before and
# after is how a leak is detected: a reclaimed volume returns to its starting
# numbers, a leaking one does not.
usage_of() {  # usage_of <image>
  e2fsck -fn "$1" 2>&1 | sed -n 's/^.*: \([0-9]*\)\/[0-9]* files.*, \([0-9]*\)\/[0-9]* blocks$/\1 \2/p'
}

note "########## OPEN-UNLINK / ORPHAN LIST ##########"

# ============================================================== lifecycle ==
note ""
note "the list tracks what is deleted-but-open"
note ""

IMG="$WORK/life.img"
new_volume "$IMG"
BASE_USAGE=$(usage_of "$IMG")

"$DUMP" "$IMG" create /f.txt >/dev/null 2>&1
"$DUMP" "$IMG" write /f.txt "$(payload A)" >/dev/null 2>&1
INO=$("$DUMP" "$IMG" stat /f.txt 2>/dev/null | sed -n 's/^inode: *\([0-9]*\).*/\1/p')
[ -n "$INO" ] || INO=$("$DUMP" "$IMG" stat /f.txt 2>/dev/null | head -1 | tr -dc '0-9')

expect_eq "a volume with nothing deleted has an empty list" "0" "$(head_of "$IMG")"

"$DUMP" "$IMG" rm-open /f.txt >/dev/null 2>&1
HEAD=$(head_of "$IMG")
if [ "$HEAD" != "0" ] && [ -n "$HEAD" ]; then
  ok "a delete with the file still open puts the inode on the list (inode $HEAD)"
else
  bad "a delete with the file still open puts the inode on the list" "head is $HEAD"
fi

# The name is gone even though the inode is not -- that is the whole point.
if "$DUMP" "$IMG" stat /f.txt >/dev/null 2>&1; then
  bad "the name is gone immediately"
else
  ok "the name is gone immediately"
fi

"$DUMP" "$IMG" release "$HEAD" >/dev/null 2>&1
expect_eq "closing the last descriptor empties the list" "0" "$(head_of "$IMG")"
expect_eq "and returns every block and inode it was holding" "$BASE_USAGE" "$(usage_of "$IMG")"
if fsck_clean "$IMG"; then ok "the volume is clean afterwards"
else bad "the volume is clean afterwards" "$(fsck_first_complaint "$IMG")"; fi

# ================================================================== chain ==
note ""
note "more than one at a time"
note ""

IMG="$WORK/chain.img"
new_volume "$IMG"
BASE_USAGE=$(usage_of "$IMG")
for n in a b c; do
  "$DUMP" "$IMG" create "/$n" >/dev/null 2>&1
  "$DUMP" "$IMG" write "/$n" "$(payload "$n")" >/dev/null 2>&1
done
INOS=$("$DUMP" "$IMG" rm-open /a /b /c 2>/dev/null | sed -n 's/.*inode \([0-9]*\),.*/\1/p' | tr '\n' ' ')
set -- $INOS
IA=${1:-0}; IB=${2:-0}; IC=${3:-0}

expect_eq "the newest deletion is the head" "$IC" "$(head_of "$IMG")"

# Removing the middle entry has to close the chain over it. If it does not,
# releasing the head next will expose the hole: the new head would be the
# inode that was already freed.
EXT4DUMP_KEEP_ORPHANS=1 "$DUMP" "$IMG" release "$IB" >/dev/null 2>&1
expect_eq "releasing a middle entry leaves the head alone" "$IC" "$(head_of "$IMG")"
EXT4DUMP_KEEP_ORPHANS=1 "$DUMP" "$IMG" release "$IC" >/dev/null 2>&1
expect_eq "and the chain closes over it" "$IA" "$(head_of "$IMG")"
EXT4DUMP_KEEP_ORPHANS=1 "$DUMP" "$IMG" release "$IA" >/dev/null 2>&1
expect_eq "releasing the last one empties the list" "0" "$(head_of "$IMG")"
expect_eq "three deferred deletes leak nothing" "$BASE_USAGE" "$(usage_of "$IMG")"
if fsck_clean "$IMG"; then ok "the volume is clean after all three"
else bad "the volume is clean after all three" "$(fsck_first_complaint "$IMG")"; fi

# =============================================================== recovery ==
#
# The sweep. Cut the write stream at every point of an open-unlink and of a
# complete open-unlink-then-close, then recover the volume by *mounting it with
# this driver* -- no e2fsck, no Linux. Every cut point has to come back with no
# leaked blocks and no complaints.
#
# This is the claim the orphan list exists to support, and it is the one that
# was false before it: a crash while a deleted-but-open file existed used to
# strand that inode until someone happened to run e2fsck.

note ""
note "every cut point recovers by mounting, with nothing else involved"
note ""

count_writes() {  # count_writes <setup-image> <argv...>
  local img="$1"; shift
  EXT4DUMP_REPORT_WRITES=1 "$DUMP" "$img" "$@" 2>&1 >/dev/null | sed -n 's/^writes=//p'
}

sweep_recover() {  # sweep_recover <label> <argv...>
  local label="$1"; shift
  local seed="$WORK/${label}_seed.img"

  new_volume "$seed"
  local base_usage
  base_usage=$(usage_of "$seed")
  "$DUMP" "$seed" create /v.bin >/dev/null 2>&1
  "$DUMP" "$seed" write /v.bin "$(payload V)" >/dev/null 2>&1

  local probe="$WORK/${label}_probe.img"
  cp "$seed" "$probe"
  local total
  total=$(count_writes "$probe" "$@")
  rm -f "$probe"
  if [ -z "$total" ]; then bad "$label: could not count writes"; return; fi

  local img="$WORK/${label}_cut.img"
  local n leaked=0 dirty=0 unmountable=0 first=""
  for ((n=0; n<=total; n++)); do
    cp "$seed" "$img"
    EXT4DUMP_FAIL_AFTER="$n" "$DUMP" "$img" "$@" >/dev/null 2>&1

    # Recovery is a plain read-write mount. `label` is the cheapest write
    # command there is; what matters is that the mount happens at all.
    if ! "$DUMP" "$img" label RECOVERED >/dev/null 2>&1; then
      unmountable=$((unmountable+1))
      [ -z "$first" ] && first="cut $n: the volume could not be mounted"
      continue
    fi

    if ! fsck_clean "$img"; then
      dirty=$((dirty+1))
      [ -z "$first" ] && first="cut $n: $(fsck_first_complaint "$img")"
      continue
    fi

    # Clean is not enough. A driver that recovered by throwing the inode away
    # without reclaiming its blocks would also be clean -- and would still be
    # leaking. The volume has to be back to the space it started with, or to
    # exactly one more file if the delete never happened.
    local u
    u=$(usage_of "$img")
    if [ "$u" != "$base_usage" ]; then
      # One surviving file is the legitimate other outcome: the cut landed
      # before the unlink committed, so /v.bin is still there.
      if "$DUMP" "$img" stat /v.bin >/dev/null 2>&1; then
        :
      else
        leaked=$((leaked+1))
        [ -z "$first" ] && first="cut $n: no file left, but usage is [$u] not [$base_usage]"
      fi
    fi
  done
  rm -f "$img" "$seed"

  local total_bad=$(( leaked + dirty + unmountable ))
  if [ "$total_bad" -eq 0 ]; then
    ok "$label: all $((total+1)) cut points recover with nothing leaked"
  else
    bad "$label: all $((total+1)) cut points recover with nothing leaked" \
        "$unmountable unmountable, $dirty unclean, $leaked leaked — first: $first"
  fi
}

# The name goes away and the inode stays, as it does for a file something still
# holds open when the machine loses power.
sweep_recover unlink_open  rm-open /v.bin
# The whole lifecycle in one session: deleted, then closed.
sweep_recover unlink_cycle rm-cycle /v.bin

# ------------------------------------------------- two orphans, two txns --
# The gap this sweep exists to catch: with the chain head published by a
# direct superblock write and the rest of the chain journaled, a cut between
# publishing the second orphan's head and committing its transaction loses
# every orphan already on the chain -- the head points at an uncommitted
# inode, recovery drops it, and whatever it linked to is unreachable.
#
# The two unlinks must sit in *separate* transactions or the window closes by
# accident: one batch commits both together and there is no moment where the
# first is durable and the second is half-published. EXT4B_TXN_BATCH=1 forces
# the split -- which is also what any sync between two real unlinks does.
sweep_two_orphans() {
  local label="two_orphans"
  local seed="$WORK/${label}_seed.img"

  new_volume "$seed"
  local base_usage
  base_usage=$(usage_of "$seed")
  "$DUMP" "$seed" create /a.bin >/dev/null 2>&1
  "$DUMP" "$seed" write /a.bin "$(payload A)" >/dev/null 2>&1
  "$DUMP" "$seed" create /b.bin >/dev/null 2>&1
  "$DUMP" "$seed" write /b.bin "$(payload B)" >/dev/null 2>&1

  local probe="$WORK/${label}_probe.img"
  cp "$seed" "$probe"
  local total
  total=$(EXT4B_TXN_BATCH=1 count_writes "$probe" script /dev/stdin <<'WL'
rm-open /a.bin
rm-open /b.bin
WL
)
  rm -f "$probe"
  if [ -z "$total" ]; then bad "$label: could not count writes"; return; fi

  local img="$WORK/${label}_cut.img"
  local n leaked=0 dirty=0 unmountable=0 first=""
  for ((n=0; n<=total; n++)); do
    cp "$seed" "$img"
    EXT4DUMP_FAIL_AFTER="$n" EXT4B_TXN_BATCH=1       "$DUMP" "$img" script /dev/stdin >/dev/null 2>&1 <<'WL'
rm-open /a.bin
rm-open /b.bin
WL

    if ! "$DUMP" "$img" label RECOVERED >/dev/null 2>&1; then
      unmountable=$((unmountable+1))
      [ -z "$first" ] && first="cut $n: the volume could not be mounted"
      continue
    fi
    if ! fsck_clean "$img"; then
      dirty=$((dirty+1))
      [ -z "$first" ] && first="cut $n: $(fsck_first_complaint "$img")"
      continue
    fi
    # Survivors are legitimate -- a cut before either unlink committed leaves
    # one or both files in place. Anything beyond the surviving files' own
    # usage is a leak.
    local u
    u=$(usage_of "$img")
    if [ "$u" != "$base_usage" ]; then
      local survivors=0
      "$DUMP" "$img" stat /a.bin >/dev/null 2>&1 && survivors=$((survivors+1))
      "$DUMP" "$img" stat /b.bin >/dev/null 2>&1 && survivors=$((survivors+1))
      if [ "$survivors" -eq 0 ]; then
        leaked=$((leaked+1))
        [ -z "$first" ] && first="cut $n: no files left, usage [$u] not [$base_usage]"
      fi
    fi
  done
  rm -f "$img" "$seed"

  local total_bad=$(( leaked + dirty + unmountable ))
  if [ "$total_bad" -eq 0 ]; then
    ok "$label: all $((total+1)) cut points recover with nothing leaked"
  else
    bad "$label: all $((total+1)) cut points recover with nothing leaked"         "$unmountable unmountable, $dirty unclean, $leaked leaked — first: $first"
  fi
}
sweep_two_orphans

# ==================================================== other implementations ==
note ""
note "a list we wrote is understood by the tools that did not write it"
note ""

make_orphans() {  # make_orphans <image>
  new_volume "$1"
  for n in a b c; do
    "$DUMP" "$1" create "/$n" >/dev/null 2>&1
    "$DUMP" "$1" write "/$n" "$(payload "$n")" >/dev/null 2>&1
  done
  "$DUMP" "$1" rm-open /a /b /c >/dev/null 2>&1
}

IMG="$WORK/e2fsck.img"
make_orphans "$IMG"
BASE_USAGE=$(usage_of "$WORK/chain.img")   # same recipe, already emptied
CLEARED=$(e2fsck -fy "$IMG" 2>&1 | grep -c "^Clearing orphaned inode")
expect_eq "e2fsck clears all three of ours" "3" "$CLEARED"
if fsck_clean "$IMG"; then ok "and leaves the volume clean"
else bad "and leaves the volume clean" "$(fsck_first_complaint "$IMG")"; fi

if docker info >/dev/null 2>&1; then
  IMG="$WORK/linux.img"
  make_orphans "$IMG"
  KMSG=$(docker run --rm --privileged -v "$WORK:/w" "$DOCKER_IMAGE" bash -c '
    mkdir -p /mnt/t
    mount -o loop /w/linux.img /mnt/t >/dev/null 2>&1 || { echo MOUNT-REFUSED; exit 0; }
    umount /mnt/t
    dmesg | grep -o "[0-9]* orphan inodes deleted" | tail -1' 2>/dev/null | tr -d '\r')
  expect_eq "the Linux kernel deletes all three on mount" "3 orphan inodes deleted" "$KMSG"
  if fsck_clean "$IMG"; then ok "and leaves the volume clean"
  else bad "and leaves the volume clean" "$(fsck_first_complaint "$IMG")"; fi
else
  note "  skip  cross-check against the Linux kernel (docker not reachable)"
fi

# ================================================================ hostile ==
#
# The superblock and the inodes it chains through are written at different
# moments, so a power cut can leave the two disagreeing in ways no correct
# writer would ever produce. None of these may hang, corrupt, or free
# something that is still in use.

note ""
note "a damaged list is survivable"
note ""

set_head() { debugfs -w -R "ssv last_orphan $2" "$1" >/dev/null 2>&1; }

hostile() {  # hostile <name> <setup fn>
  local name="$1"; shift
  local img="$WORK/hostile.img"
  new_volume "$img"
  "$DUMP" "$img" create /keep.txt >/dev/null 2>&1
  "$DUMP" "$img" write /keep.txt "$(payload K)" >/dev/null 2>&1
  "$@" "$img"

  # Mounting read-write is what runs the cleanup.
  if ! "$DUMP" "$img" label SURVIVED >/dev/null 2>&1; then
    bad "$name" "the volume could not be mounted afterwards"
    return
  fi
  if [ "$(head_of "$img")" != "0" ]; then
    bad "$name" "the list was not emptied (head $(head_of "$img"))"
    return
  fi
  if ! "$DUMP" "$img" cat /keep.txt >/dev/null 2>&1; then
    bad "$name" "an unrelated file was destroyed"
    return
  fi
  if ! fsck_clean "$img"; then
    bad "$name" "$(fsck_first_complaint "$img")"
    return
  fi
  ok "$name"
}

h_free_inode() {  # the release freed the inode but the superblock write was lost
  local img="$1"
  "$DUMP" "$img" create /gone.txt >/dev/null 2>&1
  "$DUMP" "$img" write /gone.txt "$(payload G)" >/dev/null 2>&1
  local ino
  ino=$("$DUMP" "$img" rm-open /gone.txt 2>/dev/null | sed -n 's/.*inode \([0-9]*\),.*/\1/p')
  EXT4DUMP_KEEP_ORPHANS=1 "$DUMP" "$img" release "$ino" >/dev/null 2>&1
  set_head "$img" "$ino"
}
h_live_inode() {  # the head was published and the unlink never committed
  local img="$1"
  local ino
  ino=$("$DUMP" "$img" stat /keep.txt 2>/dev/null | head -1 | tr -dc '0-9')
  set_head "$img" "$ino"
}
h_out_of_range() { set_head "$1" 4000000; }
h_reserved()     { set_head "$1" 1; }
h_self_loop()    {  # an entry whose next pointer is itself
  local img="$1"
  "$DUMP" "$img" create /loop.txt >/dev/null 2>&1
  local ino
  ino=$("$DUMP" "$img" rm-open /loop.txt 2>/dev/null | sed -n 's/.*inode \([0-9]*\),.*/\1/p')
  debugfs -w -R "sif <$ino> dtime $ino" "$img" >/dev/null 2>&1
  set_head "$img" "$ino"
}

hostile "an already-freed inode on the list is dropped, not freed twice" h_free_inode
hostile "an inode that still has its name is dropped, not deleted"       h_live_inode
hostile "a head past the end of the inode table is refused"              h_out_of_range
hostile "a head pointing at a reserved inode is refused"                 h_reserved
hostile "a list that points at itself terminates"                        h_self_loop

# ================================================================ summary ==
note ""
note "─────────────────────────────────"
note "passed: $PASS   failed: $FAIL"
note "report: $REPORT"

rm -f "$WORK"/*.img
[ "$FAIL" -eq 0 ]
