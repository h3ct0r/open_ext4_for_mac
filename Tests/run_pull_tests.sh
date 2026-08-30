#!/usr/bin/env bash
# Physical pull test -- can a mid-write pull hurt this driver?
#
# Each round: format the stick fresh, mount, run a metadata-heavy write load,
# tell the operator to PULL THE STICK mid-write, reinsert, let the driver
# recover, then autopsy: dd the partition to an image and measure two things.
#
#   consistency   after the driver's own recovery, `e2fsck -fn` finds nothing
#                 to fix. This is the claim a journal exists to make.
#   durability    every batch that had been through sync(2) before the pull is
#                 present bit for bit (sha256 manifest kept on the internal
#                 disk, checked with debugfs rdump). Informational: sync(2) on
#                 macOS reports success without proof, so a boundary batch can
#                 legitimately be in flight.
#
# This suite is what retired the write-barrier daemon. Run as an A/B -- a
# privileged helper issuing real DKIOCSYNCHRONIZE barriers against the same
# build with no barrier at all -- twenty pulls across five drives (USB-2
# sticks through an NVMe SSD behind a bridge chip, fenced and under sustained
# load) recovered identically: e2fsck-clean, nothing lost. The daemon went;
# this harness stays, because the result is a property of the direct-I/O
# write path, and a future change to that path needs a test that can
# contradict it. History says what failure looks like: the earliest write
# path lost half a transaction to one pull. See docs/STATUS.md.
#
# Usage (interactive: the pulls need hands):
#
#   DEVICE=diskN bash Tests/run_pull_tests.sh
#
#   ROUNDS=3 (default)   EXT4_SIZE=2g (default; must fit the stick)
#   KEEP_CORPSE=1        keep the dd image even when the round is clean
#   HARSH=1              sustained 1-2 MB writes with NO sync fences: the
#                        widest reorder window a drive cache gets. Durability
#                        is n/a (nothing is ever claimed durable); consistency
#                        is the whole measurement. Pull under full load.
#
# This ERASES the stick, repeatedly -- use one you can lose. Repeated hot
# pulls can also wedge DiskArbitration until a reboot; expect to reboot after
# a long session of them.
#
# A pull can even panic the whole machine: if the drive's bridge chip hangs
# the in-flight commands on surprise removal, the media object cannot finish
# terminating and xnu's 60 s busy-timeout watchdog panics rather than leak it
# ("busy timeout ... 'IOMediaBSDClient'", panicked task watchdogd). That is
# Apple's storage stack, not this driver, and it is drive-dependent -- one
# DataTraveler survived a dozen pulls, another drive panicked the Mac. Save
# your work before each round, and record which drive was in when it happens:
# a bridge that hangs on removal is a result, not a nuisance.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/Tests/lib.sh"

DEVICE="${DEVICE:-}"
ROUNDS="${ROUNDS:-3}"
EXT4_SIZE="${EXT4_SIZE:-2g}"
LABEL="EXT4PULL"
WARMUP="${WARMUP:-10}"

# One results directory per drive, so a four-drive sweep does not overwrite
# itself: TAG defaults to the media name plus the byte size, because two
# sticks of the same model are two different drives.
if [ -z "${TAG:-}" ]; then
  _info=$(diskutil info "${DEVICE%s[0-9]*}" 2>/dev/null)
  _name=$(sed -n 's|.*Device / Media Name: *||p' <<<"$_info" | head -1 \
          | tr 'A-Z ' 'a-z-' | tr -cd 'a-z0-9-')
  _bytes=$(sed -n 's/.*Disk Size:.*(\([0-9]*\) Bytes.*/\1/p' <<<"$_info" | head -1)
  TAG="${_name:-unnamed}${_bytes:+-$_bytes}"
fi
OUT="$ROOT/build/pulltest/$TAG-pull"
[ "${HARSH:-0}" = 1 ] && OUT="$OUT-harsh"

die() { echo "error: $*" >&2; exit 1; }

# ------------------------------------------------------------- preconditions

[ -n "$DEVICE" ] || die "no device. Usage: DEVICE=diskN bash Tests/run_pull_tests.sh"
DEVICE="${DEVICE%s[0-9]*}"

command -v e2fsck  >/dev/null || die "e2fsck not on PATH (brew install e2fsprogs)"
command -v debugfs >/dev/null || die "debugfs not on PATH (brew install e2fsprogs)"
[ -d /Library/Filesystems/ext4.fs ] || die "missing /Library/Filesystems/ext4.fs (sudo make install-diskutil)"
diskutil info "$DEVICE" >/dev/null 2>&1 || die "$DEVICE is not a disk this machine knows about"

