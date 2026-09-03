#!/usr/bin/env bash
# Crash-consistency sweep.
#
# For each mutating operation, cut the write stream at every point and check
# that the volume comes back. "Cut" means later writes are silently discarded
# while still reporting success -- a real power failure does not hand the
# filesystem an errno it can react to, it just stops persisting.
#
# The journal is replayed by the real Linux kernel (mount + umount in a
# privileged container), not by e2fsck, so recovery is exercised the same way it
# would be on the machine the disk came from. The volume must then be clean
# according to `e2fsck -fn`, with no repairs.
#
# Runs unattended. Writes a report to build/crash-report.txt.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/Tests/lib.sh"

DUMP="$ROOT/build/bin/ext4dump"
FIX="$ROOT/Tests/fixtures"
WORK="$ROOT/build/crash"
REPORT="$ROOT/build/crash-report.txt"

rm -rf "$WORK"; mkdir -p "$WORK"
: > "$REPORT"

CUTS=0
note() { echo "$*" | tee -a "$REPORT"; }
# lib.sh's ok/bad print a line each and tee nothing. Both are wrong here: there
# are two hundred assertions and they belong in the report, so this suite keeps
# its own pair. A silent ok is the point -- one line per cut point would bury
# the four lines that matter.
ok()   { PASS=$((PASS+1)); }
  # Must not return nonzero. `cmd && bad "x" || ok "x"` otherwise runs
  # BOTH arms when cmd succeeds, because the trailing test in bad is
  # false with no detail argument -- one assertion counted as a pass
  # and a failure at once. Seen for real: "FAIL ext2 has no journal"
  # immediately followed by "ok ext2 has no journal". lib.sh has
  # returned 0 for this reason since it was written.
bad()  { FAIL=$((FAIL+1)); note "  FAIL  $*"; return 0; }

[ -x "$DUMP" ] || { echo "build first: make tools"; exit 1; }
[ -f "$FIX/ext4_4k.img" ] || bash "$ROOT/Tests/make_fixtures.sh"
have_linux || { echo "$(no_linux_reason); cannot replay journals"; exit 1; }
oracle_needs mount umount e2fsck || exit 1

# An operation is a name plus the ext4dump argv that performs it. Some need the
# volume prepared first; `setup` runs before the measured operation and is never
# cut.
run_setup() {  # run_setup <image> <setup-spec>
  local img="$1" spec="$2"
  [ -z "$spec" ] && return 0
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    # shellcheck disable=SC2086
    "$DUMP" "$img" $line >/dev/null 2>&1
  done <<< "$spec"
}

# Count how many writes an operation performs, so the sweep knows its range.
count_writes() {  # count_writes <setup> <argv...>
  local setup="$1"; shift
  local img="$WORK/count.img"
  imgcopy "$FIX/ext4_4k.img" "$img"
  run_setup "$img" "$setup"
  EXT4DUMP_REPORT_WRITES=1 "$DUMP" "$img" "$@" 2>&1 >/dev/null | sed -n 's/^writes=//p'
}

sweep() {  # sweep <label> <setup> <argv...>
  local label="$1" setup="$2"; shift 2
  local total
  total=$(count_writes "$setup" "$@")
  [ -z "$total" ] && { bad "$label: could not count writes"; return; }

  # Cut at every write for short operations; sample evenly for long ones so the
  # suite stays inside a sensible runtime.
  local points=()
  if [ "$total" -le 40 ]; then
    for ((n=0; n<=total; n++)); do points+=("$n"); done
  else
    local step=$(( total / 40 ))
    [ "$step" -lt 1 ] && step=1
    for ((n=0; n<=total; n+=step)); do points+=("$n"); done
  fi

  note "  $label: $total writes, ${#points[@]} cut points"

  local dir="$WORK/$label"
  mkdir -p "$dir"
  for n in "${points[@]}"; do
    imgcopy "$FIX/ext4_4k.img" "$dir/cut_$n.img"
    run_setup "$dir/cut_$n.img" "$setup"
    EXT4DUMP_FAIL_AFTER="$n" "$DUMP" "$dir/cut_$n.img" "$@" >/dev/null 2>&1
    CUTS=$((CUTS+1))
  done
}

# ------------------------------------------------------------------ sweeps --
note "generating torn images"
note ""

