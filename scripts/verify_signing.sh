#!/usr/bin/env bash
# Does each signed binary actually have the entitlements it claims?
#
# codesign --verify checks that a signature is intact. It does not check that
# the entitlements inside it are *authorised*, and that failure is invisible:
# a Developer ID binary claiming a restricted entitlement no profile grants is
# killed by AMFI the instant it launches -- "Killed: 9", no crash report,
# nothing in the log, no hint that the entitlement is the cause. It cost an
# hour once. This turns it into a build-time error.
#
# The rules, in the order they bite:
#
#   1. a restricted entitlement needs an embedded provisioning profile
#   2. the profile has to actually grant it (wildcards count)
#   3. com.apple.application-identifier has to match the profile's, or the
#      system cannot pair the two and treats the profile as absent
#
# Usage: verify_signing.sh <App.app>
set -uo pipefail

APP="${1:?usage: verify_signing.sh <App.app>}"
FAIL=0

# Entitlements that mean nothing without a profile to authorise them. Anything
# not listed here is free for a Developer ID binary to claim.
RESTRICTED='com.apple.developer.fskit.fsmodule
com.apple.developer.fskit.mount
keychain-access-groups
com.apple.security.application-groups
com.apple.application-identifier'

check_one() {  # check_one <bundle> <label>
  local bundle="$1" label="$2"
  local profile="$bundle/Contents/embedded.provisionprofile"

  local claimed
  claimed=$(codesign -d --entitlements - --xml "$bundle" 2>/dev/null \
            | plutil -convert xml1 -o - - 2>/dev/null) || claimed=""
  if [ -z "$claimed" ]; then
    echo "  $label: no entitlements"
    return 0
  fi

  local granted=""
  if [ -f "$profile" ]; then
    granted=$(security cms -D -i "$profile" 2>/dev/null \
              | plutil -extract Entitlements xml1 -o - - 2>/dev/null) || granted=""
  fi

  CLAIMED="$claimed" GRANTED="$granted" RESTRICTED="$RESTRICTED" LABEL="$label" \
  python3 - <<'PY'
import os, plistlib, sys

label      = os.environ["LABEL"]
claimed    = plistlib.loads(os.environ["CLAIMED"].encode())
granted    = plistlib.loads(os.environ["GRANTED"].encode()) if os.environ["GRANTED"] else None
restricted = set(os.environ["RESTRICTED"].split())

problems = []

def authorised(key, value):
    """Is `value` covered by what the profile grants for `key`?"""
    if granted is None or key not in granted:
        return False
    allowed = granted[key]
    if isinstance(allowed, list):
        wanted = value if isinstance(value, list) else [value]
        for item in wanted:
            if not any(a == item or (a.endswith("*") and str(item).startswith(a[:-1]))
                       for a in allowed if isinstance(a, str)):
                return False
        return True
    return allowed == value

for key, value in sorted(claimed.items()):
    if key not in restricted:
        continue
    if granted is None:
        problems.append(f"claims {key} but the bundle embeds no provisioning profile")
    elif not authorised(key, value):
        problems.append(f"claims {key} = {value!r}, which the profile does not grant")

# The profile is matched to the binary by application-identifier. Without it,
# or with the wrong one, every restricted entitlement above is unauthorised
# however correct the profile is.
if granted is not None:
    mine  = claimed.get("com.apple.application-identifier")
    theirs = granted.get("com.apple.application-identifier")
    if mine is None:
        problems.append("embeds a profile but claims no com.apple.application-identifier, "
                        "so the two cannot be paired")
    elif theirs is not None and mine != theirs:
        problems.append(f"application-identifier {mine!r} does not match the profile's {theirs!r}")

if problems:
    print(f"  {label}: NOT OK")
    for p in problems:
        print(f"      {p}")
    sys.exit(1)

print(f"  {label}: entitlements are authorised by its profile"
      if granted is not None else f"  {label}: no restricted entitlements")
PY
  return $?
}

echo "verifying entitlements against provisioning profiles..."
for bundle in "$APP/Contents/Extensions/"*.appex; do
  [ -d "$bundle" ] || continue
  check_one "$bundle" "$(basename "$bundle")" || FAIL=1
done
check_one "$APP" "$(basename "$APP")" || FAIL=1

if [ "$FAIL" -ne 0 ]; then
  echo
  echo "  A binary that claims an entitlement it cannot prove does not fail loudly:"
  echo "  AMFI kills it at launch with no crash report and nothing in the log."
  echo "  See docs/SIGNING.md."
  exit 1
fi
