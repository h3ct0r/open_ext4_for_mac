#!/usr/bin/env bash
# Does the Setup Assistant know what is missing, and can the app prove a mount?
#
# The first-run experience is a checklist -- is the app in /Applications, is
# the extension registered, is it approved, does it start at login, may it
# notify, is Disk Utility integration in place -- and a demonstration: a
# bundled sample ext4 volume that mounts through the same path a plugged-in
# disk takes. Both halves are driven here without a window: `Ext4Mac setup
# --check` evaluates the checklist from EXPLICIT inputs (`--given`), so every
# state the wizard can show is produced on demand rather than by changing the
# machine; `Ext4Mac selftest --mount` mounts and ejects the sample and must
# leave nothing attached.
#
# Runs unattended. Exit 77 (SKIP) without the app binary; the mount cells
# skip themselves when the extension is not installed and approved.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/Tests/lib.sh"

APP="$ROOT/build/Ext4Mac.app/Contents/MacOS/Ext4Mac"
RES="$ROOT/build/Ext4Mac.app/Contents/Resources"
DUMP="$ROOT/build/bin/ext4dump"
WORK="$ROOT/build/setup"
rm -rf "$WORK"; mkdir -p "$WORK"

if [ ! -x "$APP" ]; then
  echo "  (building the app for the checklist cells)"
  make -C "$ROOT" app >/dev/null 2>&1
fi
if [ ! -x "$APP" ]; then
  echo "build/Ext4Mac.app is not built (macOS only; needs swiftc)"
  echo "SKIPPED"
  exit 77
fi

echo "########## SETUP ASSISTANT ##########"
echo ""

# A checklist from explicit facts. Every key the probe would read off the
# machine can be given instead, so the cells never depend on this Mac's state.
GREEN="--given bundle=/Applications/Ext4Mac.app registered=1 enabled=1 login=1 notify=authorized diskutil=1 other=0 sample=1"

check() {  # check <args...> -> writes $WORK/check.txt; returns the verb's status
  "$APP" setup --check "$@" > "$WORK/check.txt" 2>&1
}
# One line per check: "<state> <id> <detail>". State first, so a cell can ask
# for "ok install" without caring how the detail is worded.
line() { grep -E "^\s*$1\s+$2\b" "$WORK/check.txt" >/dev/null; }

echo "the checklist from explicit inputs"
echo ""

check $GREEN; CHECK_RC=$?
if [ "$CHECK_RC" = 0 ] && line ok install && line ok approve && line ok loginItem \
   && line ok notifications && line ok diskUtility && line ok sample; then
  ok "everything given as ready reads as ok, and the verb exits 0"
else
  bad "everything given as ready reads as ok, and the verb exits 0" "rc=$CHECK_RC: $(head -3 "$WORK/check.txt" | tr '\n' '|')"
fi

# The gap the old alerts had: registered-but-off and absent are different
# situations with different next steps, and got the same sentence.
check $GREEN registered=1 enabled=0; CHECK_RC=$?
if [ "$CHECK_RC" = 1 ] && line missing approve && grep -qi "registered, not approved" "$WORK/check.txt"; then
  ok "registered but not approved is named as such, and the verb exits 1"
else
  bad "registered but not approved is named as such, and the verb exits 1" "rc=$CHECK_RC: $(grep -i approve "$WORK/check.txt" | head -1)"
fi
check $GREEN registered=0 enabled=0; CHECK_RC=$?
if [ "$CHECK_RC" = 1 ] && line missing approve && grep -qi "not registered" "$WORK/check.txt"; then
  ok "not registered at all is named as such -- it is absent from Settings, not off"
else
  bad "not registered at all is named as such" "rc=$CHECK_RC: $(grep -i approve "$WORK/check.txt" | head -1)"
fi

# A skip is a decision, not a failure.
check $GREEN login=0 --skipped loginItem; CHECK_RC=$?
if [ "$CHECK_RC" = 0 ] && line skipped loginItem; then
  ok "a skipped login item reads as skipped and does not fail the checklist"
else
  bad "a skipped login item reads as skipped and does not fail the checklist" "rc=$CHECK_RC: $(grep -i login "$WORK/check.txt" | head -1)"
fi
check $GREEN login=0; CHECK_RC=$?
[ "$CHECK_RC" = 1 ] && line missing loginItem \
  && ok "an unskipped, unset login item is missing" \
  || bad "an unskipped, unset login item is missing" "rc=$CHECK_RC"

check $GREEN bundle=/Users/somebody/Downloads/Ext4Mac.app; CHECK_RC=$?
if [ "$CHECK_RC" = 1 ] && line missing install && grep -q "/Applications" "$WORK/check.txt"; then
  ok "an app run from Downloads is told to move to /Applications"
else
  bad "an app run from Downloads is told to move to /Applications" "rc=$CHECK_RC: $(grep -i install "$WORK/check.txt" | head -1)"
fi

check $GREEN other=1; CHECK_RC=$?
if [ "$CHECK_RC" = 0 ] && line warn otherDriver && grep -qi "paragon" "$WORK/check.txt"; then
  ok "another ext driver is a warning naming Paragon, not a failure"
else
  bad "another ext driver is a warning naming Paragon, not a failure" "rc=$CHECK_RC: $(grep -i other "$WORK/check.txt" | head -1)"
