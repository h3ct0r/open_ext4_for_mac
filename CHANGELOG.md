# Changelog

All notable changes to this project are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the project uses
[Semantic Versioning](https://semver.org/). `make release VERSION=x.y.z`
refuses to cut a release whose section is not written here first, and
`make changelog-draft` prints the commits since the last tag under these
headings to be edited into one.

## [Unreleased]

### Added
- Continuous integration on GitHub Actions: the offline suites on macOS 26, the
  same core under AddressSanitizer and UBSan, a five-minute fuzz smoke with a
  coverage gate, and the five oracle suites judged by the Linux kernel's own
  ext4 on an Ubuntu runner.
- In-process libFuzzer harness with a structure-aware mutator and checksum
  stamper; a mutation campaign that runs inside `make validate`; twenty
  hostile fixtures, one per finding, each proven red before its fix.
- `Ext4Mac last-error` and `Ext4Mac events`: the extension records why it
  refused, degraded, locked or could not mount a volume, and the app reads it
  back with advice. The menu-bar agent turns a new record into a
  notification and keeps the last ten under "Recent Issues"; `Ext4Mac status`
  lists every volume with something to report.
- `make help`.
- `Ext4Mac forget --all`, which lists what it would forget and requires
  `--yes`; `forget` verifies removal and says which store it cleared.
- `Ext4Mac selftest`: is key material locked into memory on this machine.
- `docs/ENVELOPE.md`: the operating envelope, with its feature table diffed
  against the shim's on every run.
- `VERSION`, this changelog, and `make release`.

### Changed
- Key schedules and derived keys are `mlock`ed; a refused lock is reported,
  not failed on.
- `bigalloc` volumes are refused by name rather than mounted read-only: lwext4
  has no cluster concept and over-read at mount.
- The tools build and run on Linux (OpenSSL backend for the crypto).

### Fixed
- Twelve memory-safety and logic bugs in the vendored lwext4 found by fuzzing,
  and five more found by CI's first runs, as patches 0062 through 0078.
- A superblock whose inode count does not cover every block group is refused
  at probe: the last group's inode count underflowed and the first create
  read past the end of a one-block bitmap (found by the nightly fuzzer).
- A volume this driver declined could not be ejected until the idle probe
  process exited: the declined resource was kept, and with it the device.
- A read-only "degraded" record was written for every normal mount of a
  dirty volume, because fskitd loads each volume read-only once before
  mounting it; the record is now written only when the mount activates.
- The release pipeline: a Keychain-exported .p12 (legacy RC2 encryption) is
  accepted, `security import` is told the format, and the app signs when it
  has no entitlements on macOS's bash 3.2.
- An infinite loop in the inode allocator on a group whose descriptor and
  bitmap disagree; a use-after-free in the journal's block records after an
  aborted transaction; the read-only mount of a dirty journal now says so at
  the error level.

## [0.1.0] - 2026-08-29

### Added
- Reads and writes ext2, ext3 and ext4 through a real FSKit mount, with
  automatic mounting on attach.
- Journal replay on read-write mount; refusal to write over an unreplayed log.
- LUKS1 and LUKS2 containers (aes-xts-plain64; PBKDF2 and Argon2), unlocked
  from the menu bar or `Ext4Mac unlock`, keys kept in the login keychain.
- Formatting (`newfs_ext4`) and a mountability check.
- Crash-consistency, reordered-write, differential-vs-Linux, replay-speed and
  mounted-driver suites; the pull test on real hardware.
