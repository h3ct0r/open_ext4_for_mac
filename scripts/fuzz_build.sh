#!/usr/bin/env bash
# Build the in-process libFuzzer target, or say plainly why this machine
# cannot, and exit 77.
#
# 77 is the project's SKIP code: run_full_validation.sh records it as SKIP
# rather than PASS, and a CI job can branch on it. It has to come from a
# script rather than from a Makefile recipe, because make collapses any
# recipe failure into its own exit 2 -- so `make fuzz-build` on a machine
# without the runtime prints "Error 77" and exits 2, while this script exits
# 77. Anything that needs to *decide* calls this; `make fuzz-build` is the
# convenience wrapper for a human at a terminal.
#
# The guard is on the runtime file, not on a version string. Homebrew's LLVM
# moves; what matters is whether libclang_rt.fuzzer_osx.a sits beside the
# compiler's own runtime. Apple's Command Line Tools clang accepts
# -fsanitize=fuzzer-no-link and the coverage flags, but ships no runtime to
# link against, so the failure it gives is a linker error about missing
# symbols rather than anything that names the cause.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

FUZZ_CC="${FUZZ_CC:-/opt/homebrew/opt/llvm/bin/clang}"

if ! command -v "$FUZZ_CC" >/dev/null 2>&1 && [ ! -x "$FUZZ_CC" ]; then
  echo "fuzz: no such compiler: $FUZZ_CC"
  echo "      brew install llvm, or set FUZZ_CC=/path/to/clang"
  exit 77
fi

rt="$("$FUZZ_CC" -print-libgcc-file-name 2>/dev/null)"
if [ -z "$rt" ] || [ ! -f "$(dirname "$rt")/libclang_rt.fuzzer_osx.a" ]; then
  echo "fuzz: $FUZZ_CC has no libclang_rt.fuzzer_osx.a next to"
  echo "      ${rt:-its runtime}, so -fsanitize=fuzzer cannot link."
  echo "      Apple's Command Line Tools clang does not ship it."
  echo "      Install one that does:  brew install llvm"
  echo "      Then:  make fuzz-build   (or set FUZZ_CC=/path/to/clang)"
  exit 77
fi

# Object files do not depend on the flags that produced them.
#
# This is stated in the Makefile about EXTRA_CFLAGS and it is just as true of
# the fuzz configuration's OPT. Adding -fno-sanitize-recover=undefined here
# changed nothing at all until build/obj/fuzz was removed by hand: the
# campaign kept printing "runtime error:" and carrying on, exactly as it had
# before, and the flag looked like it did not work. Half an hour, and the
# wrong conclusion was one step away.
#
# So record the flags that built the tree and wipe the configuration's objects
# when they change. Only build/obj/fuzz and build/lib/fuzz -- the release and
# debug trees are not ours to invalidate.
STAMP="build/.fuzz-flags"
WANT="$(make --no-print-directory CONFIG=fuzz FUZZ_CC="$FUZZ_CC" print-fuzz-flags 2>/dev/null)"
if [ -n "$WANT" ]; then
  if [ ! -f "$STAMP" ] || [ "$(cat "$STAMP" 2>/dev/null)" != "$WANT" ]; then
    [ -f "$STAMP" ] && echo "fuzz: build flags changed; rebuilding the fuzz objects"
    rm -rf build/obj/fuzz build/lib/fuzz build/bin/ext4_fuzz
    mkdir -p build
    printf '%s' "$WANT" > "$STAMP"
  fi
fi

exec make --no-print-directory CONFIG=fuzz FUZZ_CC="$FUZZ_CC" build/bin/ext4_fuzz
