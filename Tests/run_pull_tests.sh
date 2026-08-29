#!/usr/bin/env bash
# Physical pull test -- a hardware verdict on the write-barrier daemon.
#
# Same build, same journal, same transaction batching; one variable:
#
#   ARM=barrier   marker off, daemon loaded     -> rw, every commit barriered
#   ARM=naked     marker on,  daemon booted out -> rw, no barrier at all
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
#                 macOS reports success without proof, so read it comparatively
#                 across the two arms rather than as an absolute.
#
# The barrier arm has a pass bar. The naked arm is the measurement it is
# compared against -- history says 5/5 sticks damaged without a barrier, clean
# with one, but the core has changed since (batching), hence this suite.
#
# Usage (interactive: the pulls need hands):
#
#   DEVICE=diskN ARM=barrier bash Tests/run_pull_tests.sh
#   DEVICE=diskN ARM=naked   bash Tests/run_pull_tests.sh
#
#   ROUNDS=3 (default)   EXT4_SIZE=2g (default; must fit the stick)
#   KEEP_CORPSE=1        keep the dd image even when the round is clean
#   HARSH=1              sustained 1-2 MB writes with NO sync fences: the
#                        widest reorder window a drive cache gets. Durability
#                        is n/a (nothing is ever claimed durable); consistency
#                        is the whole measurement. Pull under full load.
#
# This ERASES the stick, repeatedly -- use one you can lose. Repeated hot
# pulls can also wedge DiskArbitration until a reboot; run the barrier arm
# first while the machine is fresh, and expect to reboot after the naked arm.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/Tests/lib.sh"

DEVICE="${DEVICE:-}"
ARM="${ARM:-}"
ROUNDS="${ROUNDS:-3}"
EXT4_SIZE="${EXT4_SIZE:-2g}"
LABEL="EXT4PULL"
WARMUP="${WARMUP:-10}"

APP_BIN="/Applications/Ext4Mac.app/Contents/MacOS/Ext4Mac"
BARRIER_LABEL="dev.h3ct0r.ext4mac.barrier"
BARRIER_PLIST="/Library/LaunchDaemons/$BARRIER_LABEL.plist"
# One results directory per drive, so a four-drive sweep does not overwrite
# itself: TAG defaults to the media name, slugged.
TAG="${TAG:-$(diskutil info "${DEVICE%s[0-9]*}" 2>/dev/null \
      | sed -n 's|.*Device / Media Name: *||p' | head -1 \
      | tr 'A-Z ' 'a-z-' | tr -cd 'a-z0-9-')}"
OUT="$ROOT/build/pulltest/${TAG:-unnamed}-$ARM"
[ "${HARSH:-0}" = 1 ] && OUT="$OUT-harsh"

die() { echo "error: $*" >&2; exit 1; }

# ------------------------------------------------------------- preconditions

[ -n "$DEVICE" ] || die "no device. Usage: DEVICE=diskN ARM=barrier|naked bash Tests/run_pull_tests.sh"
case "$ARM" in barrier|naked) ;; *) die "ARM must be 'barrier' or 'naked'" ;; esac
DEVICE="${DEVICE%s[0-9]*}"

command -v e2fsck  >/dev/null || die "e2fsck not on PATH (brew install e2fsprogs)"
command -v debugfs >/dev/null || die "debugfs not on PATH (brew install e2fsprogs)"
[ -x "$APP_BIN" ] || die "missing $APP_BIN (install the app)"
[ -d /Library/Filesystems/ext4.fs ] || die "missing /Library/Filesystems/ext4.fs (sudo make install-diskutil)"
diskutil info "$DEVICE" >/dev/null 2>&1 || die "$DEVICE is not a disk this machine knows about"

INFO=$(diskutil info "$DEVICE" 2>/dev/null)
case "$(sed -n 's/.*Removable Media: *//p' <<<"$INFO" | head -1)" in
  *emovable*) ;;
  *) die "$DEVICE does not report removable media; refusing" ;;
esac

if ! pluginkit -m -i dev.h3ct0r.ext4mac.Ext4FS 2>/dev/null | grep -q '^+'; then
  echo "warning: the extension does not look enabled (pluginkit shows no '+')."
  echo "         System Settings > General > Login Items & Extensions >"
  echo "         File System Extensions, or nothing below will mount."
