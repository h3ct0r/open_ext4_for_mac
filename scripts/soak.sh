#!/usr/bin/env bash
# Run the whole validation set over and over until something breaks.
#
# The number that matters about this driver is not 500-odd assertions passing.
# It is that four real bugs were found in a single day, every one of them in
# the mounted path and every one in a surface nothing exercised. Density like
# that is not brought down by writing more assertions in an afternoon; it is
# brought down by elapsed time. A suite that has passed once tells you it can
# pass. A suite that has passed two hundred times, on different days, with the
# machine in different states, tells you something else.
#
# So: one round is scripts/run_full_validation.sh, and the point of this
# script is only to run it repeatedly, stop dead at the first failure, and
# keep the evidence.
#
#   bash scripts/soak.sh                    until it fails, or you interrupt it
#   SOAK_ROUNDS=5 bash scripts/soak.sh
#   bash scripts/soak.sh --fuzz 10          and ten minutes of fuzzing in each
#                                           mode between rounds, stopping on
#                                           the first crash artifact
#   bash scripts/soak.sh --offline          rounds are scripts/ci_offline.sh
#                                           instead of the full chain: no
#                                           Docker, no extension, no hands --
#                                           which is what a CI runner has
#
# Stopping at the first failure is deliberate. A soak that carries on past a
# red round gives you a pass rate, and a pass rate is the wrong shape of
# answer for a filesystem: the question is whether it ever loses data, and
# "usually not" is not an answer. The round's full output stays in
# .soak/round-N.log, and the tally is printed in the form that belongs in
# docs/STATUS.md.
#
# NOT under build/. A round begins with `make clean`, which removes build/
# entirely -- so a log opened there is unlinked while it is still being
# written to, and the round after it cannot create one at all. That is how
# this script failed on its second round the first time it was run for
# longer than one. run_full_validation.sh carries the same lesson in a
# comment about its own log; reading it would have saved a round.
#
# Do not run this while your own media is mounted. Every round crash-tests
# the shared extension process, and that means yours too.
#
# Sleeping through a round is not a failure, and telling them apart matters.
# The first long soak here reported a wedge in round 8 -- concurrent readers
# still running after a 120 s deadline -- on a round that took 2293 s where
# every other took 630. The laptop had been closed and carried somewhere. A
# deadline measured in wall-clock expires the instant the machine wakes, and
# every queued reader resumes at once, which reads as a spin. So each round
# notes the kernel's last wake time either side of itself: a round that slept
# and then failed is reported as inconclusive and the soak carries on, because
# stopping dead is for real failures and this is not one.
#
# `caffeinate -i` keeps idle sleep away while a round runs. It cannot stop a
# closed lid, which is why the detection exists as well.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/.soak"
mkdir -p "$OUT"

ROUNDS="${SOAK_ROUNDS:-0}"        # 0 = keep going

# --fuzz MIN   spend MIN minutes fuzzing between rounds, in each mode
# --offline    run scripts/ci_offline.sh as the round instead of the full
#              validation chain -- for a machine with no Docker and no
#              enabled extension, which is every CI runner
FUZZ_MIN=0
OFFLINE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --fuzz)    FUZZ_MIN="${2:-10}"; shift 2 ;;
        --offline) OFFLINE=1; shift ;;
        *) echo "usage: soak.sh [--fuzz MINUTES] [--offline]"; exit 2 ;;
    esac
done

# A round that skipped half its stages is not a round.
#
# run_full_validation.sh treats a missing prerequisite as SKIP rather than
# failure, which is right for someone running it on a laptop without Docker.
# It is wrong for a soak: the whole product here is "nothing found in N runs",
# and an N built out of rounds that did not run the crash sweep, the Linux
# differential or the mounted driver is worse than no N at all -- it is a
# number that invites trust it has not earned.
#
# This has already happened once. Docker did not come back after a reboot,
# twenty rounds passed in 215 s each instead of 630, and seven stages -- every
# one that needs the Linux oracle, including both mounted stages, which are
# nested inside the Docker branch -- silently did not run.
require_prereqs() {
    local missing=""
    docker info >/dev/null 2>&1 || missing="$missing
  - Docker is not running. Stages 6, 7, 7b, 8, 8b SKIP without it, and so do
    9 and 10, which are nested inside that branch -- so the mounted driver is
    not exercised at all. Start Docker Desktop and wait for it to settle."
    bash "$ROOT/scripts/check_extension.sh" >/dev/null 2>&1 || missing="$missing
  - The FSKit extension is not enabled and answering. Stages 9 to 12 need it.
    System Settings > General > Login Items & Extensions > File System
    Extensions."
    [ -z "$missing" ] && return 0
    echo "soak: refusing to start, because the rounds would not measure much:"
    echo "$missing"
    echo ""
    echo "  (SOAK_ALLOW_SKIPS=1 overrides, if a partial soak is what you want.)"
    return 1
}
# --offline rounds are the offline set, which by definition needs none of
# the things require_prereqs insists on. Asking for Docker and an enabled
# extension before running a suite that uses neither would make the variant
# unusable exactly where it is for.
if [ "$OFFLINE" -eq 0 ] && [ "${SOAK_ALLOW_SKIPS:-0}" != "1" ]; then
    require_prereqs || exit 2
