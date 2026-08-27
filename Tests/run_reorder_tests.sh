#!/usr/bin/env bash
# Does the journal survive a drive that reorders writes?
#
# Tests/run_crash_tests.sh cuts the write stream and asks whether the volume
# recovers. That is a real test and it has always passed, because the medium it
# runs on cannot fail it: an image's writes reach the host filesystem in issue
# order and stay there. A USB stick reorders freely and duly produced a damaged
# volume five times out of five where images produced none in forty-two.
#
# Chasing that with real hardware cost a day. Device names change between
# replugs, the target degrades as it is abused, each run takes minutes and
# destroys its own evidence, and three consecutive five-round runs measured
# nothing at all while reporting results. So the medium is modelled instead:
# EXT4DUMP_WRITE_CACHE makes ext4dump behave like a drive with a volatile
# cache, where only a barrier makes a write durable and a cut loses a reordered
# subset of everything issued since the last one.
#
# The seed is the whole reproduction recipe. A failure at seed 7 is a failure
# anybody can look at again, on any machine, in seconds.
#
# Journals are replayed by the real Linux kernel in a privileged container, not
# by our own recovery code, so the oracle is independent of the thing on trial.
#
# Runs unattended. Writes a report to build/reorder-report.txt.
set -uo pipefail

export PATH="/opt/homebrew/opt/e2fsprogs/sbin:/opt/homebrew/opt/e2fsprogs/bin:$PATH"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DUMP="$ROOT/build/bin/ext4dump"
FIX="$ROOT/Tests/fixtures"
WORK="$ROOT/build/reorder"
REPORT="$ROOT/build/reorder-report.txt"
DOCKER_IMAGE="debian:stable-slim"

CACHE_BYTES="${EXT4_REORDER_CACHE:-4194304}"
SEEDS="${EXT4_REORDER_SEEDS:-1 2 3 4}"

PASS=0; FAIL=0; CUTS=0
note() { echo "$*" | tee -a "$REPORT"; }
ok()   { PASS=$((PASS+1)); }
bad()  { FAIL=$((FAIL+1)); note "  FAIL  $*"; }

[ -x "$DUMP" ] || { echo "build first: make tools"; exit 1; }
[ -f "$FIX/ext4_4k.img" ] || bash "$ROOT/Tests/make_fixtures.sh"
docker info >/dev/null 2>&1 || { echo "docker is not running; cannot replay journals"; echo "SKIPPED"; exit 77; }

rm -rf "$WORK"; mkdir -p "$WORK"
: > "$REPORT"

# APFS clones a file for free; these are 256 MB each and there are hundreds.
clone() { cp -c "$1" "$2" 2>/dev/null || cp "$1" "$2"; }

note "########## RECOVERY ON A DRIVE THAT REORDERS ##########"
note ""
note "cache: $CACHE_BYTES bytes    seeds: $SEEDS"
note ""

# ------------------------------------------------------------- the workload --
#
# A script of many operations, run inside one mount. Single operations, which
# is what the crash sweep uses, only ever put one transaction in flight; the
# interesting failures need several, plus enough cache pressure to force
# eviction partway through.
WORKLOAD="$WORK/workload.txt"
{
  echo "mkdir /r"
  for i in $(seq 1 120); do
    echo "mkdir /r/d$i"
    echo "mkdir /r/d$i/inner"
    echo "create /r/d$i/f"
    echo "setxattr /r/d$i/f user.k v"
  done
} > "$WORKLOAD"

# Count against a copy. Running it against the fixture mutates the fixture --
# every later clone then starts with the workload's directories already
# present, the script aborts on its first mkdir, and the suite cheerfully
# reports that a filesystem nobody touched recovered perfectly.
clone "$FIX/ext4_4k.img" "$WORK/count.img"
TOTAL=$(EXT4DUMP_REPORT_WRITES=1 "$DUMP" "$WORK/count.img" script "$WORKLOAD" 2>&1 >/dev/null \
        | sed -n 's/^writes=//p' | tail -1)
rm -f "$WORK/count.img"
[ -n "$TOTAL" ] || { note "could not count writes"; exit 1; }
note "workload: $(wc -l < "$WORKLOAD" | tr -d ' ') operations, $TOTAL writes"

# Cut points spread across the whole run, not clustered at the start where
# only the first transaction is in flight.
POINTS=()
for frac in 5 15 30 45 60 75 90; do
  POINTS+=( $(( TOTAL * frac / 100 )) )
