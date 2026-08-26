#!/usr/bin/env bash
# Crash consistency against the *mounted* FSKit driver.
#
# Tests/run_crash_tests.sh proves the ext4 core recovers from a severed write
# stream, but it drives the core directly through ext4dump's pwrite(). That
# says nothing about the path an actual mount takes:
# FSBlockDeviceResource.write, inside a sandboxed extension, called by the
# kernel. Ordering and durability there are assumptions, not documented
# guarantees. This suite tests them.
#
# The cut is made by stopping the extension process itself. SIGSTOP freezes
# every thread where it stands, so whatever has reached the medium at that
# instant is exactly what a power failure would have left behind -- no
# cooperation from the driver, no errno it could have reacted to. The device is
# then imaged, the driver resumed, and the image handed to the real Linux
# kernel to replay.
#
#   stage 0  concurrency   the kernel issues volume operations in parallel;
#                          every core entry must be serialised or lwext4's
#                          block cache corrupts and the volume wedges
#   stage 1  durability    an operation that has returned to userspace must
#                          survive the power cut that follows it
#   stage 2  crash sweep   snapshots taken at arbitrary moments under load
#                          must all recover clean
#
# Needs the extension signed, installed and enabled, plus Docker. Runs
# unattended. Writes a report to build/mount-crash-report.txt.
set -uo pipefail

export PATH="/opt/homebrew/opt/e2fsprogs/sbin:/opt/homebrew/opt/e2fsprogs/bin:$PATH"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/build/mount-crash"
REPORT="$ROOT/build/mount-crash-report.txt"
MNT="/tmp/ext4-mount-crash"
DOCKER_IMAGE="debian:stable-slim"

BUNDLE_ID="dev.h3ct0r.ext4mac.Ext4FS"
# Matches only our extension's own executable, not the container app.
EXT_PATTERN="/Ext4FS.appex/Contents/MacOS/Ext4FS"

IMAGE_MB=64
SWEEP_SNAPSHOTS="${SWEEP_SNAPSHOTS:-24}"

