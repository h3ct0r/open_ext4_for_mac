#!/usr/bin/env bash
# Reproduce the stage-0 wedge, and catch it in the act.
#
# The mounted crash suite's stage 0 -- six readers walking the tree while a
# writer churns it -- wedged on the eighth round of a soak: still running after
# 120 s, extension at 67% CPU. The suite's job at that point is to recover the
# machine, so it kills the extension, and the evidence goes with it.
#
# This runs the same workload in a loop and does the opposite: the moment it
# hangs, it takes a `sample` of the stuck process and saves it, THEN recovers.
# A spin is identified by where it is spinning, and nothing else will say.
#
#   bash scripts/repro_wedge.sh [rounds]
#
# Writes .soak/wedge-<n>.sample and .soak/wedge-<n>.log. Do not run this with
# your own ext4 media mounted: recovery kills the shared extension process.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="/opt/homebrew/opt/e2fsprogs/sbin:/opt/homebrew/opt/e2fsprogs/bin:$PATH"

ROUNDS="${1:-20}"
WORK="$ROOT/build/wedge"
OUT="$ROOT/.soak"
MNT="$WORK/mnt"
DEV=""
EXT_PATTERN="/Ext4FS.appex/Contents/MacOS/Ext4FS"

mkdir -p "$WORK" "$MNT" "$OUT"

cleanup() {
    umount "$MNT" 2>/dev/null
    [ -n "$DEV" ] && hdiutil detach "$DEV" -force >/dev/null 2>&1
    return 0
}
trap cleanup EXIT

ext_cpu() {
    ps -Ao %cpu,command | grep "$EXT_PATTERN" | grep -v grep \
        | awk '{s+=$1} END {print int(s)}'
}

mount_fresh() {
    rm -f "$WORK/base.img"
    dd if=/dev/zero of="$WORK/base.img" bs=1m count=64 2>/dev/null
    mke2fs -q -t ext4 -L WEDGE -F "$WORK/base.img" || return 1
    DEV=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount \
          "$WORK/base.img" | head -1 | awk '{print $1}')
    [ -n "$DEV" ] || return 1
    mount -F -t ext4 "${DEV#/dev/}" "$MNT" 2>/dev/null
}

for round in $(seq 1 "$ROUNDS"); do
    printf "round %2d  " "$round"
    if ! mount_fresh; then
        echo "could not mount -- is the extension enabled?"
        exit 1
    fi

    for i in $(seq 1 12); do
        mkdir -p "$MNT/d$i/sub"
        echo "seed $i" > "$MNT/d$i/f$i.txt"
        ln -s "f$i.txt" "$MNT/d$i/link$i" 2>/dev/null
    done

    # The same shape as stage 0: ls -l and stat request parentID, which is the
    # attribute whose resolution once escaped the executor.
    start=$SECONDS
    for _ in 1 2 3 4 5 6; do
      ( for _ in $(seq 1 30); do
          ls -lR "$MNT" >/dev/null 2>&1
          stat "$MNT"/d*/sub >/dev/null 2>&1
        done ) &
    done
    ( for i in $(seq 1 60); do
        mkdir -p "$MNT/churn/$i" 2>/dev/null
        echo "$i" > "$MNT/churn/$i/f" 2>/dev/null
        rm -rf "$MNT/churn/$((i-2))" 2>/dev/null
      done ) &

    deadline=$(( SECONDS + 120 ))
    while jobs -r | grep -q .; do
        [ "$SECONDS" -gt "$deadline" ] && break
        sleep 1
    done

    if jobs -r | grep -q .; then
        echo "WEDGED after $(( SECONDS - start ))s, $(ext_cpu)% cpu"
        # Before anything is killed. This is the only artifact that says WHERE.
        for pid in $(pgrep -f "$EXT_PATTERN"); do
            sample "$pid" 5 -file "$OUT/wedge-$round-$pid.sample" >/dev/null 2>&1
        done
        ps -Ao pid,pcpu,comm | grep -i ext4fs | grep -v grep \
            > "$OUT/wedge-$round.log"
        echo "  samples in $OUT/wedge-$round-*.sample"
        pkill -9 -f "$EXT_PATTERN"
        sleep 2
        cleanup; DEV=""
        exit 1
    fi

    echo "ok ($(( SECONDS - start ))s, $(ext_cpu)% cpu)"
    umount "$MNT" 2>/dev/null
    hdiutil detach "$DEV" >/dev/null 2>&1; DEV=""
done

echo "no wedge in $ROUNDS round(s)"