done

# --------------------------------------------------------------- generation --
# generate <subdir> <extra-env...>
generate() {
  local dir="$WORK/$1"; shift
  mkdir -p "$dir"
  for seed in $SEEDS; do
    for n in "${POINTS[@]}"; do
      local img="$dir/cut_${seed}_${n}.img"
      clone "$FIX/ext4_4k.img" "$img"
      env EXT4DUMP_WRITE_CACHE="$CACHE_BYTES" \
          EXT4DUMP_REORDER_SEED="$seed" \
          EXT4DUMP_FAIL_AFTER="$n" \
          "$@" "$DUMP" "$img" script "$WORKLOAD" >/dev/null 2>&1
      CUTS=$((CUTS+1))
    done
  done
}

note ""
note "generating torn images"
generate honoured
generate ignored EXT4DUMP_IGNORE_BARRIERS=1
note "  $CUTS images"

# ------------------------------------------------------------------ replay --
note ""
note "replaying journals with the Linux kernel"
docker run --rm --privileged -v "$WORK:/work" "$DOCKER_IMAGE" bash -c '
  mkdir -p /mnt/t
  for img in $(find /work -name "cut_*.img" | sort); do
    if mount -o loop "$img" /mnt/t 2>/dev/null; then
      umount /mnt/t
    else
      echo "MOUNT-REFUSED $img"
    fi
  done
  exit 0
' > "$WORK/replay.log" 2>&1

# ------------------------------------------------------------------ verdict --
# count_clean <subdir> -> "clean damaged"
count_clean() {
  local dir="$WORK/$1" clean=0 dirty=0 first=""
  for img in "$dir"/cut_*.img; do
    [ -f "$img" ] || continue
    if e2fsck -fn "$img" >/dev/null 2>&1; then
      clean=$((clean+1)); rm -f "$img"
    else
      dirty=$((dirty+1))
      [ -z "$first" ] && first=$(e2fsck -fn "$img" 2>&1 | grep -m1 -vE '^e2fsck|^Pass|^$' | cut -c1-64)
    fi
  done
  echo "$clean $dirty ${first:-}"
}

note ""
read -r H_CLEAN H_DIRTY H_FIRST <<<"$(count_clean honoured)"
read -r I_CLEAN I_DIRTY I_FIRST <<<"$(count_clean ignored)"

note "  barriers honoured   clean=$H_CLEAN  damaged=$H_DIRTY"
note "  barriers ignored    clean=$I_CLEAN  damaged=$I_DIRTY"
note ""

# Every torn image must recover. This is the actual claim.
if [ "$H_DIRTY" -eq 0 ]; then
  ok; note "  ok    every reordered cut recovered"
else
  bad "$H_DIRTY reordered cut(s) did not recover: $H_FIRST"
fi

# And the suite must be capable of saying no. A crash-consistency test that
# cannot be made to fail is not evidence of anything -- this project has
# already shipped one check that could only report success, and it reported it
# on a volume the driver had never touched.
if [ "$I_DIRTY" -gt 0 ]; then
  ok; note "  ok    ignoring barriers breaks it, so this suite can detect the bug"
else
  bad "ignoring barriers changed nothing -- this suite proves nothing"
fi

# A refusal has to be attributed before it means anything. The kernel refusing
# a volume torn with barriers disabled is the bug being demonstrated, not a
# problem with the suite; refusing one torn with barriers honoured is the
# failure this whole suite exists to catch.
# grep -c prints 0 and exits 1 when it matches nothing, so `|| echo 0` yields
# two zeroes and a shell arithmetic error. Take the output and default it.
refused_ok=$(grep -c "MOUNT-REFUSED /work/honoured/" "$WORK/replay.log" 2>/dev/null); refused_ok=${refused_ok:-0}
refused_ig=$(grep -c "MOUNT-REFUSED /work/ignored/"  "$WORK/replay.log" 2>/dev/null); refused_ig=${refused_ig:-0}

if [ "${refused_ok:-0}" -gt 0 ]; then
  bad "the kernel refused to mount $refused_ok image(s) torn with barriers honoured"
fi
[ "${refused_ig:-0}" -gt 0 ] && \
  note "  note  the kernel refused $refused_ig image(s) with barriers ignored, as expected"

note ""
note "─────────────────────────────────"
note "cut points: $CUTS   passed: $PASS   failed: $FAIL"
note "report: $REPORT"
[ "$FAIL" -eq 0 ]