# Internal-vs-External is the safety line, not the removable bit: large
# sticks and USB SSDs claim "Fixed" media on an external bus, and drives
# with real caches behind bridge chips are the test targets most worth
# having, not targets to refuse.
INFO=$(diskutil info "$DEVICE" 2>/dev/null)
LOCATION=$(sed -n 's/.*Device Location: *//p' <<<"$INFO" | head -1)
REMOVABLE=$(sed -n 's/.*Removable Media: *//p' <<<"$INFO" | head -1)
case "$LOCATION:$REMOVABLE" in
  Internal:*) die "$DEVICE is an internal disk; refusing" ;;
  External:*) ;;
  *:*emovable*) ;;
  *) die "$DEVICE reports neither External nor Removable (location '${LOCATION:-none}', media '${REMOVABLE:-none}'); refusing" ;;
esac

# The full gate, not the pluginkit guess (check_extension.sh documents why
# pluginkit misreports): extension answers a real mount, install is fresh,
# tools built, .fs bundle in place, sudo primed. This is the costliest suite
# in the tree -- rounds of physical pulls -- and it used to be the only
# hardware suite with no freshness check: a stale install would burn the
# whole session measuring last week's build.
bash "$ROOT/scripts/preflight.sh" \
  || die "preflight failed; nothing below would measure this build"

echo "about to run $ROUNDS pull round(s), erasing /dev/$DEVICE each time"
echo "    $(sed -n 's/.*Device \/ Media Name: */name  /p' <<<"$INFO" | head -1)"
echo "    $(sed -n 's/.*Disk Size: */size  /p' <<<"$INFO" | head -1)"
echo ""
printf "type ERASE to continue: "
read -r answer
[ "$answer" = "ERASE" ] || die "not confirmed"

sudo -v || die "needs sudo for format and dd"

mkdir -p "$OUT"

# ------------------------------------------------------------------ helpers

# The stick's BSD name changes on every replug; these keep track of it.
CUR="$DEVICE"
PART=""

part_of() {  # newest partition node for a whole disk
  [ -e "/dev/${1}s2" ] && { echo "${1}s2"; return; }
  [ -e "/dev/${1}s1" ] && { echo "${1}s1"; return; }
  echo ""
}

# diskutil, not the mount table: FSKit mounts do not appear as
# "/dev/diskNsM on ..." in `mount` output, and a grep for that spent a full
# round staring straight past a mounted volume.
vol_mounted() { diskutil info "$PART" 2>/dev/null | grep -q "Mounted: *Yes"; }
vol_mp()      { diskutil info "$PART" 2>/dev/null | sed -n 's/.*Mount Point: *//p' | head -1; }
vol_ro()      { diskutil info "$PART" 2>/dev/null | grep -q "Volume Read-Only: *Yes"; }

wait_mounted() {  # $1 = seconds
  local i
  for i in $(seq 1 "$1"); do
    vol_mounted && return 0
    sleep 1
  done
  return 1
}

snapshot_disks() { ls /dev | grep -E '^disk[0-9]+$'; }

wait_new_disk() {  # $1 = snapshot taken after the old node vanished
  local new="" d
  while [ -z "$new" ]; do
    sleep 1
    for d in $(snapshot_disks); do
      echo "$1" | grep -qx "$d" || new="$d"
    done
  done
  echo "$new"
}

rediscover() {  # call once /dev/$CUR is gone; updates CUR and PART
  local pre i
  pre="$(snapshot_disks)"
  echo "  reinsert the stick..."
  CUR="$(wait_new_disk "$pre")"
  PART=""
  for i in $(seq 1 15); do PART="$(part_of "$CUR")"; [ -n "$PART" ] && break; sleep 1; done
  [ -n "$PART" ] || die "reinserted disk $CUR has no partition node"
  echo "  back as /dev/$PART"
}

