# Contributing

This driver writes to people's disks. The rules below exist so that a change
which looks right can be shown to be right, and so that a bug found once
stays found.

## Build and test

```bash
brew install e2fsprogs              # mke2fs, e2fsck, debugfs
make                                # Ext4Mac.app
make test                           # read + write suites, offline
make validate                       # everything; Docker for the Linux stages
make help                           # every target
```

One suite at a time: `make test-bounds`, `make test-crash`, `make test-luks`
and so on (`make help` lists them), or `bash Tests/run_<name>_tests.sh`
directly. No Apple account, signing or mounting is needed for any of it; the
mounted suites skip themselves (exit 77) when the extension is not installed
and approved.

## Three rules

1. **Every new test is shown to fail first.** Before a fix is believed, its
   test runs red against the unfixed code — the fix reverted, or a fault
   injected — and the red result is recorded in the commit message alongside
   the green. A test that has never failed has not demonstrated it tests
   anything. `scripts/red_first.sh --id NNNN [--suite <suite>] [--asan]`
   does this for any commit that changes `Core/`: it reverts the code in a
   throwaway worktree, keeps the tests, and requires red, then green.

2. **lwext4 changes are numbered, one per commit.** `Core/lwext4` is this
   project's fork ([FORK.md](Core/lwext4/FORK.md)), edited in place like any
   other source. A change to it is one commit, subject
   `lwext4 NNNN: <what>` with the trailer `Lwext4-Change: NNNN`, and a row in
   [docs/lwext4-changes.md](docs/lwext4-changes.md) saying what and why, added
   in the same commit. IDs are never reused. Changes that alter no behaviour
   are `lwext4 vendor: <what>`. Do not reformat upstream code.

3. **The shipping core reads no environment.** Test-only hooks go behind
   `EXT4B_TEST_HOOKS`; `getenv` is allowed only under `tools/`.
   `scripts/check_ship_surface.sh` enforces it and runs in CI.

## Adding a suite

A `.PHONY` entry and a `test-<name>: tools` target in the Makefile, a `stage`
line in `scripts/run_full_validation.sh` (and `scripts/ci_offline.sh` if it
needs no extension), exit 77 for "cannot run here". Nothing under `build/`
survives a validation round; durable state goes in `.fuzz/` or `.soak/`.

## Fuzz findings

A crash from `make fuzz`, the nightly, or the mutation campaign becomes a
hostile fixture: minimise it (`make fuzz-minimize FILE=…`), craft or gzip the
image into `Tests/fixtures/hostile/00NN-<slug>.img.gz` with a `.json`
describing the edit and the symptom, add a `MANIFEST` row, and land it with
its fix in one commit — red first. `Tests/fuzz/README.md` has the details.

## Commits

Imperative mood; say *why*, not just what; include the red and green numbers
when a test is involved. One concern per commit. No attribution trailers or
generated-by markers.

## Pull requests

CI must be green: the offline suites, the sanitizer build, the fuzz smoke
and the Linux-oracle suites. The PR template's checklist is the three rules
above. Mounted-path changes cannot be exercised by CI — say in the PR how
you ran them, and against which build id (`Ext4Mac version`).

## Reporting bugs

Use the issue template; it asks for `Ext4Mac version`, `Ext4Mac last-error
/dev/diskN` and the extension's log lines, which is what makes a mount
failure diagnosable in one round trip. Data-loss or memory-safety findings
go through [SECURITY.md](SECURITY.md) instead.
