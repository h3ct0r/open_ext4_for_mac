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
started=$(date "+%Y-%m-%d %H:%M")
passed=0
slept_rounds=0
failed_at=""

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
    mkdir -p "$OUT"
    t0=$(date +%s)
    printf "round %d  %s  " "$round" "$(date '+%H:%M:%S')"

    w0=$(wake_stamp)
    caffeinate -i bash "$ROOT/scripts/run_full_validation.sh" > "$log" 2>&1
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

    if [ "$rc" -eq 0 ]; then
        passed=$((passed + 1))
        printf "PASS  (%ds)\n" "$took"
        # A passing round's log is 99% of the disk this produces and none of
        # the value; the failing one is what anybody will read.
        rm -f "$log"
    else
        printf "FAIL  (%ds)\n" "$took"
        echo ""
        echo "the failing stages:"
        grep -iE "^\s*(FAIL|✗)|FAILED" "$log" | head -20
        failed_at=$round
        report
    fi
done

report
