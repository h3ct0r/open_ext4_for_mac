#!/usr/bin/env bash
# Is the campaign reaching the code it was aimed at?
#
# A fuzzer that is running is not the same as a fuzzer that is finding. A
# corpus can lose its way quietly -- a seed regenerated slightly differently,
# a refusal that starts firing earlier, a mutator strategy that stops
# resolving -- and the result is a campaign that burns hours in ext4b_probe
# and reports nothing, which is indistinguishable from a driver with no bugs
# left.
#
# So: name the functions that MUST be covered, per mode, and fail when they
# are not. This is the gate that caught the corpus building linear
# directories instead of indexed ones -- 300 names through debugfs never set
# the INDEX flag, so ext4_dir_find_entry took the linear path and not one
# function in ext4_dir_idx.c was reached, on a corpus whose stated purpose
# was the htree.
#
#   bash scripts/fuzz_coverage.sh              seeds + corpus, both modes
#   bash scripts/fuzz_coverage.sh --mode ro    one mode
#
# Exit 0 when every expectation for the modes that ran is met, 1 when not,
# 77 when the harness is not built (no libFuzzer runtime on this machine).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BIN="$ROOT/build/bin/ext4_fuzz"
OUT="$ROOT/.fuzz/cov"
# Overridable so the gate can be shown to fail: point it at a directory of
# images this driver refuses, or at one seed that has no htree in it, and the
# expectations below must go red. A gate nobody has seen fail is a gate
# nobody has tested.
SEEDS="${EXT4_FUZZ_SEEDS:-$ROOT/.fuzz/seeds}"
# The grown corpus is included by default -- it is most of what a campaign
# has actually explored -- but it has to be suppressible, or a red-first
# demonstration on a chosen seed set silently measures the corpus as well.
# The first attempt at one did exactly that and reported a pass.
# ${VAR-default}, not ${VAR:-default}: with the colon an explicitly empty
# EXT4_FUZZ_CORPUS= falls back to the default, so the red-first run that set
# it empty measured the grown corpus anyway and reported 118 mounts from a
# directory of three refused images.
CORPUS="${EXT4_FUZZ_CORPUS-$ROOT/.fuzz/corpus}"
MODES="ro rw"

while [ $# -gt 0 ]; do
  case "$1" in
    --mode) MODES="$2"; shift 2 ;;
    *) echo "usage: fuzz_coverage.sh [--mode ro|rw]"; exit 2 ;;
  esac
done

if [ ! -x "$BIN" ]; then
  echo "coverage: $BIN is not built."
  echo "          bash scripts/fuzz_build.sh   (needs Homebrew LLVM)"
  exit 77
fi
if [ ! -d "$SEEDS" ] || [ -z "$(ls -A "$SEEDS" 2>/dev/null)" ]; then
  echo "coverage: no seed corpus; bash Tests/fuzz/make_seeds.sh"
  exit 77
fi

mkdir -p "$OUT"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok    $*"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $*"; }

# The expectations, per mode. Each line is a function name that libFuzzer's
# -print_coverage must report as COVERED. Names taken from the source, and
# checked against a real run rather than guessed -- a gate listing a function
# that does not exist passes forever.
#
# ro: the read paths a mounted volume exercises on an `ls`.
RO_EXPECT="
ext4_dir_iterator_next
ext4_dir_find_entry
ext4_dir_find_in_block
ext4_dir_dx_find_entry
ext4_dir_dx_get_leaf
ext4_dir_dx_next_block
ext4_dir_dx_csum_verify
ext4_xattr_list
ext4_xattr_is_ibody_valid
ext4_xattr_is_block_valid
ext4_xattr_find_entry
ext4_extent_get_blocks
ext4_find_extent
ext4_fs_get_inode_dblk_idx_internal
ext4_inode_get_indirect_block
ext4b_orphan_head
ext4b_map_extents
ext4b_listxattr
"

