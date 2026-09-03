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

exec make --no-print-directory CONFIG=fuzz FUZZ_CC="$FUZZ_CC" build/bin/ext4_fuzz
