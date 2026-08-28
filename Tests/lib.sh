# Shared plumbing for test suites. Source it:
#
#     ROOT="$(cd "$(dirname "$0")/.." && pwd)"
#     . "$ROOT/Tests/lib.sh"
#
# New suites use this; existing suites carry their own copies and migrate
# when they are next touched for another reason -- rewriting the safety net
# for tidiness is how safety nets get holes.
#
# Provides: PASS/FAIL counters, ok/bad, finish, the e2fsprogs PATH, and the
# Docker image names.

export PATH="/opt/homebrew/opt/e2fsprogs/sbin:/opt/homebrew/opt/e2fsprogs/bin:$PATH"

# Linux oracle images. One place, because three different values had crept
# into eight scripts.
DOCKER_LINUX_IMAGE="${DOCKER_LINUX_IMAGE:-debian:stable-slim}"
DOCKER_LUKS_IMAGE="${DOCKER_LUKS_IMAGE:-ext4luks:cryptsetup-attr}"

PASS=0
FAIL=0

# `bad` must not return nonzero: under `set -e` (or a && chain) a failing
# assertion would otherwise abort the suite at the first red instead of
# counting it.
ok()  { PASS=$((PASS+1)); echo "  ok    $*"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $*"; shift; [ $# -gt 0 ] && echo "        $*"; return 0; }

# Print the tally and exit nonzero on any failure.
finish() {
  echo ""
  echo "passed: $PASS failed: $FAIL"
  [ "$FAIL" -eq 0 ]
}
