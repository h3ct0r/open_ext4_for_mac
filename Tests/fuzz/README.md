# Fuzzing

Two instruments, one corpus, one set of strategies.

| | `make fuzz` (A0–A4, A7) | `make test-fuzz` (A5) |
|---|---|---|
| what it is | an in-process libFuzzer target | a mutation campaign over `ext4dump` |
| needs | Homebrew LLVM (`libclang_rt.fuzzer_osx.a`) | python3 and e2fsprogs |
| speed | thousands of inputs a second, coverage-guided | hundreds of mutants a minute, blind |
| runs in | a soak, a nightly, by hand | **`make validate`, every round** |
| finds | everything the corpus can reach | crashes, hangs, writes; memory unsafety only under `make test-asan` |

The second exists because validation must not depend on a second compiler.
The first exists because the second is thirty times slower and has no idea
which inputs are interesting.

## The pieces

    tools/fuzz/ext4_fuzz.c        the harness: an in-memory device through
                                  the same seam ext4dump uses, a read-only
                                  walk, a read-write script, and the
                                  global-state self-test
    tools/fuzz/ext4_csum.{c,h}    ext4's checksums, computed outside the
                                  driver, in C
    tools/fuzz/ext4_mutator.c     eleven structure-aware strategies
    tools/fuzz/ext4_stampcheck.c  does the stamper agree with mke2fs?
    tools/fuzz/ext4.dict          the tokens a byte flip needs to land on
    tools/fuzz/mutweights.json    the weights BOTH mutators read

    Tests/fuzz/make_seeds.sh      fourteen small volumes, generated
    Tests/fuzz/ext4_csum.py       the same checksums, in Python
    Tests/fuzz/mutate_image.py    the same eleven strategies, in Python
    Tests/run_fuzz_tests.sh       the campaign that runs in validation
    Tests/run_fuzz_regressions_tests.sh   every past finding, run again
    Tests/fixtures/hostile/       the past findings themselves

    scripts/fuzz_build.sh         build the harness, or exit 77 saying why
    scripts/fuzz_coverage.sh      the gate: is the campaign still reaching
                                  the code it was aimed at?
    scripts/red_first_patch.sh    prove a patch by taking it away

Durable state lives in `.fuzz/`, deliberately outside `build/`: a validation
round begins with `make clean`, and a corpus a round deletes is a corpus that
never grows. `.soak/` exists for the same reason.

## Why the checksums are implemented twice, and never shared with the driver

`metadata_csum` gates almost everything. An edit to an inode, a descriptor or
a directory block that does not re-stamp its checksum never reaches the parser
it was aimed at, because the driver refuses the structure first. A campaign
without a stamper spends its whole budget proving the checksum code works.

So the mutator re-stamps — and that makes the stamper an oracle as well as a
tool. It must not share code with `Core/shim` or `Core/lwext4`, because a
shared bug would cancel out in both roles. `Tests/bitmap_csum.py` takes the
same position for the same reason.

The stamper is checked both ways round, in both languages, on every run:
recompute every checksum in a pristine `mke2fs` image and require agreement,
then rebuild with the wrong polynomial and require disagreement everywhere. A
checker that passes with the wrong polynomial is not checking anything.

Five per cent of edits deliberately leave the superblock checksum wrong. The
gate is code too.

## The triage loop

1. `make fuzz` (or `make fuzz-rw`) until something lands in `.fuzz/crashes/`.
2. `make fuzz-repro FILE=.fuzz/crashes/crash-...` — symbolised, both modes.
3. Minimize. **Not** with `-minimize_crash=1`: libFuzzer's random shrink gets
   nowhere on a structured multi-megabyte image ("failed to minimize beyond
   3145728 bytes"). Delta-debug the diff against the seed instead — that took
   one finding from 4996 bytes in 1664 runs to **four bytes in one**.
4. Confirm with the release `ext4dump`, picking the verb from the stack.
5. Add a row to `Tests/fixtures/hostile/MANIFEST` with the gzipped image and a
   JSON recipe naming the bytes. A fixture nobody can explain is a fixture
   nobody will dare to change.
6. Fix it — in the shim, or in lwext4 as `patches/lwext4/00NN-*.patch` with a
   README row and `make check-patches` green.
7. `bash scripts/red_first_patch.sh 00NN [--asan]`. It reverses the patch,
   rebuilds, requires the suite to FAIL, then repatches and requires it to
   PASS. A patch that passes both ways is a patch whose test does not test it.
8. Commit the fixture, the patch and the row together.

## Two traps this cost time to learn

**The patch stamp puts your revert back.** `build/.lwext4-patched` is a
prerequisite of every object file and depends on the patch *files*. A freshly
written patch is newer than the stamp, so the stamp rule re-runs — and that
rule re-applies every patch that still applies, including the one you just
reverted. `touch build/.lwext4-patched` after reverting.
`scripts/red_first_patch.sh` does it, and then verifies the revert survived
the build rather than trusting it.

**A failed red-first leaves a poisoned binary.** `build/bin/ext4dump` is one
path whatever the CONFIG, so an early exit can leave it built from the
reverted source while the submodule says otherwise. The next suite anyone runs
then reports the fixed bug as live. The script's EXIT trap repatches *and*
relinks.

## What each instrument cannot see

`make test-fuzz` against a release build cannot see memory unsafety: a
heap-buffer-overflow that reads past a buffer returns the wrong answer and
exits 0. Measured — 200 superblock-targeted mutants give zero findings against
release and five heap-buffer-overflows against the sanitizer build. Both
suites print which build they are judging, so a green run is never read as the
wider claim.

`make fuzz` cannot run in `make validate`, because Apple's Command Line Tools
clang ships no libFuzzer runtime. `scripts/fuzz_build.sh` exits 77 rather than
failing.

Neither can see anything a mounted FSKit volume does. That is what
`run_mount_crash_tests.sh`, `run_kill_recovery_tests.sh` and the pull suite
are for, and none of them can run on a CI runner.
