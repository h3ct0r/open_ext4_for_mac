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

export PATH="/opt/homebrew/opt/e2fsprogs/sbin:/opt/homebrew/opt/e2fsprogs/bin:$PATH"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DUMP="$ROOT/build/bin/ext4dump"
FIX="$ROOT/Tests/fixtures"
WORK="$ROOT/build/crash"
REPORT="$ROOT/build/crash-report.txt"
DOCKER_IMAGE="debian:stable-slim"

rm -rf "$WORK"; mkdir -p "$WORK"
: > "$REPORT"

PASS=0; FAIL=0; CUTS=0
note() { echo "$*" | tee -a "$REPORT"; }
ok()   { PASS=$((PASS+1)); }
bad()  { FAIL=$((FAIL+1)); note "  FAIL  $*"; }

[ -x "$DUMP" ] || { echo "build first: make tools"; exit 1; }
[ -f "$FIX/ext4_4k.img" ] || bash "$ROOT/Tests/make_fixtures.sh"
docker info >/dev/null 2>&1 || { echo "docker is not running; cannot replay journals"; exit 1; }

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
  cp "$FIX/ext4_4k.img" "$img"
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
    cp "$FIX/ext4_4k.img" "$dir/cut_$n.img"
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
sweep rmdir     "mkdir /d"                           rm /d
sweep rename    "create /a.txt"                      mv /a.txt /b.txt
sweep rename_x  $'mkdir /src\nmkdir /dst\ncreate /src/f' mv /src/f /dst/f
sweep symlink   ""                                   symlink /target /link
sweep hardlink  "create /orig"                       ln /orig /hard
sweep truncate  $'create /t.txt\nwrite /t.txt xxxxxxxxxxxxxxxxxxxx' truncate /t.txt 5
sweep setxattr  "create /x.txt"                      setxattr /x.txt user.k v
sweep bigwrite  "create /big.bin"                    write /big.bin "$(python3 -c "import sys; sys.stdout.write('Q'*120000)")"

note ""
note "replaying journals with the Linux kernel ($CUTS images)"

# One container for the whole batch: per-image container startup would dominate.
docker run --rm --privileged -v "$WORK:/work" "$DOCKER_IMAGE" bash -c '
  fail=0
  mkdir -p /mnt/t
  for img in $(find /work -name "cut_*.img" | sort); do
    if mount -o loop "$img" /mnt/t 2>/dev/null; then
      umount /mnt/t
    else
      echo "MOUNT-REFUSED $img"
      fail=1
    fi
  done
  exit 0
' > "$WORK/replay.log" 2>&1

refused=$(grep -c "MOUNT-REFUSED" "$WORK/replay.log" 2>/dev/null) || refused=0
refused=${refused:-0}

note ""
note "checking each recovered volume"
note ""

for dir in "$WORK"/*/; do
  label=$(basename "$dir")
  [ "$label" = "count.img" ] && continue
  local_fail=0
  for img in "$dir"cut_*.img; do
    [ -f "$img" ] || continue
    if e2fsck -fn "$img" >/dev/null 2>&1; then
      ok
    else
      local_fail=$((local_fail+1))
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

note ""
note "─────────────────────────────────"
note "cut points: $CUTS   recovered: $PASS   unrecovered: $FAIL   mounts refused: $refused"
note "report: $REPORT"

[ "$FAIL" -eq 0 ] && [ "$refused" -eq 0 ] || exit 1
