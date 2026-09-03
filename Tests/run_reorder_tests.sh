#!/usr/bin/env bash
# Does the journal survive a drive that reorders writes?
#
# Tests/run_crash_tests.sh cuts the write stream and asks whether the volume
# recovers. That is a real test and it has always passed, because the medium it
# runs on cannot fail it: an image's writes reach the host filesystem in issue
# order and stay there. A USB stick reorders freely and duly produced a damaged
# volume five times out of five where images produced none in forty-two.
#
# So the medium is modelled instead: EXT4DUMP_WRITE_CACHE makes ext4dump behave
# like a drive with a volatile cache, where only a barrier makes a write
# durable and a cut loses a reordered subset of everything issued since the
# last one. The seed is the whole reproduction recipe: a failure at seed 7 is a
# failure anybody can look at again, on any machine, in seconds.
#
# This suite is a matrix, and the geometry axis exists because of a specific
# humiliation: transaction batching corrupted volumes under reordering, and
# this suite passed it -- every cut, every seed -- because its one fixture
# carried a 16 MB journal that never wrapped during the workload. The log-wrap
# path in lwext4 was the code at fault, and a log that never wraps cannot
# exercise it. Small-journal geometries are not an extra; they are the cell
# where the last real bug lived.
#
# Journals are replayed by the real Linux kernel in a privileged container, not
# by our own recovery code, so the oracle is independent of the thing on trial.
#
#   run_reorder_tests.sh            full matrix: geometries x batch sizes
#   run_reorder_tests.sh --quick    the dev loop: small journal, batch 16
#
# Runs unattended. Writes a report to build/reorder-report.txt.
set -uo pipefail

# bash 3.2 -- the /bin/bash macOS ships -- has no associative arrays, and it
# does not fail here so much as degrade: under `set -u` without `-e` the
# failed `declare -A` leaves every lookup empty and the suite keeps walking,
# which once turned this stage into cut images that were never cut (a false
# FAIL) and a sibling suite into a 2-second false PASS. Re-exec into a real
# bash, or refuse to pretend.
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  for _b in /opt/homebrew/bin/bash /opt/local/bin/bash /usr/local/bin/bash; do
    [ -x "$_b" ] && "$_b" -c '[ "${BASH_VERSINFO[0]}" -ge 4 ]' 2>/dev/null \
      && exec "$_b" "$0" "$@"
  done
  echo "this suite needs bash >= 4 (associative arrays); brew install bash" >&2
  exit 1
fi


ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/Tests/lib.sh"

DUMP="$ROOT/build/bin/ext4dump"
FIX="$ROOT/Tests/fixtures"
WORK="$ROOT/build/reorder"
REPORT="$ROOT/build/reorder-report.txt"

QUICK=0
[ "${1:-}" = "--quick" ] && QUICK=1

CACHE_BYTES="${EXT4_REORDER_CACHE:-4194304}"
STARTED=$(date +%s)

CUTS=0
note() { echo "$*" | tee -a "$REPORT"; }
# Its own ok/bad, not lib.sh's: this sweep has hundreds of assertions, they go
# to the report as well as the terminal, and a per-cut-point line would bury
# the verdict.
ok()   { PASS=$((PASS+1)); }
  # Must not return nonzero. `cmd && bad "x" || ok "x"` otherwise runs
  # BOTH arms when cmd succeeds, because the trailing test in bad is
  # false with no detail argument -- one assertion counted as a pass
  # and a failure at once. Seen for real: "FAIL ext2 has no journal"
  # immediately followed by "ok ext2 has no journal". lib.sh has
  # returned 0 for this reason since it was written.
bad()  { FAIL=$((FAIL+1)); note "  FAIL  $*"; return 0; }

[ -x "$DUMP" ] || { echo "build first: make tools"; exit 1; }
[ -f "$FIX/ext4_4k.img" ] && [ -f "$FIX/ext4_64m.img" ] || bash "$ROOT/Tests/make_fixtures.sh"
have_linux || { echo "$(no_linux_reason); cannot replay journals"; echo "SKIPPED"; exit 77; }
oracle_needs mount umount e2fsck || { echo "SKIPPED"; exit 77; }

rm -rf "$WORK"; mkdir -p "$WORK"
: > "$REPORT"