# Metadata-heavy load: write-tmp-then-rename, the pattern journaling protects.
# Hashes are recorded on the internal disk; a batch enters the manifest only
# after the sync(2) that followed it returned.
writer() {
  local dir="$1" rd="$2" b=0 i sz okbatch
  while :; do
    b=$((b+1))
    mkdir "$dir/batch_$b" 2>/dev/null || { sleep 0.3; continue; }
    : > "$rd/pending"
    okbatch=yes
    for i in $(seq 1 24); do
      if [ "${HARSH:-0}" = 1 ]; then
        sz=$(( (RANDOM % 1024 + 1024) * 1024 ))   # 1-2 MB, sustained
      else
        sz=$(( (RANDOM % 60 + 4) * 1024 ))
      fi
      head -c "$sz" /dev/urandom > "$dir/batch_$b/f$i.tmp" 2>/dev/null || { okbatch=no; break; }
      mv "$dir/batch_$b/f$i.tmp" "$dir/batch_$b/f$i" 2>/dev/null || { okbatch=no; break; }
      (cd "$dir" && shasum -a 256 "batch_$b/f$i" 2>/dev/null) >> "$rd/pending" || okbatch=no
    done
    # HARSH=1 drops the sync fences: no queue drain, no durable claims, the
    # deepest sustained load this stick can be handed -- the widest window a
    # drive cache gets to reorder in. Consistency is then the only metric.
    if [ "${HARSH:-0}" = 1 ]; then continue; fi
    sync 2>/dev/null
    # A batch that died mid-write ran its sync against a dead mount; claiming
    # it durable turned one boundary rename into a phantom "lost synced file".
    [ "$okbatch" = yes ] || continue
    cat "$rd/pending" >> "$rd/manifest" 2>/dev/null
    echo "$b" >> "$rd/durable"
  done
}

# --------------------------------------------------------------------- rounds

SUMMARY="$OUT/summary.tsv"
echo -e "round\tmount\tremount\tfsck_fn\tfsck_fy\tdurable\tsha_bad" > "$SUMMARY"

