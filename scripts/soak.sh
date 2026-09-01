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
#   bash scripts/soak.sh              until it fails, or you interrupt it
#   SOAK_ROUNDS=5 bash scripts/soak.sh
#
# Stopping at the first failure is deliberate. A soak that carries on past a
# red round gives you a pass rate, and a pass rate is the wrong shape of
# answer for a filesystem: the question is whether it ever loses data, and
# "usually not" is not an answer. The round's full output stays in
# build/soak/round-N.log, and the tally is printed in the form that belongs
# in docs/STATUS.md.
#
# Do not run this while your own media is mounted. Every round crash-tests
# the shared extension process, and that means yours too.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/soak"
mkdir -p "$OUT"

ROUNDS="${SOAK_ROUNDS:-0}"        # 0 = keep going
started=$(date "+%Y-%m-%d %H:%M")
passed=0
failed_at=""

# Interrupting a soak is the normal way to end one -- it is meant to be left
# running -- so Ctrl-C reports rather than vanishing.
report() {
    echo ""
    echo "──────────────────────────────────────────────────"
    echo "soak: $passed round(s) passed, started $started"
    if [ -n "$failed_at" ]; then
        echo "      round $failed_at FAILED -- $OUT/round-$failed_at.log"
    fi
    echo ""
    echo "for docs/STATUS.md:"
    if [ -n "$failed_at" ]; then
        echo "  soak: $passed clean round(s) of the full set, then a failure in round $failed_at ($(date +%Y-%m-%d))"
    else
        echo "  soak: $passed clean round(s) of the full set as of $(date +%Y-%m-%d)"
    fi
    exit $([ -n "$failed_at" ] && echo 1 || echo 0)
}
trap report INT TERM

round=0
while :; do
    round=$((round + 1))
    [ "$ROUNDS" -gt 0 ] && [ "$round" -gt "$ROUNDS" ] && break

    log="$OUT/round-$round.log"
    t0=$(date +%s)
    printf "round %d  %s  " "$round" "$(date '+%H:%M:%S')"

    if bash "$ROOT/scripts/run_full_validation.sh" > "$log" 2>&1; then
        passed=$((passed + 1))
        printf "PASS  (%ds)\n" "$(( $(date +%s) - t0 ))"
        # A passing round's log is 99% of the disk this produces and none of
        # the value; the failing one is what anybody will read.
        rm -f "$log"
    else
        printf "FAIL  (%ds)\n" "$(( $(date +%s) - t0 ))"
        echo ""
        echo "the failing stages:"
        grep -iE "^\s*(FAIL|✗)|FAILED" "$log" | head -20
        failed_at=$round
        report
    fi
done

report
