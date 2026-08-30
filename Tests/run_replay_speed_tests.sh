#!/usr/bin/env bash
# Does journal replay fit inside DiskArbitration's mount timeout?
#
# On 2026-08-29 a LUKS2+ext4 USB stick that had been unplugged mid-write took
# over eight minutes to replay its journal, and DiskArbitration gave up on the
# mount after about twenty seconds (0x3C ETIMEDOUT). A sample of the wedged
# extension showed why: jbd_iterate_log read the journal one 4 KiB block per
# pread through the LUKS layer, and jbd_replay_block_tags wrote every replayed
# block back one flush at a time. Correct, and hopeless on a medium where each
# command has a fixed setup cost.
#
# A disk image cannot show any of that -- through the page cache a 4 KiB read
# costs the same as a 512 KiB one -- so this suite measures the *shape* of the
# I/O instead, and then prices it like the medium that produced the incident:
# ext4dump's media model (EXT4DUMP_IO_LATENCY_US / EXT4DUMP_IO_BW_MBS) charges
# a fixed cost per command plus a transfer cost per byte, tuned to an ordinary
# USB stick. The budget is DiskArbitration's: recovery that cannot finish in
# twenty modelled seconds is recovery that times out on real hardware.
#
# The fixture is the incident, reconstructed: a LUKS2 container holding an
# ext4 filesystem with a 128 MiB journal (mkfs.ext4 -J size=128, the shape
# GNOME Disks produces), filled by our own driver under a metadata-heavy load
# and then SIGKILLed mid-write, leaving thousands of committed-but-unreplayed
# transactions. Replay correctness is checked the same way the other suites
# check it: e2fsck over the decrypted payload, and files written before the
# kill still legible afterwards.
#
# Needs Docker for cryptsetup; skips with exit 77 if it is not running.
# Runs unattended. Writes a report to build/replay-speed-report.txt.
set -uo pipefail

export PATH="/opt/homebrew/opt/e2fsprogs/sbin:/opt/homebrew/opt/e2fsprogs/bin:$PATH"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DUMP="$ROOT/build/bin/ext4dump"
WORK="$ROOT/build/replay-speed"
REPORT="$ROOT/build/replay-speed-report.txt"
DOCKER_IMAGE="ext4luks:cryptsetup-attr"

# The media model: a fixed per-command cost plus a transfer rate, the two
# numbers that define a USB stick. 500 us per command is a mid-range stick on
# a good day; the incident's was slower.
LATENCY_US=500
BW_MBS=40
# DiskArbitration's patience, roughly. The whole point of the suite.
DA_BUDGET_S=20