fi

daemon_loaded() {
  launchctl print "system/$BARRIER_LABEL" >/dev/null 2>&1 && return 0
  sudo launchctl print "system/$BARRIER_LABEL" >/dev/null 2>&1
}

echo "about to run the $ARM arm: $ROUNDS round(s), erasing /dev/$DEVICE each time"
echo "    $(sed -n 's/.*Device \/ Media Name: */name  /p' <<<"$INFO" | head -1)"
echo "    $(sed -n 's/.*Disk Size: */size  /p' <<<"$INFO" | head -1)"
echo ""
printf "type ERASE to continue: "
read -r answer
[ "$answer" = "ERASE" ] || die "not confirmed"

sudo -v || die "needs sudo for format, dd, and launchctl"

# ---------------------------------------------------------------- arm setup

RESTORE_DAEMON=no
cleanup() {
  "$APP_BIN" removable-writes off >/dev/null 2>&1
  if [ "$RESTORE_DAEMON" = yes ]; then
    sudo launchctl bootstrap system "$BARRIER_PLIST" 2>/dev/null \
      && echo "restored: barrier daemon bootstrapped back"
  fi
}
trap cleanup EXIT

if [ "$ARM" = barrier ]; then
  "$APP_BIN" removable-writes off >/dev/null 2>&1
  daemon_loaded || die "barrier arm needs the daemon: sudo make install-barrier (and Full Disk Access for /Library/PrivilegedHelperTools/ext4barrierd)"
  # The caller check once shipped with API flags SecCodeCheckValidity refuses
  # (-67070), which silently refused every caller; only a physical stick
  # surfaced it. Refuse to measure through a daemon that cannot say yes.
  if ! /Library/PrivilegedHelperTools/ext4barrierd --selfcheck 2>/dev/null \
       | grep -q "selfcheck: ok"; then
    die "installed daemon fails --selfcheck (or predates it, which means the broken caller check): make sign && sudo make install-barrier"
  fi
else
  if daemon_loaded; then
    sudo launchctl bootout "system/$BARRIER_LABEL" || die "could not boot the daemon out"
    RESTORE_DAEMON=yes
    echo "daemon booted out for the naked arm (restored on exit)"
  fi
  "$APP_BIN" removable-writes on >/dev/null 2>&1
  "$APP_BIN" removable-writes | grep -q FORCED || die "could not set the removable-writes marker"
fi

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
  echo "================ $ARM round $r/$ROUNDS ================"

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
  if vol_ro; then
    [ "$ARM" = barrier ] && die "mounted read-only: the daemon did not confirm a barrier (FDA missing?). See the log."
    die "mounted read-only despite the marker; investigate before pulling"
  fi
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

  diskutil unmountDisk force "/dev/$CUR" >/dev/null 2>&1
  sleep 1

  echo "  autopsy: imaging /dev/r$PART ..."
  CORPSE="$RD/corpse.img"
  sudo dd if="/dev/r$PART" of="$CORPSE" bs=4194304 2>/dev/null || die "dd failed"
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

  if [ "$ARM" = barrier ]; then
    if [ "$REMOUNT" != no ] && [ "$RCN" -eq 0 ]; then
      ok "round $r: recovered to an e2fsck-clean filesystem"
    else
      bad "round $r: remount=$REMOUNT, e2fsck -fn exit $RCN -- see $RD/"
    fi
    [ "$SHA_BAD" != n/a ] && [ "$SHA_BAD" != 0 ] \
      && bad "round $r: $SHA_BAD synced file(s) lost or corrupt"
  else
    echo "  recorded (naked arm measures; it has no pass bar)"
  fi
done

# -------------------------------------------------------------------- report

echo ""
echo "================ $ARM arm: $ROUNDS round(s) ================"
column -t -s $'\t' "$SUMMARY" | sed 's/^/  /'
echo ""
echo "  fsck_fn: 0 = the driver's recovery left nothing for e2fsck to fix"
echo "  fsck_fy: 0/1 = none/minor repairs on a clone; >=4 = real damage"
echo "  results in $OUT/"

if [ "$ARM" = barrier ]; then
  finish
else
  echo ""
  echo "compare against the barrier arm's summary to reach the verdict."
  exit 0
fi
