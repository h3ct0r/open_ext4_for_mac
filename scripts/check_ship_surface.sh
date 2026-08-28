#!/usr/bin/env bash
# What is in the shipping core, and what must not be.
#
# The appex links build/lib/<config>/libext4core.a. The audit found things in
# it that have no business shipping: a getenv the extension never uses (a
# journal-barrier kill switch, since removed) and test-only exports that
# disable recovery on a live mount. This asserts they are gone -- from the
# SHIP library's shim objects specifically, not the test library, which is
# allowed to have them.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-release}"
LIB="$ROOT/build/lib/$CONFIG/libext4core.a"

fail=0
note() { echo "  ship-surface: $*"; }

if [ ! -f "$LIB" ]; then
  echo "ship-surface: $LIB not built; run 'make core' first"
  exit 1
fi

# nm over the archive: symbols the shipping core defines or references.
syms=$(nm "$LIB" 2>/dev/null)

# 1. No getenv anywhere in the shipping core. The tool reads the environment;
#    the library must not.
if grep -qE '(^| )U _?getenv$' <<<"$syms"; then
  note "FAIL the shipping core references getenv -- it must read no environment"
  fail=1
else
  note "ok   the shipping core references no getenv"
fi

# 2. The test-only orphan hooks must be absent from the shipping symbol table.
for sym in ext4b_set_orphan_cleanup ext4b_orphan_head; do
  if grep -qE "T _?$sym\$" <<<"$syms"; then
    note "FAIL the shipping core exports the test hook $sym"
    fail=1
  else
    note "ok   the shipping core does not export $sym"
  fi
done

# 3. No trace of the removed/relocated env-var names as string literals.
for s in EXT4B_TXN_BATCH EXT4B_NO_JOURNAL_BARRIER; do
  # Capture first: a present string would make `strings | grep -q` exit early,
  # SIGPIPE the producer, and pipefail would flip the result -- reporting the
  # string absent when it is there, the exact failure this check exists to catch.
  libstrings=$(strings "$LIB" 2>/dev/null)
  if grep -q "$s" <<<"$libstrings"; then
    note "FAIL the shipping core still contains the string \"$s\""
    fail=1
  else
    note "ok   the shipping core contains no \"$s\""
  fi
done

# Sanity: the TEST library SHOULD have the hooks -- proves the split works and
# we did not just delete the tool's interface.
TESTLIB="$ROOT/build/lib/$CONFIG/libext4core-test.a"
if [ -f "$TESTLIB" ]; then
  # Capture first: `nm | grep -q` trips the pipefail+SIGPIPE trap (grep exits
  # on the match, nm dies with SIGPIPE, the pipeline reports failure).
  testsyms=$(nm "$TESTLIB" 2>/dev/null)
  if grep -qE 'T _?ext4b_orphan_head$' <<<"$testsyms"; then
    note "ok   the test library still provides the orphan hooks"
  else
    note "FAIL the test library lost the orphan hooks -- the tool cannot build"
    fail=1
  fi
fi

echo ""
[ "$fail" -eq 0 ] && echo "ship surface is clean" || echo "SHIP SURFACE HAS LEAKS"
exit "$fail"