for r in $(seq 1 "$ROUNDS"); do
  RD="$OUT/round$r"
  rm -rf "$RD"; mkdir -p "$RD"
  echo ""
  echo "================ pull round $r/$ROUNDS ================"

  sudo -v
  echo "  formatting (takes a while; newfs runs during partitioning)..."
  if ! sudo env DEVICE="$CUR" CONFIRM=ERASE EXT4_LABEL="$LABEL" EXT4_SIZE="$EXT4_SIZE" \
      bash "$ROOT/scripts/prepare_device.sh" > "$RD/prepare.log" 2>&1; then
    tail -5 "$RD/prepare.log" | sed 's/^/    | /'
    die "prepare_device failed on $CUR (full log: $RD/prepare.log)"
  fi
  PART="$(part_of "$CUR")"
  [ -n "$PART" ] || die "no partition node appeared on $CUR"
  echo "  formatted /dev/$PART ($EXT4_SIZE)"

  if ! wait_mounted 30; then
    diskutil mount "/dev/$PART" >/dev/null 2>&1
    if ! wait_mounted 10; then
      # DiskArbitration can cache a "no filesystem" verdict from mid-format;
      # a replug forces full re-enumeration and a fresh probe.
      echo "  not mounting -- DiskArbitration may hold a stale verdict."
      echo "  unplug the stick now..."
      while [ -e "/dev/$CUR" ]; do sleep 0.5; done
      rediscover
      wait_mounted 40 || die "the volume never mounted; check: /usr/bin/log show --last 5m --predicate 'subsystem == \"dev.h3ct0r.ext4\"' --info"
    fi
  fi
  MP="$(vol_mp)"
  # Nothing inhibits writes any more; read-only here means the probe demoted
  # the volume (or the media is), and a pull test of a read-only mount
  # measures nothing.
  vol_ro && die "mounted read-only; investigate before pulling (see the driver log)"
  echo "  mounted read-write at $MP"
  MOUNT_OK=rw

  mkdir -p "$MP/stress" || die "cannot write to $MP"
  writer "$MP/stress" "$RD" 2>/dev/null &
  WPID=$!
  sleep "$WARMUP"

  echo ""
  echo "  >>>>>>  PULL THE STICK NOW -- mid-write  <<<<<<"
  echo "  (ignore any 'disk not ejected properly' complaint)"
  while [ -e "/dev/$CUR" ]; do sleep 0.5; done
  kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
  DUR=0; [ -s "$RD/durable" ] && DUR=$(tail -1 "$RD/durable")
  echo "  pulled. $DUR batch(es) had been through sync before the pull."
  sleep 5

  rediscover

  # Let the driver do its own recovery: replay happens at mount.
  REMOUNT=no
  if wait_mounted 40; then
    REMOUNT=$(vol_ro && echo ro || echo rw)
    echo "  remounted ($REMOUNT) -- journal replay, if any, has run"
    sleep 2
  else
    echo "  did NOT remount within 40s -- recovery refused; autopsy will show why"
  fi
  /usr/bin/log show --last 4m --info --predicate 'subsystem == "dev.h3ct0r.ext4"' \
      --style compact > "$RD/oslog.txt" 2>/dev/null
  grep -iE 'recover|replay|journal|barrier' "$RD/oslog.txt" | tail -5 | sed 's/^/    | /'

  # The replay-fresh volume can refuse the first force unmount while journal
  # recovery and the mount-time sync are still churning; dd on the raw node
  # of a mounted volume then dies with nothing but "Resource busy". Insist,
  # and verify, before imaging.
  for i in $(seq 1 10); do
    vol_mounted || break
    diskutil unmountDisk force "/dev/$CUR" >/dev/null 2>&1
    sleep 3
  done
  vol_mounted && die "cannot unmount /dev/$CUR for the autopsy"
  [ -e "/dev/r$PART" ] || die "/dev/r$PART vanished before the autopsy; replug and rerun the round"

  echo "  autopsy: imaging /dev/r$PART ..."
  CORPSE="$RD/corpse.img"
  sudo -v
  if ! sudo dd if="/dev/r$PART" of="$CORPSE" bs=4194304 2>"$RD/dd-err.txt"; then
    grep -v records "$RD/dd-err.txt" | sed 's/^/    | /'
    die "dd failed"
  fi
  sudo chown "$(id -un)" "$CORPSE"

  # fn on the corpse: the state the driver's own recovery left behind.
  # fy on a clone: what a full repair still had to do, as a damage grade.
  e2fsck -fn "$CORPSE" > "$RD/fsck-fn.log" 2>&1; RCN=$?
  cp -c "$CORPSE" "$RD/work.img" 2>/dev/null || cp "$CORPSE" "$RD/work.img"
  e2fsck -fy "$RD/work.img" > "$RD/fsck-fy.log" 2>&1; RCY=$?
  echo "  e2fsck -fn: exit $RCN$( [ "$RCN" -ne 0 ] && echo " ($(grep -m1 -vE '^e2fsck|^Pass|^$' "$RD/fsck-fn.log" | cut -c1-60))" )"
  echo "  e2fsck -fy: exit $RCY (repairs a full fsck still wanted)"

  # Durability: every synced batch, bit for bit, from the repaired image.
  SHA_BAD=n/a
  if [ -s "$RD/manifest" ]; then
    rm -rf "$RD/rdump"; mkdir -p "$RD/rdump"
    debugfs -R "rdump /stress $RD/rdump" "$RD/work.img" >/dev/null 2>&1
    if [ -d "$RD/rdump/stress" ]; then
      (cd "$RD/rdump/stress" && shasum -a 256 -c "$RD/manifest" 2>/dev/null) \
        | grep ': FAILED' > "$RD/durability-failures.txt"
      SHA_BAD=$(wc -l < "$RD/durability-failures.txt" | tr -d ' ')
    else
      cp "$RD/manifest" "$RD/durability-failures.txt"   # nothing survived at all
      SHA_BAD=$(wc -l < "$RD/manifest" | tr -d ' ')
    fi
    echo "  durability: $SHA_BAD of $(wc -l < "$RD/manifest" | tr -d ' ') synced files missing or wrong"
    if [ "$SHA_BAD" != 0 ]; then
      # Which batches: a loss in the last batch or two is the advisory
      # sync(2) window at the pull boundary; a loss in an OLD batch would be
      # a real durability hole and needs to be seen by name.
      sed 's/^/    | /' "$RD/durability-failures.txt" | head -8
      echo "    (last batch through sync before the pull: $DUR)"
    fi
  else
    echo "  durability: no batch completed a sync before the pull (n/a)"
  fi
  rm -rf "$RD/rdump" "$RD/work.img"
  [ "$RCN" -eq 0 ] && [ "${KEEP_CORPSE:-0}" != 1 ] && rm -f "$CORPSE"

  echo -e "$r\t$MOUNT_OK\t$REMOUNT\t$RCN\t$RCY\t$DUR\t$SHA_BAD" >> "$SUMMARY"

  if [ "$REMOUNT" != no ] && [ "$RCN" -eq 0 ]; then
    ok "round $r: recovered to an e2fsck-clean filesystem"
  else
    bad "round $r: remount=$REMOUNT, e2fsck -fn exit $RCN -- see $RD/"
  fi
  [ "$SHA_BAD" != n/a ] && [ "$SHA_BAD" != 0 ] \
    && bad "round $r: $SHA_BAD synced file(s) lost or corrupt"
done

# -------------------------------------------------------------------- report

echo ""
echo "================ $ROUNDS pull round(s) ================"
column -t -s $'\t' "$SUMMARY" | sed 's/^/  /'
echo ""
echo "  fsck_fn: 0 = the driver's recovery left nothing for e2fsck to fix"
echo "  fsck_fy: 0/1 = none/minor repairs on a clone; >=4 = real damage"
echo "  results in $OUT/"

finish