# These are up to 256 MB each and there are hundreds. lib.sh's imgcopy is the
# cheap copy on both systems: an APFS clone here, a sparse copy on Linux.
clone() { imgcopy "$1" "$2"; }

note "########## RECOVERY ON A DRIVE THAT REORDERS ##########"
note ""
note "cache: $CACHE_BYTES bytes    mode: $([ "$QUICK" = 1 ] && echo quick || echo full)"

# -------------------------------------------------------------- geometries --
# big    256 MB, 16 MB journal, mke2fs   -- the log never wraps: the control
# small   64 MB,  4 MB journal, make_fixtures asserts it -- the log wraps
# ours   256 MB,  4 MB checksummed journal, our own mkfs -- both at once
geometry_image() {
  case "$1" in
    big)    echo "$FIX/ext4_4k.img" ;;
    small)  echo "$FIX/ext4_64m.img" ;;
    ours)   echo "$WORK/ours_base.img" ;;
    ours64) echo "$WORK/ours64_base.img" ;;
  esac
}

# build_ours <image> <size-mb>
build_ours() {
  local img="$1" mb="$2"
  rm -f "$img"
  dd if=/dev/zero of="$img" bs=1M count="$mb" 2>/dev/null
  env EXT4DUMP_JOURNAL_BLOCKS=1024 \
      EXT4DUMP_UUID=5ee0a11ab1e5000000000000000000d1 \
      "$DUMP" "$img" format 4 4096 OURS >/dev/null 2>&1
  e2fsck -fn "$img" >/dev/null 2>&1 || { note "our-format base image failed fsck"; exit 1; }
  local jb
  jb=$(dumpe2fs -h "$img" 2>/dev/null | sed -n 's/^Total journal blocks: *//p')
  [ "$jb" = "1024" ] || { note "our-format journal is $jb blocks, not 1024"; exit 1; }
}

# --------------------------------------------------------------- workloads --
# mix:   the original many-creates workload -- lots of transactions in flight.
# churn: create-then-delete cycles. Deletion is what emits revoke records, and
#        reuse of freed blocks is what makes replaying a stale log dangerous;
#        together with a 1024-block journal the cycles wrap the log more than
#        once, which is the path batching broke. No rm-open here on purpose:
#        the known open-unlink gap is covered by run_orphan_tests.sh and must
#        not be able to masquerade as a reordering failure.
WL_MIX="$WORK/workload-mix.txt"
{
  echo "mkdir /r"
  for i in $(seq 1 120); do
    echo "mkdir /r/d$i"
    echo "mkdir /r/d$i/inner"
    echo "create /r/d$i/f"
    echo "setxattr /r/d$i/f user.k v"
  done
} > "$WL_MIX"

WL_CHURN="$WORK/workload-churn.txt"
PAYLOAD=$(printf 'reorder-suite-payload-%0.s' 1 2 3 4)   # ~88 chars, one data block
{
  for c in 1 2 3; do
    echo "mkdir /c$c"
    for i in $(seq 1 100); do
      echo "create /c$c/f$i"
      echo "write /c$c/f$i $PAYLOAD"
      echo "setxattr /c$c/f$i user.k v"
    done
    for i in $(seq 1 100); do
      echo "rm /c$c/f$i"
    done
    echo "rm /c$c"
  done
} > "$WL_CHURN"

# mix300: the workload that reproduced the batching corruption -- 300
# directories of nested creates, no deletes, recovered from the transcript of
# the run that found it. On a 1024-block journal at batch=16 it wraps the log
# several times over; the failing cuts land where a wrap's tail advance was
# still volatile while the log space it freed had already been reused.
WL_MIX300="$WORK/workload-mix300.txt"
{
  echo "mkdir /r"
  for i in $(seq 1 300); do
    echo "mkdir /r/d$i"
    echo "mkdir /r/d$i/inner"
    echo "create /r/d$i/f"
    echo "setxattr /r/d$i/f user.k v"
  done
} > "$WL_MIX300"

workload_file() {
  case "$1" in
    mix)    echo "$WL_MIX" ;;
    mix300) echo "$WL_MIX300" ;;
    churn)  echo "$WL_CHURN" ;;
  esac
}