fi

check $GREEN notify=denied; CHECK_RC=$?
[ "$CHECK_RC" = 1 ] && line missing notifications \
  && ok "denied notifications are missing (the volume-event channel is silent without them)" \
  || bad "denied notifications are missing" "rc=$CHECK_RC"

# The wizard's own view of the same data.
"$APP" setup --check --json $GREEN > "$WORK/check.json" 2>/dev/null; rc=$?
if [ "$rc" = 0 ] && python3 - "$WORK/check.json" <<'PY'
import json, sys
rows = json.load(open(sys.argv[1]))
ids = {r["id"] for r in rows}
need = {"install", "approve", "loginItem", "notifications", "diskUtility", "sample", "otherDriver"}
assert need <= ids, ids
assert all(set(r) >= {"id", "state", "detail"} for r in rows)
PY
then ok "--json is a list of {id, state, detail} covering every check"
else bad "--json is a list of {id, state, detail} covering every check" "rc=$rc: $(head -c 120 "$WORK/check.json")"; fi

"$APP" setup --check $GREEN colour=blue > "$WORK/check.txt" 2>&1; rc=$?
[ "$rc" = 2 ] && grep -qi "usage" "$WORK/check.txt" \
  && ok "an unknown --given key is a usage error (rc=2)" \
  || bad "an unknown --given key is a usage error (rc=2)" "rc=$rc"

# Without --given the checklist reads this machine. Only the shape is asserted.
"$APP" setup --check > "$WORK/check.txt" 2>&1; rc=$?
if { [ "$rc" = 0 ] || [ "$rc" = 1 ]; } && grep -qE "\bapprove\b" "$WORK/check.txt"; then
  ok "with no inputs the checklist reads the machine (rc=$rc)"
else
  bad "with no inputs the checklist reads the machine" "rc=$rc: $(head -2 "$WORK/check.txt" | tr '\n' '|')"
fi

# ------------------------------------------------------------ artefacts --
echo ""
echo "what the bundle carries"
echo ""

SAMPLE="$RES/Ext4Mac-Sample.img"
if [ -f "$SAMPLE" ]; then
  ok "the sample image is in Contents/Resources"
  label=$("$DUMP" "$SAMPLE" probe 2>/dev/null | sed -n 's/^label: *//p')
  [ "$label" = "Ext4Mac Sample" ] && ok "and is labelled 'Ext4Mac Sample'" \
                                  || bad "and is labelled 'Ext4Mac Sample'" "label: '$label'"
  if "$DUMP" "$SAMPLE" cat /README.txt 2>/dev/null | cmp -s - "$ROOT/Packaging/sample/README.txt"; then
    ok "and holds the README the package ships"
  else
    bad "and holds the README the package ships"
  fi
  "$DUMP" "$SAMPLE" check >/dev/null 2>&1 && ok "and passes ext4dump check" || bad "and passes ext4dump check"
else
  bad "the sample image is in Contents/Resources" "no $SAMPLE"
  bad "and is labelled 'Ext4Mac Sample'" "no image"
  bad "and holds the README the package ships" "no image"
  bad "and passes ext4dump check" "no image"
fi
[ -f "$RES/ext4.fs/Contents/Info.plist" ] && ok "the Disk Utility bundle is in Contents/Resources" \
                                            || bad "the Disk Utility bundle is in Contents/Resources"

# ---------------------------------------------------------- the mount --
echo ""
echo "the sample volume, mounted and ejected"
echo ""

# Through the INSTALLED app, the way the mounted cells of run_events_tests.sh
# do: only a signed bundle in /Applications may ask FSKit anything, and only
# the extension inside it is the one macOS approved. check_install_freshness
# is what stops this from testing yesterday's binary.
INSTALLED="/Applications/Ext4Mac.app/Contents/MacOS/Ext4Mac"

if ! bash "$ROOT/scripts/check_extension.sh" >/dev/null 2>&1; then
  echo "  (mount cells skipped: the FSKit extension is not installed and enabled)"
else
  bash "$ROOT/scripts/check_install_freshness.sh" || exit 1
  before=$(hdiutil info 2>/dev/null | grep -c "CRawDiskImage")
  run_deadline 120 "$INSTALLED" selftest --mount > "$WORK/mount.txt" 2>&1; rc=$?
  after=$(hdiutil info 2>/dev/null | grep -c "CRawDiskImage")
  if [ "$rc" = 0 ] && grep -q "README" "$WORK/mount.txt"; then
    ok "selftest --mount mounts the sample, reads its README, and ejects it (rc=0)"
  elif [ "$rc" = 77 ]; then
    bad "selftest --mount mounts the sample" "it skipped although the extension answers: $(tail -1 "$WORK/mount.txt")"
  else
    bad "selftest --mount mounts the sample, reads its README, and ejects it" "rc=$rc: $(grep -iE 'error|fail|unknown' "$WORK/mount.txt" | head -1)"
  fi
  if [ "$before" = "$after" ] && ! hdiutil info 2>/dev/null | grep -q "ext4mac-sample"; then
    ok "and leaves no disk image attached ($before before, $after after)"
  else
    bad "and leaves no disk image attached" "$before before, $after after"
  fi
fi

echo ""
echo "─────────────────────────────────"
finish