sweep mkdir     ""                                   mkdir /a
sweep create    ""                                   create /f.txt
sweep write     "create /f.txt"                      write /f.txt "some file content here"
sweep unlink    "create /f.txt"                      rm /f.txt
# Deleting a file that something still has open. The name goes, the inode does
# not, and the volume carries an orphan-list entry until the descriptor closes
# -- so a cut anywhere in here has to leave either a file or a reclaimable
# orphan, never an inode that nothing points at.
sweep unlink_open  $'create /o.txt\nwrite /o.txt xxxxxxxxxxxxxxxxxxxx' rm-open /o.txt
sweep unlink_cycle $'create /c.txt\nwrite /c.txt xxxxxxxxxxxxxxxxxxxx' rm-cycle /c.txt
sweep rmdir     "mkdir /d"                           rm /d
sweep rename    "create /a.txt"                      mv /a.txt /b.txt
sweep rename_x  $'mkdir /src\nmkdir /dst\ncreate /src/f' mv /src/f /dst/f
sweep symlink   ""                                   symlink /target /link
sweep hardlink  "create /orig"                       ln /orig /hard
sweep truncate  $'create /t.txt\nwrite /t.txt xxxxxxxxxxxxxxxxxxxx' truncate /t.txt 5
sweep setxattr  "create /x.txt"                      setxattr /x.txt user.k v
sweep bigwrite  "create /big.bin"                    write /big.bin "$(python3 -c "import sys; sys.stdout.write('Q'*120000)")"

# Red-first control, and the only reason it lives in the suite rather than in a
# throwaway edit: what this suite claims is "every one of 203 cut points came
# back", and a suite that could not tell a damaged volume from a whole one
# would make that claim just as loudly and just as green. EXT4_CRASH_PLANT
# truncates one generated image to a megabyte before the replay -- the
# superblock survives, the volume it describes does not -- and the run must go
# red naming that image and no other.
#
#     EXT4_CRASH_PLANT=write:3 bash Tests/run_crash_tests.sh   # must fail
#
# Read here and nowhere near the shim: scripts/check_ship_surface.sh exists to
# keep it that way.
if [ -n "${EXT4_CRASH_PLANT:-}" ]; then
  plant_img="$WORK/${EXT4_CRASH_PLANT%%:*}/cut_${EXT4_CRASH_PLANT##*:}.img"
  if [ -f "$plant_img" ]; then
    # No truncate(1) on macOS. perl is on both.
    perl -e 'truncate($ARGV[0], 1048576) or die "truncate: $!"' "$plant_img"
    note ""
    note "  PLANTED: $plant_img truncated to 1 MiB"
  else
    note ""
    note "  PLANT REQUESTED but no such image: $plant_img"
    exit 2
  fi
fi

note ""
note "replaying journals with the Linux kernel ($CUTS images)"

# One trip into Linux for the whole batch: per-image container startup would
# dominate, and on a Linux runner there is no trip at all.
in_linux "$WORK" '
  m=$(mktemp -d)
  trap '"'"'umount "$m" 2>/dev/null; rmdir "$m" 2>/dev/null'"'"' EXIT
  for img in $(find . -name "cut_*.img" | sort); do
    if mount -o loop "$img" "$m" 2>/dev/null; then
      umount "$m"
    else
      echo "MOUNT-REFUSED $img"
    fi
  done
  exit 0
' > "$WORK/replay.log" 2>&1

refused=$(grep -c "MOUNT-REFUSED" "$WORK/replay.log" 2>/dev/null) || refused=0
refused=${refused:-0}

note ""
note "checking each recovered volume"
note ""

# Each image is a full copy of a 256 MB fixture, so 256 cut points is 64 GB.
# Delete the ones that passed as they are checked -- an image that recovered
# has nothing left to tell us, and leaving them behind fills the disk.
KEPT=0
for dir in "$WORK"/*/; do
  label=$(basename "$dir")
  [ "$label" = "count.img" ] && continue
  local_fail=0
  for img in "$dir"cut_*.img; do
    [ -f "$img" ] || continue
    if e2fsck -fn "$img" >/dev/null 2>&1; then
      ok
      rm -f "$img"
    else
      local_fail=$((local_fail+1))
      KEPT=$((KEPT+1))
      if [ "$local_fail" -le 3 ]; then
        bad "$label $(basename "$img" .img): $(e2fsck -fn "$img" 2>&1 | grep -m1 -vE '^e2fsck|^Pass|^$' | cut -c1-70)"
      fi
    fi
  done
  if [ "$local_fail" -eq 0 ]; then
    note "  ok    $label — every cut point recovered"
  else
    note "  FAIL  $label — $local_fail cut point(s) did not recover"
  fi
done

rm -f "$WORK/count.img"

note ""
note "─────────────────────────────────"
note "cut points: $CUTS   recovered: $PASS   unrecovered: $FAIL   mounts refused: $refused"
if [ "$KEPT" -gt 0 ]; then
  note "kept $KEPT unrecovered image(s) under $WORK for inspection"
fi
note "report: $REPORT"

[ "$FAIL" -eq 0 ] && [ "$refused" -eq 0 ] || exit 1