PASS=0; FAIL=0
note() { echo "$*" | tee -a "$REPORT"; }
ok()   { PASS=$((PASS+1)); note "  ok    $1"; }
# `bad` must end in a success status; see the note in the other suites.
bad()  { FAIL=$((FAIL+1)); note "  FAIL  $1"; [ $# -gt 1 ] && note "        $2"; return 0; }

[ -x "$DUMP" ] || { echo "build first: make tools"; exit 1; }
command -v e2fsck >/dev/null || { echo "e2fsck not found; brew install e2fsprogs"; exit 1; }
command -v debugfs >/dev/null || { echo "debugfs not found; brew install e2fsprogs"; exit 1; }

if ! docker info >/dev/null 2>&1; then
  echo "docker is not running; cryptsetup is the only way to make a LUKS fixture"
  echo "SKIPPED"
  exit 77
fi

rm -rf "$WORK"; mkdir -p "$WORK"
: > "$REPORT"

# The fixtures are ~400 MB each and one of them is a plaintext passphrase.
# Nothing here is worth keeping: the report survives outside $WORK, and a
# debugging session rebuilds the fixture deterministically in under a minute.
trap 'rm -rf "$WORK"' EXIT

PASSPHRASE="correct horse battery staple"
printf '%s' "$PASSPHRASE" > "$WORK/pass.txt"
export EXT4DUMP_LUKS_KEYFILE="$WORK/pass.txt"

in_linux() { docker run --rm --privileged -v "$WORK:/w" "$DOCKER_IMAGE" bash -c "$1"; }

note "########## journal replay speed ##########"
note ""
note "media model: ${LATENCY_US}us per command + ${BW_MBS} MB/s; budget ${DA_BUDGET_S}s"
note ""

if ! docker image inspect "$DOCKER_IMAGE" >/dev/null 2>&1; then
  echo "building $DOCKER_IMAGE (one-off, needs network)"
  docker build -q -t "$DOCKER_IMAGE" - >/dev/null <<'DOCKERFILE'
FROM debian:stable-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    cryptsetup-bin e2fsprogs attr && rm -rf /var/lib/apt/lists/*
DOCKERFILE
fi

# =================================================================== fixture ==
# LUKS2 with 4096-byte sectors, the modern default. pbkdf2 with the iteration
# floor so unlocking costs nothing measurable -- the suite times replay, not
# key derivation. The journal is 128 MiB because that is what mkfs.ext4 makes
# for a stick-sized volume when a GNOME user formats one.
note "building the container (cryptsetup, one-off)"
in_linux '
set -e
dd if=/dev/zero of=/w/bench.img bs=1M count=384 status=none
cryptsetup luksFormat --batch-mode --key-file /w/pass.txt \
  --type luks2 --sector-size 4096 --pbkdf pbkdf2 --pbkdf-force-iterations 1000 \
  /w/bench.img
cryptsetup luksOpen --key-file /w/pass.txt /w/bench.img rsbench
mkfs.ext4 -q -b 4096 -J size=128 -L REPLAYBENCH /dev/mapper/rsbench
cryptsetup luksClose rsbench
echo BUILT
' 2>&1 | tail -1 | sed 's/^/  /'
[ -f "$WORK/bench.img" ] || { note "  fixture was not built"; exit 1; }

# A metadata-heavy load: file creation is almost pure journal traffic. Twice
# as much as the journal can hold, so the kill always lands mid-history. The
# directory create/remove cycles leave revoke blocks in the log -- a journal
# with none of them lets recovery skip its revoke pass entirely, and this
# suite must price the full three-pass walk a real mixed workload gets.
awk 'BEGIN{
  print "mkdir /d0";
  for (i = 0; i < 60000; i++) {
    if (i % 1000 == 0 && i > 0) printf "mkdir /d%d\n", i/1000;
    d = int(i/1000);
    printf "create /d%d/f%d\ncreate /d%d/g%d\n", d, i, d, i;
    if (i % 500 == 250) {
      printf "mkdir /t%d\ncreate /t%d/x\n", i, i;
      printf "rm /t%d/x\nrm /t%d\n", i, i;
    }
  }
}' > "$WORK/load.txt"

# Kill the driver mid-load, then confirm the journal really is deep: a kill
# that lands too early leaves a shallow log and a benchmark that measures
# nothing. The load is sized to run well past every kill point, and the kill
# point grows if a machine is fast enough to outrun it.
dirty_ok=""
for kill_after in 20 40 80; do
  cp "$WORK/bench.img" "$WORK/dirty.img"
  "$DUMP" "$WORK/dirty.img" script "$WORK/load.txt" >/dev/null 2>&1 &
  load_pid=$!
  sleep "$kill_after"
  if kill -0 "$load_pid" 2>/dev/null; then
    kill -9 "$load_pid" 2>/dev/null
    wait "$load_pid" 2>/dev/null
  else
    wait "$load_pid" 2>/dev/null
    note "  load finished before the ${kill_after}s kill; retrying with a later one"
    continue
  fi

  "$DUMP" "$WORK/dirty.img" decrypt "$WORK/dirty-plain.img" >/dev/null 2>&1
  if ! dumpe2fs -h "$WORK/dirty-plain.img" 2>/dev/null \
       | grep -q 'needs_recovery'; then
    note "  kill left a clean journal at ${kill_after}s; retrying"
    continue
  fi
  trans=$(debugfs -R 'logdump -S' "$WORK/dirty-plain.img" 2>/dev/null \
          | grep -c 'descriptor block')
  revokes=$(debugfs -R 'logdump -S' "$WORK/dirty-plain.img" 2>/dev/null \
            | grep -ci 'revoke')
  note "  killed at ${kill_after}s: $trans transactions waiting for replay, $revokes revoke blocks"
  if [ "${trans:-0}" -ge 500 ] && [ "${revokes:-0}" -ge 1 ]; then dirty_ok=yes; break; fi
  note "  journal too shallow ($trans transactions, $revokes revoke blocks); retrying with a later kill"
done
[ -n "$dirty_ok" ] || { bad "could not construct a deep dirty journal"; note ""; note "RESULT: FAIL"; exit 1; }

# ================================================================== recovery ==
note ""
note "replaying through the modelled stick"
note ""

# Files created long before any kill point; recovery must surface them.
PROBE_FILES="/d0/f3 /d0/g500 /d1/f1400"

cp "$WORK/dirty.img" "$WORK/recover.img"
SECONDS=0
EXT4DUMP_IO_STATS=1 \
  EXT4DUMP_IO_LATENCY_US=$LATENCY_US EXT4DUMP_IO_BW_MBS=$BW_MBS \
  "$DUMP" "$WORK/recover.img" label AFTERKILL >/dev/null 2>"$WORK/recover.err"
elapsed=$SECONDS
stats=$(grep IOSTATS "$WORK/recover.err")

reads=$(echo "$stats"  | sed -n 's/.*reads=\([0-9]*\).*/\1/p')
writes=$(echo "$stats" | sed -n 's/.*writes=\([0-9]*\).*/\1/p')
read_bytes=$(echo "$stats"  | sed -n 's/.*read_bytes=\([0-9]*\).*/\1/p')
write_bytes=$(echo "$stats" | sed -n 's/.*write_bytes=\([0-9]*\).*/\1/p')
note "  recovery mount: ${elapsed}s modelled; $stats"

if [ "$elapsed" -le "$DA_BUDGET_S" ]; then
  ok "recovery fits DiskArbitration's ~${DA_BUDGET_S}s budget (${elapsed}s)"
else
  bad "recovery blows DiskArbitration's ~${DA_BUDGET_S}s budget" \
      "${elapsed}s modelled; a real mount times out at ~20s and the volume never appears"
fi

# The shape itself, independent of any timing: replay of a ~32k-block journal
# must not take ~one command per block. The bound is loose -- header reads in
# the scan passes are legitimately per-block today -- but it is far below what
# per-block replay reads and per-block write-back cost.
total_ops=$(( ${reads:-0} + ${writes:-0} ))
if [ "$total_ops" -le 20000 ]; then
  ok "replay I/O is batched ($total_ops commands)"
else
  bad "replay still issues ~one command per journal block" \
      "$total_ops commands for a ~32k-block journal"
fi

# The other half of the fix was byte volume: replayed blocks are written once
# (the newest logged copy), not once per transaction that logged them. Without
# dedup this fixture writes ~90-120 MB; with it, ~25 MB. And the log itself is
# read once plus the header passes -- a regression that re-read it per pass
# would keep the command count while tripling the bytes.
if [ "${write_bytes:-0}" -le 50000000 ]; then
  ok "replayed blocks are written once ($(( ${write_bytes:-0} / 1000000 )) MB)"
else
  bad "replay writes each block once per transaction again" \
      "$write_bytes bytes written for a ~128 MiB journal"
fi
if [ "${read_bytes:-0}" -le 250000000 ]; then
  ok "the log is read about once ($(( ${read_bytes:-0} / 1000000 )) MB)"
else
  bad "replay re-reads the log" "$read_bytes bytes read for a ~128 MiB journal"
fi

# The line a hardware tester will grep for. A replay that does not report its
# duration puts the next incident back to `sample` and guesswork.
if grep -q 'journal replayed in [0-9]* ms' "$WORK/recover.err"; then
  ok "replay reports its duration ($(sed -n 's/.*journal replayed in \([0-9]* ms\).*/\1/p' "$WORK/recover.err" | head -1))"
else
  bad "replay finished without reporting its duration"
fi

# ================================================================ correctness ==
note ""
note "what replay produced"
note ""

"$DUMP" "$WORK/recover.img" decrypt "$WORK/recovered-plain.img" >/dev/null 2>&1
if dumpe2fs -h "$WORK/recovered-plain.img" 2>/dev/null | grep -q 'needs_recovery'; then
  bad "recovery did not clear needs_recovery"
else
  ok "needs_recovery is cleared"
fi

fsck_out=$(e2fsck -fn "$WORK/recovered-plain.img" 2>&1)
if [ $? -eq 0 ]; then
  ok "e2fsck accepts the replayed filesystem"
else
  bad "e2fsck rejects the replayed filesystem" \
      "$(echo "$fsck_out" | grep -Evi '^e2fsck |^Pass [0-9]' | head -3 | tr '\n' ' ')"
fi

for f in $PROBE_FILES; do
  if "$DUMP" "$WORK/recover.img" stat "$f" >/dev/null 2>&1; then
    ok "pre-kill file survived replay: $f"
  else
    bad "pre-kill file lost by replay: $f"
  fi
done

# A second mount of the now-clean volume, for scale: this is what mounting
# costs when there is nothing to replay. The gap between this line and the
# recovery line above is the price of the journal.
cp "$WORK/recover.img" "$WORK/clean.img"
SECONDS=0
EXT4DUMP_IO_LATENCY_US=$LATENCY_US EXT4DUMP_IO_BW_MBS=$BW_MBS \
  "$DUMP" "$WORK/clean.img" label CLEANMOUNT >/dev/null 2>&1
note ""
note "  clean mount of the same volume: ${SECONDS}s modelled (for scale)"

# ==================================================================== eject ==
# Eject has an OS timeout just as mount does, and the unmount that ends a
# session flushes every remaining checkpoint. Priced the same way: a write
# flood through the LUKS layer, then the session's own unmount, all under
# the media model. The bounds are the shape, not a diff: a regression to
# per-block checkpointing (or to trading writes for barriers -- flushes are
# counted now) blows them immediately.
note ""
note "a write flood and its eject, priced"
note ""

awk 'BEGIN{ for (i = 0; i < 400; i++) printf "create /e%d\n", i }' \
  > "$WORK/eject-load.txt"
SECONDS=0
stats=$(EXT4DUMP_IO_STATS=1 \
        EXT4DUMP_IO_LATENCY_US=$LATENCY_US EXT4DUMP_IO_BW_MBS=$BW_MBS \
        "$DUMP" "$WORK/clean.img" script "$WORK/eject-load.txt" 2>&1 >/dev/null \
        | grep IOSTATS)
elapsed=$SECONDS
writes=$(echo "$stats" | sed -n 's/.*writes=\([0-9]*\).*/\1/p')
flushes=$(echo "$stats" | sed -n 's/.*flushes=\([0-9]*\).*/\1/p')
note "  400 creates + eject: ${elapsed}s modelled; $stats"
if [ "$elapsed" -le "$DA_BUDGET_S" ]; then
  ok "the flood and its eject fit the ~${DA_BUDGET_S}s budget (${elapsed}s)"
else
  bad "eject blows the budget" "${elapsed}s modelled"
fi
if [ "${writes:-99999}" -le 1500 ] && [ "${flushes:-99999}" -le 150 ]; then
  ok "eject I/O keeps its shape ($writes writes, $flushes flushes)"
else
  bad "the eject path issues per-block commands again" "$stats"
fi

note ""
note "PASS $PASS FAIL $FAIL"
if [ "$FAIL" -eq 0 ]; then note "RESULT: PASS"; else note "RESULT: FAIL"; exit 1; fi
