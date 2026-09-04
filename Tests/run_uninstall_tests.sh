#!/usr/bin/env bash
# Does the uninstall name everything an install leaves behind?
#
# The destructive run is never exercised here -- it removes an application, a
# container of keys and a system bundle, and the machine this runs on has all
# three in use. The DRY RUN is what is checked: every artifact the install
# creates has to appear in a "would:" line, so an artifact added to the
# install and not to the uninstall is a red cell here rather than a leftover
# on somebody's disk.
#
# Red-first: a copy of the script with one step commented out must fail the
# same checks, and does so on every run.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/Tests/lib.sh"

SCRIPT="$ROOT/scripts/uninstall.sh"
WORK="$ROOT/build/uninstall"
rm -rf "$WORK"; mkdir -p "$WORK"

echo "########## UNINSTALL ##########"
echo ""

# Everything an install creates, as a substring the dry run must print.
EXPECTED=(
  "eject every ext2/3/4 volume"
  "login-item off"
  "forget --all --yes"
  "pluginkit -r"
  "remove /Applications/Ext4Mac.app"
  "Containers/dev.h3ct0r.ext4mac.Ext4FS"
  "Containers/dev.h3ct0r.ext4mac"
  "defaults delete dev.h3ct0r.ext4mac"
  "/Library/Filesystems/ext4.fs"
  "dev.h3ct0r.ext4mac.barrier.plist"
)

check_dry_run() {  # check_dry_run <script> <label>  -> prints missing count
  local script="$1" label="$2" missing=0
  DRY_RUN=1 bash "$script" > "$WORK/$label.out" 2>&1
  for want in "${EXPECTED[@]}"; do
    grep -qF -- "$want" "$WORK/$label.out" || missing=$((missing+1))
  done
  echo "$missing"
}

echo "the real script"
echo ""
if ! grep -q "^would" <(DRY_RUN=1 bash "$SCRIPT" 2>/dev/null); then
  bad "DRY_RUN=1 prints 'would:' lines" "$(head -3 "$WORK/real.out" 2>/dev/null)"
fi
missing=$(check_dry_run "$SCRIPT" real)
if [ "$missing" = "0" ]; then
  ok "the dry run names every one of ${#EXPECTED[@]} artifacts"
else
  bad "the dry run names every one of ${#EXPECTED[@]} artifacts" \
      "$missing missing: $(for w in "${EXPECTED[@]}"; do grep -qF -- "$w" "$WORK/real.out" || printf '%s; ' "$w"; done)"
fi

# It must refuse when told neither DRY_RUN nor FOR_REAL.
bash "$SCRIPT" >/dev/null 2>&1; rc=$?
[ "$rc" = "2" ] && ok "without DRY_RUN or EXT4_UNINSTALL_FOR_REAL it refuses (rc=2)" \
                || bad "without DRY_RUN or EXT4_UNINSTALL_FOR_REAL it refuses" "rc=$rc"

# The dry run must not have touched anything: the app is still there.
[ -d /Applications/Ext4Mac.app ] && ok "the dry run removed nothing (the app is still installed)" \
                                  || echo "  (no /Applications/Ext4Mac.app on this machine; the removed-nothing cell has nothing to check)"

echo ""
echo "the check has teeth"
echo ""
# Comment out the container step in a copy: the dry run then names one
# artifact fewer, and the check must say so.
sed 's|^step "remove the extension.s container|# &|' "$SCRIPT" > "$WORK/one-less.sh"
missing=$(check_dry_run "$WORK/one-less.sh" one-less)
[ "$missing" = "1" ] && ok "a step commented out is one artifact reported missing" \
                     || bad "a step commented out is reported missing" "missing=$missing"

echo ""
echo "─────────────────────────────────"
finish