PASS=0; FAIL=0
note() { echo "$*" | tee -a "$REPORT"; }
ok()   { PASS=$((PASS+1)); note "  ok    $1"; }
bad()  { FAIL=$((FAIL+1)); note "  FAIL  $1"; [ $# -gt 1 ] && note "        $2"; }

DEV=""

# --------------------------------------------------------------- teardown --
# The driver must never be left frozen: a stopped extension wedges the mount
# and every process that touches it, including this script's own cleanup.
cleanup() {
  pkill -CONT -f "$EXT_PATTERN" 2>/dev/null
  [ -n "${WORKLOAD_PID:-}" ] && kill "$WORKLOAD_PID" 2>/dev/null
  [ -n "${READER_PID:-}" ] && kill "$READER_PID" 2>/dev/null
  pkill -f "ext4-mount-crash-workload" 2>/dev/null
  umount "$MNT" 2>/dev/null
  [ -n "$DEV" ] && hdiutil detach "$DEV" -force >/dev/null 2>&1
  return 0
}

# A wedged volume cannot be unmounted and does not respond to signals: its
# callers sit in uninterruptible wait until the driver answers, which it never
# will. Killing the extension is what releases them.
force_recover() {
  note "  recovering: killing the extension to release the stuck volume"
  pkill -9 -f "$EXT_PATTERN" 2>/dev/null
  local deadline=$(( SECONDS + 30 ))
  while [ "$SECONDS" -lt "$deadline" ]; do
    mount | grep -q "$(basename "$MNT") " || break
    sleep 1
  done
  umount "$MNT" 2>/dev/null
  [ -n "$DEV" ] && hdiutil detach "$DEV" -force >/dev/null 2>&1
  DEV=""
}
trap cleanup EXIT INT TERM

# ----------------------------------------------------------- requirements --
if ! pluginkit -m -p com.apple.fskit.fsmodule 2>/dev/null | grep -q "$BUNDLE_ID"; then
  echo "the FSKit extension is not registered with the system."
  echo "install it with 'make install SIGN_ID=...' and enable it in"
  echo "System Settings > General > Login Items & Extensions > File System Extensions."
  echo "SKIPPED"
  # 77 is the conventional "skipped, not passed" exit status. Reporting a skip
  # as success is how a suite quietly stops testing anything.
  exit 77
fi
docker info >/dev/null 2>&1 || { echo "docker is not running; cannot replay journals"; exit 1; }
command -v mke2fs >/dev/null || { echo "mke2fs not found; brew install e2fsprogs"; exit 1; }
mount | grep -q "$(basename "$MNT") " && { echo "$MNT is already mounted"; exit 1; }
pgrep -f "ext4-mount-crash-workload" >/dev/null 2>&1 && {
  echo "a workload from an earlier run is still going; kill it first"; exit 1; }

# An aborted run can leave files in the mount point on local disk. Mounting
# over them hides them, so the run looks normal right up until the mount is
# gone and the workload is quietly writing to the boot volume instead. $MNT is
# a fixed scratch path this suite owns, so clearing it is safe.
if [ -d "$MNT" ] && [ -n "$(ls -A "$MNT" 2>/dev/null)" ]; then
  echo "clearing stale contents left in $MNT by an earlier run"
  rm -rf "${MNT:?}"
fi

rm -rf "$WORK"; mkdir -p "$WORK"
: > "$REPORT"

# Marker for `find -newer`: any Ext4FS crash report younger than this file was
# produced by this run. The extension dying is invisible from the outside --
# FSKit restarts it and the volume keeps working -- so without this check a
# driver that traps on every unmount still looks green.
CRASH_DIR="$HOME/Library/Logs/DiagnosticReports"
: > "$WORK/.started"

# ------------------------------------------------------------- primitives --

freeze_and_snapshot() {  # freeze_and_snapshot <output image>
  local out="$1"
  pkill -STOP -f "$EXT_PATTERN"
  dd if="/dev/r${DEV#/dev/}" of="$out" bs=1m 2>/dev/null
  pkill -CONT -f "$EXT_PATTERN"
}

mount_volume() {
  cp "$WORK/base.img" "$WORK/live.img"
  DEV=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount "$WORK/live.img" \
        | head -1 | awk '{print $1}')
  [ -n "$DEV" ] || { note "could not attach the image"; exit 1; }
  mkdir -p "$MNT"
  local out
  if ! out=$(mount -F -t ext4 "${DEV#/dev/}" "$MNT" 2>&1); then
    # Installing the app does not enable the extension: macOS requires the user
    # to approve it, and reinstalling or changing Info.plist revokes that
    # approval. The module is registered but inert until they do.
    if printf '%s' "$out" | grep -q "is disabled"; then
      note "the extension is installed but not enabled."
      note "Turn it on in System Settings > General > Login Items & Extensions"
      note "  > File System Extensions, then run this again."
      note "SKIPPED"
      hdiutil detach "$DEV" >/dev/null 2>&1; DEV=""
      exit 77
    fi
    note "mount failed: $out"
    exit 1
  fi
  assert_mounted "after mounting"
}

# Every write in this suite goes through a path, not a handle. If the volume
# stops being mounted the path still exists, the writes still succeed, and they
# land on the boot disk -- so the run continues and reports on a volume nothing
# ever touched. Check rather than assume.
assert_mounted() {  # assert_mounted <when>
  if ! mount | grep -q "^$DEV on .*$(basename "$MNT") "; then
    note "  the volume is not mounted at $MNT ($1)"
    note "  everything below would measure the boot disk, so stopping here"
    exit 1
  fi
}

unmount_volume() {
  umount "$MNT" 2>/dev/null
  hdiutil detach "$DEV" >/dev/null 2>&1
  DEV=""
}

# Whether a snapshot actually caught the volume mid-flight. A snapshot of a
# quiescent volume recovers trivially and proves nothing, so this is reported
# as coverage rather than assumed.
needs_recovery() {  # needs_recovery <image>
  dumpe2fs -h "$1" 2>/dev/null | grep -q "needs_recovery"
}

# ------------------------------------------------------------------ setup --
note "########## MOUNT CRASH CONSISTENCY ##########"
note ""
note "building a ${IMAGE_MB}MB ext4 volume"
dd if=/dev/zero of="$WORK/base.img" bs=1m count="$IMAGE_MB" 2>/dev/null
mke2fs -q -t ext4 -L MOUNTCRASH -F "$WORK/base.img" || { note "mke2fs failed"; exit 1; }

# ================================================== stage 0: concurrency ==
#
# FSKit issues volume operations concurrently. lwext4 has no internal locking,
# so every entry into the core has to go through the serial executor. When one
# did not -- getAttributes resolved parentID outside it -- two kernel threads
# raced inside the block cache, corrupted its LRU list and spun forever in
# ext4_bcache_free. The volume wedged at 200% CPU and umount hung in
# uninterruptible wait. This is the regression test for that.

note ""
note "stage 0: concurrent operations"
note ""

mount_volume

for i in $(seq 1 12); do
  mkdir -p "$MNT/d$i/sub"
  echo "seed $i" > "$MNT/d$i/f$i.txt"
  ln -s "f$i.txt" "$MNT/d$i/link$i" 2>/dev/null
done

# Six readers walking the tree while a writer mutates it. `ls -l` and `stat`
# are what make this bite: they request parentID, which is the attribute whose
# resolution used to escape the executor.
CONC_START=$SECONDS
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

# A wedged volume never returns, so the pass condition is that it finishes.
CONC_DEADLINE=$(( SECONDS + 120 ))
while jobs -r | grep -q .; do
  if [ "$SECONDS" -gt "$CONC_DEADLINE" ]; then break; fi
  sleep 1
done

WEDGED=0
if jobs -r | grep -q .; then
  WEDGED=1
  bad "concurrent readers and writers complete" "still running after 120s — the volume is wedged"
else
  ok "concurrent readers and writers complete ($(( SECONDS - CONC_START ))s)"
fi

# A spinning extension is the other half of the symptom: the wedge burns CPU in
# a list walk rather than blocking on anything.
sleep 3
EXT_CPU=$(ps -Ao %cpu,command | grep "$EXT_PATTERN" | grep -v grep | awk '{s+=$1} END {print int(s)}')
EXT_CPU=${EXT_CPU:-0}
if [ "$EXT_CPU" -lt 50 ]; then
  ok "extension goes idle when the load stops (${EXT_CPU}% cpu)"
else
  WEDGED=1
  bad "extension goes idle when the load stops" "still at ${EXT_CPU}% cpu three seconds later"
fi

# Everything after this point writes to the volume, so there is nothing to
# learn from continuing against one that no longer answers. Bail out here --
# and do not `wait`, because the stuck readers will not be reaped until the
# driver is gone.
if [ "$WEDGED" -eq 1 ]; then
  force_recover
  note ""
  note "─────────────────────────────────"
  note "passed: $PASS   failed: $FAIL"
  note "stopped after stage 0: the volume stopped answering, so the"
  note "durability and crash stages would only measure the wedge."
  note "report: $REPORT"
  exit 1
fi
wait 2>/dev/null

# =================================================== stage 0b: open-unlink ==
#
# A file can be unlinked while it is still open. ext4 frees an inode the moment
# its last link goes away, which is too early: the kernel keeps sending reads
# and writes for that descriptor afterwards. Freeing it there means the writes
# allocate blocks onto an inode nothing references -- the data reads back
# correctly, so nothing looks wrong from userspace, but the blocks are never
# recovered.
#
# The damage is only visible after unmounting, so the e2fsck at the end of
# stage 2 is what actually catches it; this stage just does the deed.

note ""
note "stage 0b: files unlinked while open"
note ""

if python3 - "$MNT" <<'OPENUNLINK'
import os, sys, hashlib
M = sys.argv[1]
d = os.path.join(M, "openunlink")
os.makedirs(d, exist_ok=True)
ok = True

# Write *after* the unlink -- the case that leaks blocks.
p = os.path.join(d, "written-after.bin")
f = open(p, "w+b"); os.unlink(p)
f.write(b"B" * 65536); f.flush(); f.seek(0)
if f.read() != b"B" * 65536:
    print("    content written after unlink came back wrong"); ok = False
f.close()

# A file far too big to be served from a cache.
p2 = os.path.join(d, "read-after.bin")
payload = os.urandom(8 << 20)
with open(p2, "wb") as g: g.write(payload)
f2 = open(p2, "rb"); os.unlink(p2)
h = hashlib.sha256()
while c := f2.read(1 << 16): h.update(c)
f2.close()
if h.hexdigest() != hashlib.sha256(payload).hexdigest():
    print("    8 MiB read through an unlinked descriptor did not match"); ok = False

sys.exit(0 if ok else 1)
OPENUNLINK
then
  ok "files unlinked while open still read and write correctly"
else
  bad "files unlinked while open still read and write correctly"
fi
rm -rf "$MNT/openunlink" 2>/dev/null

# ==================================================== stage 1: durability ==
#
# The offline sweep proves a torn write stream recovers to *some* consistent
# state. That is not sufficient on its own: a driver that discarded everything
# would also pass. An operation that has returned to userspace must still be
# there afterwards. Only metadata operations are tested here — file data goes
# through the unified buffer cache, which is entitled to hold it.

note ""
note "stage 1: operations survive the cut that follows them"
note ""

DUR="$WORK/durability"
mkdir -p "$DUR"
mkdir -p "$MNT/dur"

: > "$WORK/dur-manifest.txt"
durability_case() {  # durability_case <name> <setup> <operation> <check>
  local name="$1" setup="$2" op="$3" check="$4"
  [ -n "$setup" ] && eval "$setup"
  sync 2>/dev/null
  eval "$op"
  freeze_and_snapshot "$DUR/$name.img"
  printf '%s\t%s\n' "$name" "$check" >> "$WORK/dur-manifest.txt"
}

durability_case mkdir    ""                          \
  'mkdir "$MNT/dur/made"'                            \
  '[ -d /mnt/t/dur/made ]'
durability_case create   ""                          \
  'touch "$MNT/dur/created"'                         \
  '[ -f /mnt/t/dur/created ]'
durability_case symlink  ""                          \
  'ln -s ../target "$MNT/dur/symlinked"'             \
  '[ "$(readlink /mnt/t/dur/symlinked)" = "../target" ]'
durability_case hardlink 'touch "$MNT/dur/orig"'     \
  'ln "$MNT/dur/orig" "$MNT/dur/hardlinked"'         \
  '[ "$(stat -c %h /mnt/t/dur/hardlinked)" = "2" ]'
durability_case rename   'touch "$MNT/dur/before"'   \
  'mv "$MNT/dur/before" "$MNT/dur/after"'            \
  '[ -f /mnt/t/dur/after ] && [ ! -e /mnt/t/dur/before ]'
durability_case unlink   'touch "$MNT/dur/doomed"'   \
  'rm "$MNT/dur/doomed"'                             \
  '[ ! -e /mnt/t/dur/doomed ]'
durability_case rmdir    'mkdir "$MNT/dur/emptydir"' \
  'rmdir "$MNT/dur/emptydir"'                        \
  '[ ! -e /mnt/t/dur/emptydir ]'

note "  $(wc -l < "$WORK/dur-manifest.txt" | tr -d ' ') operations snapshotted immediately after returning"

# ==================================================== stage 2: crash sweep ==
#
# Continuous mixed load, cut at arbitrary moments. Unlike the offline sweep the
# cut points are not enumerable -- there is no way to count the writes a
# mounted driver will issue -- so they are sampled instead.

note ""
note "stage 2: crash sweep under load ($SWEEP_SNAPSHOTS snapshots)"
note ""

SWEEP="$WORK/sweep"
mkdir -p "$SWEEP"

cat > "$WORK/workload.sh" <<'WORKLOAD'
#!/usr/bin/env bash
# Every mutating operation the driver implements, in a loop, forever.
M="$1"
i=0
while :; do
  i=$((i+1))
  d="$M/w$((i % 6))"
  mkdir -p "$d/nested"                                  2>/dev/null
  echo "round $i payload" > "$d/f$i.txt"                2>/dev/null
  dd if=/dev/urandom of="$d/big$i.bin" bs=4k \
     count=$(( (i % 30) + 1 ))                          2>/dev/null
  ln -s "f$i.txt" "$d/link$i"                           2>/dev/null
  ln "$d/f$i.txt" "$d/hard$i"                           2>/dev/null
  xattr -w user.round "$i" "$d/f$i.txt"                 2>/dev/null
  mv "$d/f$i.txt" "$d/nested/moved$i.txt"               2>/dev/null
  : > "$d/big$i.bin"                                    2>/dev/null
  rm -f "$d/hard$i" "$d/link$i"                         2>/dev/null
  # Keep the volume from filling: drop a round from three iterations back.
  p=$((i - 3)); [ "$p" -gt 0 ] && rm -rf "$M/w$((p % 6))" 2>/dev/null
done
WORKLOAD
chmod +x "$WORK/workload.sh"

# The argument is never read; it is there so pgrep can find this process even
# if the script file has been deleted out from under it.
"$WORK/workload.sh" "$MNT" ext4-mount-crash-workload & WORKLOAD_PID=$!
( while :; do ls -lR "$MNT" >/dev/null 2>&1; done ) & READER_PID=$!

for n in $(seq 1 "$SWEEP_SNAPSHOTS"); do
  # Randomised so snapshots do not land in step with the workload's own period.
  perl -e 'select(undef, undef, undef, 0.10 + rand(0.45))'
  freeze_and_snapshot "$SWEEP/snap_$n.img"
done

kill "$WORKLOAD_PID" "$READER_PID" 2>/dev/null
wait "$WORKLOAD_PID" "$READER_PID" 2>/dev/null
WORKLOAD_PID=""; READER_PID=""

assert_mounted "after the sweep"

DIRTY=0
for img in "$SWEEP"/snap_*.img; do
  needs_recovery "$img" && DIRTY=$((DIRTY+1))
done
note "  $DIRTY of $SWEEP_SNAPSHOTS snapshots caught the volume mid-transaction"

# The mount has to come down cleanly after all that freezing.
UMOUNT_START=$SECONDS
if umount "$MNT" 2>/dev/null; then
  ok "clean unmount after $SWEEP_SNAPSHOTS freeze/resume cycles ($(( SECONDS - UMOUNT_START ))s)"
else
  bad "clean unmount after $SWEEP_SNAPSHOTS freeze/resume cycles"
fi
hdiutil detach "$DEV" >/dev/null 2>&1; DEV=""

# An inode that was unlinked while open and never released shows up here and
# nowhere else: the volume is structurally fine, but blocks are marked in use
# with nothing referencing them.
if e2fsck -fn "$WORK/live.img" >/dev/null 2>&1; then
  ok "no leaked blocks or inodes after unmount"
else
  bad "no leaked blocks or inodes after unmount" \
      "$(e2fsck -fn "$WORK/live.img" 2>&1 | grep -m1 -vE '^e2fsck|^Pass|^$' | cut -c1-70)"
fi

if [ "$(dumpe2fs -h "$WORK/live.img" 2>/dev/null | sed -n 's/^Filesystem state: *//p')" = "clean" ]; then
  ok "cleanly unmounted volume is marked clean"
else
  bad "cleanly unmounted volume is marked clean" \
      "state is [$(dumpe2fs -h "$WORK/live.img" 2>/dev/null | sed -n 's/^Filesystem state: *//p')]"
fi

# ======================================================= replay and verify ==
#
# One container for everything: per-image startup would dominate. The Linux
# kernel replays the journal on mount, exactly as the machine the disk came
# from would.

note ""
note "replaying journals with the Linux kernel"

docker run --rm --privileged -v "$WORK:/work" "$DOCKER_IMAGE" bash -c '
  mkdir -p /mnt/t

  while IFS=$'"'"'\t'"'"' read -r name check; do
    [ -z "$name" ] && continue
    img="/work/durability/$name.img"
    if ! mount -o loop "$img" /mnt/t 2>/dev/null; then
      echo "DUR-REFUSED $name"
      continue
    fi
    if eval "$check"; then echo "DUR-OK $name"; else echo "DUR-LOST $name"; fi
    umount /mnt/t
  done < /work/dur-manifest.txt

  for img in $(find /work/sweep -name "snap_*.img" | sort); do
    if mount -o loop "$img" /mnt/t 2>/dev/null; then
      umount /mnt/t
    else
      echo "SWEEP-REFUSED $(basename "$img")"
    fi
  done
' > "$WORK/replay.log" 2>&1

note ""
note "durability results"
note ""

while IFS=$'\t' read -r name _; do
  [ -z "$name" ] && continue
  if grep -q "^DUR-OK $name\$" "$WORK/replay.log"; then
    ok "$name survived the cut"
  elif grep -q "^DUR-REFUSED $name\$" "$WORK/replay.log"; then
    bad "$name survived the cut" "Linux refused to mount the snapshot"
  else
    bad "$name survived the cut" "the operation was gone after recovery"
  fi
done < "$WORK/dur-manifest.txt"

note ""
note "sweep results"
note ""

REFUSED=$(grep -c "^SWEEP-REFUSED" "$WORK/replay.log" 2>/dev/null) || REFUSED=0
REFUSED=${REFUSED:-0}
if [ "$REFUSED" -eq 0 ]; then
  ok "the Linux kernel mounted every snapshot"
else
  bad "the Linux kernel mounted every snapshot" "$REFUSED refused"
fi

# The error-flag check below reads the superblock, so record that first and
# then drop each image that passed: 31 copies of a 64 MB volume is 2 GB, and a
# recovered image has nothing left to tell us.
ERRORED=0
UNRECOVERED=0
for img in "$SWEEP"/snap_*.img "$DUR"/*.img; do
  [ -f "$img" ] || continue
  case "$(dumpe2fs -h "$img" 2>/dev/null | sed -n 's/^Filesystem state: *//p')" in
    *error*) ERRORED=$((ERRORED+1)) ;;
  esac
  if e2fsck -fn "$img" >/dev/null 2>&1; then
    rm -f "$img"
  else
    UNRECOVERED=$((UNRECOVERED+1))
    if [ "$UNRECOVERED" -le 3 ]; then
      note "        $(basename "$img" .img): $(e2fsck -fn "$img" 2>&1 | grep -m1 -vE '^e2fsck|^Pass|^$' | cut -c1-70)"
    fi
  fi