# Cut points as percentages of the run's total writes. mix spreads across the
# whole run; churn and mix300 are biased late, where the log has wrapped.
fracs_for() {
  case "$1" in
    mix)    echo "3 8 14 20 26 33 40 47 54 61 68 75 82 89 95" ;;
    mix300) echo "25 41 55 68 82 93" ;;
    churn)  echo "45 55 64 72 80 87 93 97" ;;
  esac
}

# ------------------------------------------------------- write counting --
# Counted against a clone -- running against the fixture mutates the fixture,
# and every later clone then aborts on its first mkdir while the suite reports
# that a filesystem nobody touched recovered perfectly. Counted per
# (geometry, workload, batch): batching changes how many writes a run issues.
declare -A TOTALS
total_for() {  # <geom> <workload> <batch>
  local key="$1-$2-$3"
  if [ -z "${TOTALS[$key]:-}" ]; then
    local img="$WORK/count.img"
    clone "$(geometry_image "$1")" "$img"
    TOTALS[$key]=$(env EXT4DUMP_REPORT_WRITES=1 EXT4B_TXN_BATCH="$3" \
                   "$DUMP" "$img" script "$(workload_file "$2")" 2>&1 >/dev/null \
                   | sed -n 's/^writes=//p' | tail -1)
    rm -f "$img"
    case "${TOTALS[$key]:-}" in
      ''|*[!0-9]*) note "could not count writes for $key (got '${TOTALS[$key]:-}')"; exit 1 ;;
    esac
  fi
  echo "${TOTALS[$key]}"
}

# ------------------------------------------------------------------ cells --
# name geometry workload batch seeds expect
# expect=clean:   every torn image must recover -- the actual claim
# expect=damaged: barriers are ignored, damage is mandatory -- the negative
#                 control, because a crash-consistency test that cannot be
#                 made to fail proves nothing.
CELLS=()
CELLS+=("ours64-mix300-b16|ours64|mix300|16|1 2 3 4|clean|")
CELLS+=("ours64-mix300-b1|ours64|mix300|1|1 2|clean|")
CELLS+=("small-churn-b16|small|churn|16|1 2 3 4|clean|")
CELLS+=("small-churn-b16-lies|small|churn|16|1|damaged|EXT4DUMP_IGNORE_BARRIERS=1")
if [ "$QUICK" != 1 ]; then
  CELLS+=("ours64-mix300-b64|ours64|mix300|64|1|clean|")
  CELLS+=("small-churn-b1|small|churn|1|1|clean|")
  CELLS+=("small-churn-b64|small|churn|64|1 2|clean|")
  CELLS+=("ours-churn-b16|ours|churn|16|1 2|clean|")
  CELLS+=("ours-churn-b1|ours|churn|1|1|clean|")
  CELLS+=("ours-churn-b64|ours|churn|64|1|clean|")
  CELLS+=("ours-churn-b16-lies|ours|churn|16|1|damaged|EXT4DUMP_IGNORE_BARRIERS=1")
  CELLS+=("big-mix-b1|big|mix|1|1 2|clean|")
  CELLS+=("big-mix-b16|big|mix|16|1 2|clean|")
  CELLS+=("big-mix-b64|big|mix|64|1|clean|")
  CELLS+=("big-mix-b1-lies|big|mix|1|1|damaged|EXT4DUMP_IGNORE_BARRIERS=1")
fi

for cell in "${CELLS[@]}"; do case "$cell" in *"|ours|"*)   build_ours "$WORK/ours_base.img"   256; break;; esac; done
for cell in "${CELLS[@]}"; do case "$cell" in *"|ours64|"*) build_ours "$WORK/ours64_base.img"  64; break;; esac; done

# --------------------------------------------------------------- generation --
note ""
note "generating torn images"
for cell in "${CELLS[@]}"; do
  IFS='|' read -r name geom workload batch seeds expect extra <<<"$cell"
  base="$(geometry_image "$geom")"
  total=$(total_for "$geom" "$workload" "$batch")
  dir="$WORK/$name"; mkdir -p "$dir"
  n_imgs=0
  for seed in $seeds; do
    for frac in $(fracs_for "$workload"); do
      n=$(( total * frac / 100 ))
      img="$dir/cut_${seed}_${n}.img"
      clone "$base" "$img"
      env EXT4DUMP_WRITE_CACHE="$CACHE_BYTES" \
          EXT4DUMP_REORDER_SEED="$seed" \
          EXT4DUMP_FAIL_AFTER="$n" \
          EXT4B_TXN_BATCH="$batch" \
          $extra \
          "$DUMP" "$img" script "$(workload_file "$workload")" >/dev/null 2>&1
      CUTS=$((CUTS+1)); n_imgs=$((n_imgs+1))
    done
  done
  note "  $name: $n_imgs cuts ($total writes total)"
