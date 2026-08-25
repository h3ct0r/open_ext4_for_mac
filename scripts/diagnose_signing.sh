#!/usr/bin/env bash
# Signing diagnostic. Run this in Terminal.app (not over SSH), so the keychain
# can prompt if it needs to.
#
#   bash scripts/diagnose_signing.sh "Developer ID Application: Your Name (TEAMID)"
ID="${1:?usage: diagnose_signing.sh \"Developer ID Application: Name (TEAM)\"}"

echo "== 1. identity =="
security find-identity -v -p codesigning | grep -F "$ID" || echo "  NOT FOUND"

echo
echo "== 2. chain, as the trust system evaluates it =="
security find-certificate -c "${ID%% (*}" -p > /tmp/_leaf.pem 2>/dev/null
security verify-cert -c /tmp/_leaf.pem -p codeSign 2>&1 | tail -2

echo
echo "== 3. sign a throwaway binary =="
cp /bin/echo /tmp/_signtest
codesign --force --timestamp --options runtime --sign "$ID" /tmp/_signtest
echo "   exit status: $?"

echo
echo "== 4. what actually landed =="
codesign -dv --verbose=2 /tmp/_signtest 2>&1 | grep -E "Signature|Authority|TeamIdentifier"

echo
echo "== 5. verdict =="
if codesign -dv --verbose=2 /tmp/_signtest 2>&1 | grep -q "Authority=Developer ID Application"; then
  echo "   SIGNING WORKS — the chain warning, if any, is cosmetic."
else
  echo "   SIGNING FAILED — nothing usable was applied."
fi
rm -f /tmp/_signtest /tmp/_leaf.pem