fi
started=$(date "+%Y-%m-%d %H:%M")
passed=0
slept_rounds=0
partial_rounds=0
failed_at=""
failed_kind="the validation round"

# Seconds of the kernel's last wake. Changes across a round exactly when the
# machine slept during it.
wake_stamp() {
    # Anchored: a greedy .* would match "usec = " instead, which changes on
    # every wake too but is not the field being asked for.
    sysctl -n kern.waketime 2>/dev/null | sed -nE 's/^\{ sec = ([0-9]+).*/\1/p'
}

# Interrupting a soak is the normal way to end one -- it is meant to be left
# running -- so Ctrl-C reports rather than vanishing.
report() {
    echo ""
    echo "──────────────────────────────────────────────────"
    echo "soak: $passed round(s) passed, started $started"
    if [ "$slept_rounds" -gt 0 ]; then
        echo "      $slept_rounds round(s) spanned a sleep and were not counted"
    fi
    if [ "$partial_rounds" -gt 0 ]; then
        echo "      $partial_rounds round(s) skipped stages and were not counted"
    fi
    if [ -n "$failed_at" ]; then
        echo "      round $failed_at FAILED ($failed_kind)"
        if [ "$failed_kind" = "the fuzzer" ]; then
            echo "      artifacts in .fuzz/crashes/, logs in .fuzz/logs/"
        else
            echo "      $OUT/round-$failed_at.log"
        fi
    fi
    echo ""
    echo "for docs/STATUS.md:"
    # Name the set. "N clean rounds" means something quite different for the
    # full chain and for the offline subset, and a line that does not say
    # which is a line that will be read as the stronger one.
    local what="the full set"
    [ "$OFFLINE" -eq 1 ] && what="the offline set"
    [ "$FUZZ_MIN" -gt 0 ] && what="$what with ${FUZZ_MIN}m of fuzzing between rounds"
    if [ -n "$failed_at" ]; then
        echo "  soak: $passed clean round(s) of $what, then a failure in round $failed_at ($(date +%Y-%m-%d))"
    else
        echo "  soak: $passed clean round(s) of $what as of $(date +%Y-%m-%d)"
    fi
    exit $([ -n "$failed_at" ] && echo 1 || echo 0)
}
trap report INT TERM

# Fuzzing between rounds.
#
# A validation round is the same inputs every time; the point of a soak is
# elapsed time against a fixed target. The fuzzer is the opposite -- new
# inputs, guided by what it has already reached -- and the corpus in .fuzz/
# persists across rounds, so a long soak is also a long campaign. They cost
# different things and find different things, which is why both.
#
# Returns non-zero when a new crash artifact appears, which stops the soak:
# the same reasoning as stopping at the first failing round. A pass rate is
# the wrong shape of answer, and a crash the soak ran past is a crash nobody
# will look at.
FUZZ_BIN="$ROOT/build/bin/ext4_fuzz"

fuzz_interlude() {
    [ "$FUZZ_MIN" -gt 0 ] || return 0

    if [ ! -x "$FUZZ_BIN" ]; then
        if ! bash "$ROOT/scripts/fuzz_build.sh" >/dev/null 2>&1; then
            echo "      (no libFuzzer runtime here; --fuzz has nothing to run)"
            FUZZ_MIN=0
            return 0
        fi
    fi

    mkdir -p "$ROOT/.fuzz/crashes" "$ROOT/.fuzz/logs"
    local before after new
    before=$(ls -1 "$ROOT/.fuzz/crashes" 2>/dev/null | wc -l | tr -d " ")

    local secs=$(( FUZZ_MIN * 60 ))
    local mode
    for mode in fuzz fuzz-rw; do
        printf "      %-8s %dm  " "$mode" "$FUZZ_MIN"
        local t0; t0=$(date +%s)
        caffeinate -i make -C "$ROOT" "$mode" FUZZ_TIME="$secs" \
            > "$ROOT/.fuzz/logs/round-$round-$mode.txt" 2>&1
        printf "%ds\n" "$(( $(date +%s) - t0 ))"
    done

    # Every tenth round, distil. A corpus grows monotonically and most of it
    # is redundant; without this the sweep at the start of each campaign costs
    # more than the campaign.
    if [ $(( round % 10 )) -eq 0 ]; then
        printf "      merging the corpus  "
        make -C "$ROOT" fuzz-merge > "$ROOT/.fuzz/logs/round-$round-merge.txt" 2>&1
        grep -o "merged corpus: .*" "$ROOT/.fuzz/logs/round-$round-merge.txt" \
            | tail -1 || echo ""
    fi

    after=$(ls -1 "$ROOT/.fuzz/crashes" 2>/dev/null | wc -l | tr -d " ")
    if [ "$after" -gt "$before" ]; then
        echo ""
        echo "      THE FUZZER FOUND SOMETHING in round $round:"
        ls -1t "$ROOT/.fuzz/crashes" | head -$(( after - before )) \
            | sed "s|^|        .fuzz/crashes/|"
        echo ""
        echo "      make fuzz-repro FILE=.fuzz/crashes/<name>"
        echo "      then Tests/fuzz/README.md, 'The triage loop'."
        # The round number alone, because report() builds a log path from it.
        # "round 1 (fuzzer)" produced ".soak/round-1 (fuzzer).log", which is
        # not a file anybody has.
        failed_at="$round"
        failed_kind="the fuzzer"
        return 1
    fi
    return 0
}