done
rm -f "$WORK/base.img" "$WORK/live.img"
if [ "$UNRECOVERED" -eq 0 ]; then
  ok "every snapshot is clean after recovery"
else
  bad "every snapshot is clean after recovery" "$UNRECOVERED of $SWEEP_SNAPSHOTS did not recover"
fi

# A volume that recovers but reports itself damaged sends the user to a repair
# tool they do not need. lwext4 used to mark mounted volumes with the error
# flag, which made every power cut look like corruption. Counted above.
if [ "$ERRORED" -eq 0 ]; then
  ok "no snapshot falsely reports filesystem errors"
else
  bad "no snapshot falsely reports filesystem errors" "$ERRORED of $SWEEP_SNAPSHOTS carry the error flag"
fi

# The extension must not have died at any point. FSKit relaunches it, so a
# trap or a failed assertion leaves no trace in the test results themselves --
# only a crash report. This is how the nil-device trap in synchronize() was
# found: every stage passed, and every unmount crashed the extension.
NEW_CRASHES=$(find "$CRASH_DIR" -name "Ext4FS-*.ips" -newer "$WORK/.started" 2>/dev/null | wc -l | tr -d ' ')
NEW_CRASHES=${NEW_CRASHES:-0}
if [ "$NEW_CRASHES" -eq 0 ]; then
  ok "the extension never crashed"
else
  newest=$(find "$CRASH_DIR" -name "Ext4FS-*.ips" -newer "$WORK/.started" 2>/dev/null | sort | tail -1)
  where=$(grep -o '"symbol":"[^"]*"' "$newest" 2>/dev/null | head -3 | sed 's/"symbol":"//;s/"//' | tr '\n' ' ')
  bad "the extension never crashed" "$NEW_CRASHES crash report(s); newest at: ${where:-see $newest}"
fi

note ""
note "─────────────────────────────────"
note "passed: $PASS   failed: $FAIL"
note "snapshots: $(( SWEEP_SNAPSHOTS + $(wc -l < "$WORK/dur-manifest.txt" | tr -d ' ') ))   caught mid-transaction: $DIRTY"
note "report: $REPORT"

[ "$FAIL" -eq 0 ]