done

# ------------------------------------------------------------------ replay --
note ""
note "replaying journals with the Linux kernel"
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

# ------------------------------------------------------------------ verdict --
# count_clean <subdir> -> "clean damaged first-error..."
count_clean() {
  local dir="$WORK/$1" clean=0 dirty=0 first="" first_img=""
  for img in "$dir"/cut_*.img; do
    [ -f "$img" ] || continue
    if e2fsck -fn "$img" >/dev/null 2>&1; then
      clean=$((clean+1)); rm -f "$img"
    else
      dirty=$((dirty+1))
      if [ -z "$first" ]; then
        first=$(e2fsck -fn "$img" 2>&1 | grep -m1 -vE '^e2fsck|^Pass|^$' | cut -c1-64)
        first_img="$img"
      fi
    fi
  done
  echo "$clean $dirty ${first_img:-none} ${first:-}"
}

note ""
DIAG_CELL=""; DIAG_IMG=""
for cell in "${CELLS[@]}"; do
  IFS='|' read -r name geom workload batch seeds expect extra <<<"$cell"
  read -r clean dirty first_img first <<<"$(count_clean "$name")"
  refused=$(grep -c "MOUNT-REFUSED /work/$name/" "$WORK/replay.log" 2>/dev/null); refused=${refused:-0}
  note "  $(printf '%-22s' "$name") clean=$(printf '%-4s' "$clean") damaged=$(printf '%-4s' "$dirty") refused=$refused"
  if [ "$expect" = clean ]; then
    if [ "$dirty" -eq 0 ] && [ "$refused" -eq 0 ]; then
      ok
    else
      bad "$name: $dirty damaged, $refused refused -- first: $first"
      if [ -z "$DIAG_CELL" ] && [ "$first_img" != "none" ]; then
        DIAG_CELL="$cell"; DIAG_IMG="$first_img"
      fi
    fi
  else
    if [ "$dirty" -gt 0 ] || [ "$refused" -gt 0 ]; then
      ok
    else
      bad "$name: ignoring barriers changed nothing -- this suite proves nothing"
    fi
  fi
done

# ---------------------------------------------------------- auto-diagnosis --
# A failing cut is regenerated with the trace on and classified, so the report
# says which write class landed out of order -- not just that something did.
if [ -n "$DIAG_CELL" ]; then
  IFS='|' read -r name geom workload batch seeds expect extra <<<"$DIAG_CELL"
  cut_id=$(basename "$DIAG_IMG" .img)      # cut_<seed>_<n>
  seed=${cut_id#cut_}; seed=${seed%%_*}
  n=${cut_id##*_}
  note ""
  note "diagnosing $name $cut_id"
  img="$WORK/diag.img"; trc="$WORK/diag.trc"
  clone "$(geometry_image "$geom")" "$img"
  env EXT4DUMP_WRITE_CACHE="$CACHE_BYTES" \
      EXT4DUMP_REORDER_SEED="$seed" \
      EXT4DUMP_FAIL_AFTER="$n" \
      EXT4B_TXN_BATCH="$batch" \
      EXT4DUMP_TRACE="$trc" \
      $extra \
      "$DUMP" "$img" script "$(workload_file "$workload")" >/dev/null 2>&1
  bash "$ROOT/Tests/classify_trace.sh" "$(geometry_image "$geom")" "$trc" \
    | sed 's/^/    /' | tee -a "$REPORT"
  rm -f "$img"
fi

ELAPSED=$(( $(date +%s) - STARTED ))
note ""
note "─────────────────────────────────"
note "cut points: $CUTS   passed: $PASS   failed: $FAIL   ${ELAPSED}s"
note "report: $REPORT"
[ "$FAIL" -eq 0 ]