round=0
while :; do
    round=$((round + 1))
    [ "$ROUNDS" -gt 0 ] && [ "$round" -gt "$ROUNDS" ] && break

    log="$OUT/round-$round.log"
    mkdir -p "$OUT"
    t0=$(date +%s)
    printf "round %d  %s  " "$round" "$(date '+%H:%M:%S')"

    w0=$(wake_stamp)
    if [ "$OFFLINE" -eq 1 ]; then
        caffeinate -i env REQUIRE_ALL=1 FUZZ_SEED="$round" \
            bash "$ROOT/scripts/ci_offline.sh" > "$log" 2>&1
    else
        # FUZZ_SEED is the round number, so a long soak is a long campaign
        # rather than the same three hundred mutants over and over. Stage 2c
        # reads it.
        caffeinate -i env FUZZ_SEED="$round" \
            bash "$ROOT/scripts/run_full_validation.sh" > "$log" 2>&1
    fi
    rc=$?
    w1=$(wake_stamp)
    took=$(( $(date +%s) - t0 ))

    if [ -n "$w0" ] && [ -n "$w1" ] && [ "$w0" != "$w1" ]; then
        # Everything this round measured was measured across a sleep, so it
        # says nothing either way -- a pass could have skipped work and a
        # failure is most likely a wall-clock deadline expiring on wake.
        slept_rounds=$((slept_rounds + 1))
        printf "SLEPT (%ds, rc=%d)  -- not counted\n" "$took" "$rc"
        [ "$rc" -eq 0 ] && rm -f "$log" \
            || mv "$log" "$OUT/slept-round-$round.log"
        continue
    fi

    # Checked per round as well as up front: Docker can stop, and a soak that
    # kept counting after it did would quietly change what it was measuring
    # halfway through.
    # No `|| echo 0`: grep -c already prints 0, and exits 1 when it does, so
    # the fallback appended a second line and every comparison below became
    # "[: 0\n0: integer expected". The test then errored rather than being
    # false, so a partial round would have been counted as a pass -- the
    # check silently not working is worse than not having it.
    skipped=$(grep -cE '^[0-9]+[a-z]*\..* SKIP ' "$log" 2>/dev/null)
    skipped=${skipped:-0}
    if [ "$rc" -eq 0 ] && [ "${skipped:-0}" -gt 0 ] \
       && [ "${SOAK_ALLOW_SKIPS:-0}" != "1" ]; then
        printf "PARTIAL (%ds, %s stage(s) skipped) -- not counted\n" \
               "$took" "$skipped"
        grep -E '^[0-9]+[a-z]*\..* SKIP ' "$log" | head -8
        mv "$log" "$OUT/partial-round-$round.log"
        partial_rounds=$((partial_rounds + 1))
        continue
    fi

    if [ "$rc" -eq 0 ]; then
        passed=$((passed + 1))
        printf "PASS  (%ds)\n" "$took"
        # A passing round's log is 99% of the disk this produces and none of
        # the value; the failing one is what anybody will read.
        rm -f "$log"
        fuzz_interlude || report
    else
        printf "FAIL  (%ds)\n" "$took"
        echo ""
        # The validation driver ends with a stage table -- "9. mounted driver
        # PASS 24s" -- and everything in it that is not PASS is the answer.
        #
        # Two grep-for-the-word-FAIL attempts came before this and both
        # printed noise: "failed: 0" is what a PASSING suite prints, and
        # "PASS 15 FAIL 0" contains the word with spaces either side. The
        # second version reported a 900-second timeout as the two lines
        # "PASS 15 FAIL 0" and "FAILURES PRESENT", naming neither the stage
        # nor the cause. Match the table instead of the vocabulary.
        echo "the stages that did not pass:"
        grep -E '^[0-9]+[a-z]*\. ' "$log" | grep -vE ' PASS +[0-9]+s$' | head -10

        # And whatever the run said in prose. A stage that times out, or a
        # host that has wedged, explains itself a line or two above the
        # table, and that explanation is usually the whole diagnosis --
        # "writing into the extension container HANGS ... a reboot clears
        # it" was sitting in the log the whole time.
        echo ""
        echo "what the run said:"
        grep -nE "produced no result|HANGS|wedged|^  FAIL |SKIPPED" "$log" \
            | tail -8
        failed_at=$round
        report
    fi
done

report
