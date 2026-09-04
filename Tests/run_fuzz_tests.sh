#!/usr/bin/env bash
# Mutation campaign against the offline driver, with no special toolchain.
#
# This is the fuzzing that runs in `make validate`. The in-process libFuzzer
# harness is deeper and faster, and it needs Homebrew LLVM; validation must
# work on whatever compiler the machine has, so this drives the ordinary
# release ext4dump over mutated image files instead. Same mutation strategies,
# same weights file, same checksum stamper -- written twice, in C and in
# Python, because two instruments need them and a shared bug would hide in
# both.
#
#   FUZZ_COUNT=300   mutants per round (spread across the seed images)
#   FUZZ_SEED=1      the RNG seed; the soak passes its round number, so a
#                    long soak is a long campaign rather than the same
#                    hundred mutants over and over
#
# Every mutant is classified by what the tool did, not by what it printed:
#
#   rc 0 or 1        clean -- worked, or refused. Both are correct answers.
#   rc 2             a bug in this suite (usage error), not in the driver
#   rc 134           CRASH (abort, which is what a failed lwext4 assert does)
#   rc 137           HANG (the deadline killed it)
#   rc >= 128        CRASH
#   sanitizer line   SAN
#   md5 changed      WROTE -- a read-only verb touched the medium
#
# A finding copies the mutant and its JSON recipe into .fuzz/findings/ and
# prints the exact line that reproduces it. .fuzz/ and not build/, because a
# validation round begins with `make clean`.
#
# Exit 77 (SKIP) without e2fsprogs or python3.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/Tests/lib.sh"

DUMP="$ROOT/build/bin/ext4dump"
STAMPCHECK="$ROOT/build/bin/ext4_stampcheck"
SEEDS="$ROOT/.fuzz/seeds"
FINDINGS="$ROOT/.fuzz/findings/$(date +%Y%m%d-%H%M%S)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ext4-fuzz.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
printf 'mkdir /fz\ncreate /fz/a\nwrite /fz/a hello-from-the-campaign\nrm /fz/a\n' > "$WORK/rw-script.txt"

FUZZ_COUNT="${FUZZ_COUNT:-300}"
FUZZ_SEED="${FUZZ_SEED:-1}"
# Strategies applied per mutant. One is the realistic case -- a single
# corrupted field -- and more is the way to reach combinations a single edit
# cannot, at the cost of mutants that are less like anything a real medium
# produces.
FUZZ_EDITS="${FUZZ_EDITS:-1}"
# Force one strategy. The weighted campaign spreads 300 mutants across eleven
# strategies and five seeds, so any single field gets a handful of attempts --
# broad, which is what validation wants, and thin, which is why the in-process
# fuzzer exists. FUZZ_TARGET=superblock aims the whole budget at one place,
# which is how a known bug is used to prove the classifier fires on something
# real and not only on a plant.
FUZZ_TARGET="${FUZZ_TARGET:-}"

# The campaign guards its own elapsed time. run_full_validation.sh kills a
# stage at 900 s with no idea which part was slow; a suite that notices at 600
# s can say "the campaign got slower" -- which is a finding about the driver,
# not about the harness. A mutant that takes ten times as long as its
# neighbours is exactly the shape of a pathological input.
BUDGET="${FUZZ_BUDGET:-600}"
START=$SECONDS

command -v python3 >/dev/null 2>&1 || { echo "  python3 not found"; exit 77; }
command -v mke2fs  >/dev/null 2>&1 || { echo "  mke2fs not found; brew install e2fsprogs"; exit 77; }
[ -x "$DUMP" ] || { echo "  build first: make tools"; exit 77; }

# The suite's own deadline, copied from the bounds suite rather than shared:
# macOS has no timeout(1), and a driver that stops answering is the failure
# being guarded against. rc 137 means killed.
# run_deadline comes from Tests/lib.sh.

md5of() { md5 -q "$1" 2>/dev/null || md5sum "$1" | cut -d' ' -f1; }

# Which build is being judged, and what that build can see.
#
# This matters more than it looks. Against the release tool, the campaign
# detects crashes, hangs and writes -- real classes, all of them, and all
# invisible to a suite that only checks output. It cannot see memory
# unsafety: a heap-buffer-overflow that reads garbage returns 0 and prints a
# wrong answer, and the campaign calls it clean. Under `make test-asan` the
# same mutants become a memory-safety sweep.
#
# Measured, not assumed: 200 superblock-targeted mutants of s01 produce zero
# findings against the release build and five heap-buffer-overflows against
# the sanitizer build -- the same five mutants, the same s_inode_size field.
# So a green campaign in `make validate` is a narrower claim than a green one
# in `make test-asan`, and it says so out loud rather than letting the reader
# assume the wider one.
# Capture first, then match. `nm ... | grep -q` under `set -o pipefail` is a
# trap this project has already been bitten by once (see
# scripts/check_ship_surface.sh): grep -q exits at the first hit, nm gets
# SIGPIPE, and pipefail makes the whole pipeline non-zero -- so a present
# symbol reads as absent, sometimes, depending on how much nm had left to
# write. This reported "release build" against an ASan binary carrying 1276
# __asan symbols.
SANITIZED=no
DUMP_SYMS="$(nm "$DUMP" 2>/dev/null)"
case "$DUMP_SYMS" in *__asan*) SANITIZED=yes ;; esac

