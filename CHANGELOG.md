# Changelog

All notable changes to this project are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the project uses
[Semantic Versioning](https://semver.org/). `make release VERSION=x.y.z`
refuses to cut a release whose section is not written here first, and
`make changelog-draft` prints the commits since the last tag under these
headings to be edited into one.

## [Unreleased]

### Added
- **A Setup Assistant.** The first launch now opens one window that walks the
  whole install: approve the extension, start at login, allow notifications,
  add ext2/3/4 to Disk Utility with the standard administrator prompt, mount a
  sample ext4 volume that ships inside the app, and a short tour of the
  menu-bar icon. Reopen it from the menu, or with `Ext4Mac setup`.
- `Ext4Mac setup --check [--json]` prints the same checklist without a window
  and exits 1 when something is missing, so a script can ask.
- `Ext4Mac selftest --mount` mounts the bundled sample volume, reads a file
  back through the driver and ejects it — the install proven end to end.
- An application icon: a dark tile carrying the word `ext4`, drawn at three
  levels of detail so it stays legible down to 16 px.
- Closing the Setup Assistant before it is finished asks first, naming the
  steps not seen yet, anything still missing, and a sample volume that would
  be ejected. It stays quiet for skipped steps, warnings, the last screen, and
  a setup already completed.

### Changed
- The first run is no longer three NSAlerts. They fired before the menu-bar
  icon existed, gave "registered but not approved" and "not registered at all"
  the same sentence, and stopped watching for the approval after two minutes
  in silence.
- The menu header asks FSKit what it thinks of the module when the menu opens,
  instead of checking that a file exists in /Applications — a bundle sitting
  there unapproved used to report itself as installed and ready.
- `Ext4Mac setup` hands the request to the agent that is already running
  instead of starting a second one, which would have been a second identical
  menu-bar icon watching the same disks. The window also opens on the display
  the pointer is on, rather than wherever `center()` decided.

### Fixed
- **Disk Utility can erase a physical disk as ext4.** It failed with "File
  system formatter failed (-69832)" for every real disk: the `.fs` bundle's
  wrapper re-dispatched the work to the logged-in user, who cannot open a
  device node that belongs to root, so the open failed before this driver was
  asked. The wrapper now keeps the privileges macOS gives it. First Aid on an
  ext4 volume had the same bug and is fixed with it. Reinstall the Disk
  Utility integration to pick this up — from the Setup Assistant, or
  `sudo make install-diskutil`.
- The app no longer records the Setup Assistant as completed just because the
  extension is enabled. That key was written at launch for every working
  install, so the app believed people had finished a window they had never
  opened — and closing it halfway through therefore asked nothing.

## [0.1.0] - 2026-09-05

The first release. Everything below is in it.

### Added
- Reads and writes ext2, ext3 and ext4 through a real FSKit mount, with
  automatic mounting on attach.
- Journal replay on read-write mount; refusal to write over an unreplayed log.
- LUKS1 and LUKS2 containers (aes-xts-plain64; PBKDF2 and Argon2), unlocked
  from the menu bar or `Ext4Mac unlock`, keys kept in the login keychain.
- Formatting (`newfs_ext4`) and a mountability check.
- Crash-consistency, reordered-write, differential-vs-Linux, replay-speed and
  mounted-driver suites; the pull test on real hardware.
- Continuous integration on GitHub Actions: the offline suites on macOS 26, the
  same core under AddressSanitizer and UBSan, a five-minute fuzz smoke with a
  coverage gate, and the five oracle suites judged by the Linux kernel's own
  ext4 on an Ubuntu runner.
- In-process libFuzzer harness with a structure-aware mutator and checksum
  stamper; a mutation campaign that runs inside `make validate`; 22
  hostile fixtures, one per finding, each proven red before its fix; a
  twenty-round soak with fuzzing between rounds, and a hardware
  re-verification on a real USB stick, both recorded in the docs.
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
  five more found by CI's first runs, and one by the soak, as patches 0062
  through 0079 -- the last an xattr list that put every second entry on a
  misaligned address on any healthy volume with two attributes on one file.
- Listed extended-attribute names carried the on-disk `user.` namespace
  (`user.com.apple.provenance`), so a file copied off a volume came home with
  its metadata renamed; names are now the ones macOS set.
- `Ext4Mac last-error <disk>` finds a record keyed by the volume's UUID --
  what a pulled stick leaves -- by the disk name a person types.
- A superblock whose inode count is not block groups x inodes per group is
  refused at probe, in either direction -- the Linux kernel's own rule. Too
  few underflowed the last group's count and the first create read past a
  one-block bitmap; too many made a read-only walk take 52 seconds.
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