# rw: everything above plus the paths only a writable mount reaches. The
# journal is the one that matters most -- recovery is the code that exists
# specifically to protect data, and it runs on exactly one kind of input.
RW_EXPECT="
jbd_recover
jbd_journal_start
jbd_journal_stop
jbd_journal_commit_trans
ext4_dir_dx_init
ext4_dir_dx_add_entry
ext4_dir_dx_split_index
ext4_xattr_set
ext4_xattr_block_set
ext4_extent_get_blocks
ext4_ext_insert_extent
ext4_extent_remove_space
ext4b_orphan_cleanup
"

# And the negative controls: things that must NOT be covered in ro mode. A
# gate with no negative control cannot tell "we cover everything" from "the
# measurement is broken and reports everything as covered".
RO_MUST_NOT="
jbd_recover
ext4_dir_dx_add_entry
ext4b_orphan_cleanup
"

# -max_len matters: without it libFuzzer truncates every corpus file to 4096
# bytes, and four kilobytes of a filesystem is not a filesystem. The first
# version of this measurement reported jbd_recover uncovered in both modes
# for exactly that reason, and it looked like a finding.
run_coverage() {  # run_coverage <mode> <logfile>
  local mode="$1" log="$2"
  local inputs=("$SEEDS")
  [ -n "$CORPUS" ] && [ -d "$CORPUS/$mode" ] && inputs+=("$CORPUS/$mode")
  EXT4_FUZZ_MODE="$mode" EXT4_FUZZ_NO_SELFTEST=1 \
    "$BIN" -runs=0 -max_len=8388608 -rss_limit_mb=4096 \
           -print_coverage=1 -detect_leaks=0 "${inputs[@]}" > "$log" 2>&1
  return 0
}

covered() {  # covered <log> <function>
  # Anchored on COVERED_FUNC at the start of the line. UNCOVERED_FUNC
  # contains COVERED_FUNC as a substring, so an unanchored grep reports every
  # uncovered function as covered -- which it did, on the first attempt.
  grep -qE "^COVERED_FUNC: .* $2 " "$1"
}

echo "fuzz coverage gate"
echo ""

for mode in $MODES; do
  log="$OUT/print-$mode.txt"
  echo "mode $mode"
  run_coverage "$mode" "$log"

  ran=$(grep -oE '^ext4_fuzz: inputs=[0-9]+ probed-ext=[0-9]+ mounted=[0-9]+' "$log" | tail -1)
  total=$(grep -c '^COVERED_FUNC' "$log")
  echo "  ${ran:-(no stats line)}, $total function(s) covered"
  # A symbolizer that cannot read the binary reports nothing covered, and the
  # gate then lists every function as missing -- eighteen FAILs about coverage
  # that are one fact about tooling. The first CI run did exactly this: atos
  # could not symbolize a Homebrew-clang binary. Say what is actually wrong.
  if [ "$total" -eq 0 ] && grep -q "failed to symbolize\|Can't read from symbolizer" "$log"; then
    bad "$mode: the symbolizer works" \
        "$(grep -m1 'failed to symbolize\|symbolizer' "$log") -- coverage cannot be measured on this toolchain"
    return 0
  fi

  # A run that mounted nothing measures nothing, and every expectation below
  # would fail for one reason rather than for its own.
  mounted=$(sed -nE 's/.*mounted=([0-9]+).*/\1/p' <<<"$ran" | head -1)
  if [ "${mounted:-0}" -eq 0 ]; then
    bad "mode $mode mounted nothing; the coverage below means nothing"
    continue
  fi

  case "$mode" in
    ro) expect="$RO_EXPECT" ;;
    rw) expect="$RW_EXPECT" ;;
    *)  expect="" ;;
  esac

  for fn in $expect; do
    if covered "$log" "$fn"; then ok "$mode covers $fn"
    else bad "$mode does not cover $fn"; fi
  done

  if [ "$mode" = "ro" ]; then
    for fn in $RO_MUST_NOT; do
      if covered "$log" "$fn"; then
        bad "ro covers $fn, which only a writable mount should reach"
      else
        ok "ro does not cover $fn (negative control)"
      fi
    done
  fi
  echo ""
done

echo "─────────────────────────────────"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
echo "reports: $OUT"
[ "$FAIL" -eq 0 ]