echo "mutation campaign"
if [ "$SANITIZED" = "yes" ]; then
  echo "  against a sanitizer build: crashes, hangs, writes AND memory unsafety"
else
  echo "  against a release build: crashes, hangs and writes only."
  echo "  Memory unsafety is out of reach here; run 'make test-asan' for that."
fi
echo ""

# ------------------------------------------------------- 1. the seed corpus --
echo "seed corpus"
if ! bash "$ROOT/Tests/fuzz/make_seeds.sh" > "$WORK/seeds.log" 2>&1; then
  rc=$?
  if [ "$rc" -eq 77 ]; then
    sed 's/^/  /' "$WORK/seeds.log"
    exit 77
  fi
  bad "the seed corpus builds" "$(tail -3 "$WORK/seeds.log" | tr '\n' ' ')"
  finish; exit 1
fi
seed_n=$(ls -1 "$SEEDS"/*.img 2>/dev/null | wc -l | tr -d ' ')
if [ "${seed_n:-0}" -lt 5 ]; then
  bad "the seed corpus has images to mutate" "found $seed_n"
else
  ok "the seed corpus builds ($seed_n images)"
fi

# --------------------------------------------------- 2. the stamper's oracle --
# If the stamper is wrong, every mutant is refused at the checksum gate, the
# campaign covers nothing past the superblock, and it looks exactly like a
# driver with very good validation. That failure is silent, so it is checked
# before anything else -- both ways round.
echo ""
echo "the checksum stamper"

if python3 "$ROOT/Tests/fuzz/ext4_csum.py" --verify "$SEEDS"/s01.img "$SEEDS"/s03.img \
     > "$WORK/verify.log" 2>&1; then
  ok "python stamper agrees with mke2fs ($(grep -o '[0-9]* checked' "$WORK/verify.log" | head -1))"
else
  bad "python stamper agrees with mke2fs" "$(grep -m1 'BAD' "$WORK/verify.log")"
fi

if python3 "$ROOT/Tests/fuzz/ext4_csum.py" --verify --poly 0x82F63B79 \
     "$SEEDS"/s01.img > "$WORK/verify-bad.log" 2>&1; then
  bad "a wrong polynomial disagrees with mke2fs" \
      "the checker passed with the wrong polynomial, so it checks nothing"
else
  n=$(grep -c 'BAD ' "$WORK/verify-bad.log")
  ok "a wrong polynomial disagrees with mke2fs (reported mismatches)"
fi

if [ -x "$STAMPCHECK" ]; then
  if "$STAMPCHECK" "$SEEDS"/s01.img > "$WORK/cstamp.log" 2>&1; then
    ok "C stamper agrees with mke2fs (the twin)"
  else
    bad "C stamper agrees with mke2fs" "$(grep -m1 'BAD' "$WORK/cstamp.log")"
  fi
  # And with each other. Two implementations that agree with mke2fs
  # separately could still disagree about a structure mke2fs never writes.
  pyn=$(sed -nE 's/.*  ([0-9]+) checked.*/\1/p' "$WORK/verify.log" | head -1)
  cn=$(sed -nE 's/.*  ([0-9]+) checked.*/\1/p' "$WORK/cstamp.log" | head -1)
  if [ -n "$pyn" ] && [ "$pyn" = "$cn" ]; then
    ok "the two stampers check the same $pyn structures"
  else
    bad "the two stampers check the same structures" "python $pyn, C $cn"
  fi
fi

# ------------------------------------------------- 3. the classifier itself --
# A classifier that has never been shown to fire is a classifier nobody has
# tested: the campaign below would report "300 mutants, all clean" just as
# cheerfully if it were broken. EXT4DUMP_PLANT is read in the tool, so the
# shipping core is unaffected.
echo ""
echo "the classifier fires"

PLANT_IMG="$WORK/plant.img"
cp "$SEEDS/s01.img" "$PLANT_IMG"

run_deadline 20 env EXT4DUMP_PLANT=abort "$DUMP" "$PLANT_IMG" ls / >/dev/null 2>&1
prc=$?
[ "$prc" -eq 134 ] && ok "a planted abort classifies as CRASH (rc=134)" \
                   || bad "a planted abort classifies as CRASH" "rc=$prc, expected 134"

run_deadline 5 env EXT4DUMP_PLANT=spin "$DUMP" "$PLANT_IMG" ls / >/dev/null 2>&1
prc=$?
[ "$prc" -eq 137 ] && ok "a planted spin classifies as HANG (rc=137)" \
                   || bad "a planted spin classifies as HANG" "rc=$prc, expected 137"

before=$(md5of "$PLANT_IMG")
run_deadline 20 env EXT4DUMP_PLANT=write "$DUMP" "$PLANT_IMG" ls / >/dev/null 2>&1
after=$(md5of "$PLANT_IMG")
[ "$before" != "$after" ] && ok "a planted write classifies as WROTE (md5 changed)" \
                          || bad "a planted write classifies as WROTE" "md5 unchanged"

cp "$SEEDS/s01.img" "$PLANT_IMG"
before=$(md5of "$PLANT_IMG")
run_deadline 20 "$DUMP" "$PLANT_IMG" ls / >/dev/null 2>&1
prc=$?
after=$(md5of "$PLANT_IMG")
if [ "$prc" -lt 128 ] && [ "$before" = "$after" ]; then
  ok "and an unplanted run classifies as clean (rc=$prc, md5 unchanged)"
else
  bad "an unplanted run classifies as clean" "rc=$prc, md5 changed=$([ "$before" = "$after" ] && echo no || echo yes)"
fi

# ---------------------------------------------------------- 4. the campaign --
echo ""
echo "campaign: $FUZZ_COUNT mutants, seed $FUZZ_SEED${FUZZ_TARGET:+, strategy $FUZZ_TARGET}"

READ_VERBS=(probe "ls /" "stat /docs/small.txt" "cat /docs/small.txt"
            "extents /docs/mid.bin" "xattr /docs/mid.bin" check df groups orphans)

# Which seeds the campaign mutates. Overridable so a finding can be chased
# down to one image and one strategy without re-running the whole spread --
# 300 mutants over five seeds, two modes and eleven strategies is a handful
# of attempts per field, which is the right shape for validation and the
# wrong shape for reproducing something specific.
read -r -a CAMPAIGN_SEEDS <<<"${FUZZ_IMAGES:-s01 s02 s04 s05 s06}"
present=()
for s in "${CAMPAIGN_SEEDS[@]}"; do
  [ -f "$SEEDS/$s.img" ] && present+=("$s")
done
if [ ${#present[@]} -eq 0 ]; then
  bad "the campaign has seeds to work from" "none of ${CAMPAIGN_SEEDS[*]} exist"
  finish; exit 1
fi

per_seed=$(( FUZZ_COUNT / ${#present[@]} ))
[ "$per_seed" -lt 1 ] && per_seed=1

mutants=0; clean=0; crash=0; hang=0; san=0; wrote=0; suitebug=0
budget_hit=0

record() {  # record <img> <json> <what> <reproduce-line>
  mkdir -p "$FINDINGS"
  local base; base="$(basename "$1" .img)-$(date +%s)"
  cp "$1" "$FINDINGS/$base.img" 2>/dev/null
  [ -f "$2" ] && cp "$2" "$FINDINGS/$base.json" 2>/dev/null
  bad "$3" "reproduce: $4"
  echo "        kept: $FINDINGS/$base.img (+ .json recipe)"
}

for s in "${present[@]}"; do
  [ "$budget_hit" -eq 1 ] && break
  for mode in restamp raw; do
    [ "$budget_hit" -eq 1 ] && break
    half=$(( per_seed / 2 )); [ "$half" -lt 1 ] && half=1
    out="$WORK/m-$s-$mode"
    if ! python3 "$ROOT/Tests/fuzz/mutate_image.py" --seed "$FUZZ_SEED" \
           --count "$half" --edits "$FUZZ_EDITS" --out "$out" \
           --mode "$mode" ${FUZZ_TARGET:+--target "$FUZZ_TARGET"} \
           "$SEEDS/$s.img" \
           > "$WORK/mut-$s-$mode.log" 2>&1; then
      bad "mutating $s ($mode) succeeds" "$(tail -2 "$WORK/mut-$s-$mode.log" | tr '\n' ' ')"
      continue
    fi

    for img in "$out"/*.img; do
      [ -f "$img" ] || continue
      if [ $(( SECONDS - START )) -gt "$BUDGET" ]; then
        # A campaign that has outgrown its budget is itself the finding: the
        # 900 s stage timeout would kill it with no idea which part was slow.
        bad "the campaign fits in ${BUDGET}s" \
            "stopped after $mutants mutants at $(( SECONDS - START ))s -- the driver got slower, or a mutant is pathological"
        budget_hit=1
        break
      fi
      json="${img%.img}.json"
      mutants=$(( mutants + 1 ))
      before=$(md5of "$img")
      verdict=""

      for verb in "${READ_VERBS[@]}"; do
        # shellcheck disable=SC2086
        out_txt=$(run_deadline 20 "$DUMP" "$img" $verb 2>&1); rc=$?
        if [ "$rc" -eq 137 ]; then
          verdict="HANG"; hang=$(( hang + 1 ))
          record "$img" "$json" "a mutant hangs ($s/$mode: $verb)" \
                 "build/bin/ext4dump <img> $verb"
          break
        elif [ "$rc" -eq 2 ]; then
          suitebug=$(( suitebug + 1 ))
          bad "the suite invokes '$verb' correctly" "rc=2 is a usage error, not a driver bug"
          break
        elif [ "$rc" -ge 128 ]; then
          verdict="CRASH"; crash=$(( crash + 1 ))
          record "$img" "$json" "a mutant crashes ($s/$mode: $verb, rc=$rc)" \
                 "build/bin/ext4dump <img> $verb"
          break
        fi
        if grep -qE 'AddressSanitizer|runtime error:|LeakSanitizer' <<<"$out_txt"; then
          verdict="SAN"; san=$(( san + 1 ))
          record "$img" "$json" "a sanitizer fired ($s/$mode: $verb)" \
                 "build/bin/ext4dump <img> $verb"
          break
        fi
      done

      if [ -z "$verdict" ] && [ "$(md5of "$img")" != "$before" ]; then
        verdict="WROTE"; wrote=$(( wrote + 1 ))
        record "$img" "$json" "a read-only verb wrote to the medium ($s/$mode)" \
               "for v in ${READ_VERBS[*]}; do build/bin/ext4dump <img> \$v; done"
      fi

      # And a write session on a copy, cut short at a random point, then a
      # structural check of what it left. This is where a mutant that reads
      # cleanly can still take the write path somewhere it should not go.
      if [ -z "$verdict" ]; then
        imgcopy "$img" "$WORK/rw.img"
        # The script is a FILE. It was a heredoc, and run_deadline backgrounds
        # the command it is given; bash hands an asynchronous command /dev/null
        # on stdin, so for its first weeks this arm ran an empty script against
        # every mutant and called every one of them clean on the write path.
        # ext4dump prints "script: N command(s) run" at the end, and the
        # hostile-regressions suite asserts on that line; this campaign cannot
        # (a mutant may legitimately refuse the mkdir) and relies on the same
        # file-not-stdin shape.
        run_deadline 40 env "EXT4DUMP_FAIL_AFTER=$(( RANDOM % 200 ))" \
            "$DUMP" "$WORK/rw.img" script "$WORK/rw-script.txt" >/dev/null 2>&1
        rc=$?
        if [ "$rc" -eq 137 ]; then
          verdict="HANG"; hang=$(( hang + 1 ))
          record "$img" "$json" "a mutant hangs on the write path ($s/$mode)" \
                 "EXT4DUMP_FAIL_AFTER=N build/bin/ext4dump <img> script -"
        elif [ "$rc" -ge 128 ]; then
          verdict="CRASH"; crash=$(( crash + 1 ))
          record "$img" "$json" "a mutant crashes on the write path ($s/$mode, rc=$rc)" \
                 "EXT4DUMP_FAIL_AFTER=N build/bin/ext4dump <img> script -"
        else
          chk=$(run_deadline 20 "$DUMP" "$WORK/rw.img" check 2>&1); rc=$?
          if [ "$rc" -ge 128 ]; then
            verdict="CRASH"; crash=$(( crash + 1 ))
            record "$img" "$json" "check crashes after a cut write ($s/$mode, rc=$rc)" \
                   "build/bin/ext4dump <img> check"
          elif grep -qE 'AddressSanitizer|runtime error:' <<<"$chk"; then
            verdict="SAN"; san=$(( san + 1 ))
            record "$img" "$json" "a sanitizer fired on check ($s/$mode)" \
                   "build/bin/ext4dump <img> check"
          fi
        fi
      fi

      [ -z "$verdict" ] && clean=$(( clean + 1 ))
    done
    rm -rf "$out"
  done
done

echo ""
echo "  mutants=$mutants clean=$clean crash=$crash hang=$hang san=$san wrote=$wrote"
echo "  elapsed=$(( SECONDS - START ))s of ${BUDGET}s budget"
[ -d "$FINDINGS" ] && echo "  findings kept in $FINDINGS"

# A campaign that mutated nothing is not a pass.
if [ "$mutants" -eq 0 ]; then
  bad "the campaign ran any mutants at all" "zero mutants is not a clean run"
elif [ "$clean" -eq 0 ]; then
  bad "the campaign produced any clean mutant" \
      "every mutant was a finding, which usually means the harness is broken"
else
  ok "the campaign ran $mutants mutants ($clean clean)"
fi

finish
