# Status

What works, what does not yet, and where the evidence is. The engineering
record behind every claim here — the investigations, the incidents, the
measurements — lives in [the notebook](notebook/README.md); this page is the
summary. What the driver will and will not mount is [ENVELOPE.md](ENVELOPE.md),
which is checked against the code on every test run.

Last updated 2026-09-04, at the first release's candidate build.

| phase | state |
|---|---|
| pipeline and packaging | complete — signed, installed, loads, mounts |
| read-only ext2/3/4 | complete |
| write path | complete, on real mounts; every write `e2fsck`-clean, every journal replayed by the Linux kernel |
| kernel-offloaded I/O | **disabled** by design — see gaps |
| correctness harness | complete: image suites, crash consistency, reordered writes, differential vs Linux, replay speed, fuzzing, mounted driver |
| encrypted volumes | complete: LUKS1 and LUKS2, unlock from the menu bar or the command line |
| distribution | complete: DMG, notarization, versioning, release workflow proven by dry run; first release in preparation |

## What works today

- **ext2, ext3 and ext4 mount, read and write** through a real FSKit mount:
  nested directories, multi-MB files, `cp`, symlinks, hard links, rename,
  `rm`, `rmdir`, extended attributes, preallocation, a clean unmount that
  closes the journal. Volumes written entirely on macOS read back
  byte-for-byte on the Linux kernel with nothing in its log.
- **Journals are replayed** before any read-write mount, and an unreplayed
  log is never written over. A read-only mount does not replay and says so.
- **Auto-mount:** plug a disk in and it appears in Finder under its own label.
- **LUKS1 and LUKS2** (`aes-xts-plain64`; PBKDF2, Argon2id, Argon2i; both
  header copies; every key slot) unlock from the menu-bar agent or
  `Ext4Mac unlock`; the passphrase never enters the sandboxed extension.
- **Formatting** with `newfs_fskit -t ext4|ext3|ext2`, and Disk Utility after
  `sudo make install-diskutil`; `fsck_fskit` is a mountability check.
- **Open-unlink** puts a deleted-but-open inode on ext4's orphan list, so a
  crash in that window is recoverable by the next mount.
- **`chattr +i` / `+a`** are honoured and shown to macOS as `uchg` / `uappnd`.
- **When a volume will not mount, the extension writes down why** and
  `Ext4Mac last-error` reads it back with advice; the agent raises a
  notification. "The disk was not readable" is no longer the only sentence.
- **Performance:** 62.7 MB/s sequential write on a real mount; 400 small
  files in 1.3 s.

The full table of supported, refused and read-only features, and every
measured limit, is in [ENVELOPE.md](ENVELOPE.md).

## Known gaps

- **Kernel-offloaded I/O is off.** Conforming to
  `FSVolumeKernelOffloadedIOOperations` makes FSKit route writes through
  `blockmapFile` even for files that report `inhibitKernelOffloadedIO`, and a
  write blockmap must allocate and journal before returning, with no way to
  undo it if the kernel then fails the I/O. All I/O goes through
  `FSVolume.ReadWriteOperations` — every byte is copied through the
  extension. The code is kept as `Ext4Volume+KernelIO.swift.disabled`.
- **No write barrier.** FSKit's `metadataFlush` fails with `EIO` here and the
  device-level `DKIOCSYNCHRONIZE` is denied to the sandbox, so the journal's
  ordering guarantee stops at the drive's cache. Measured, twice: the current
  direct write path survived twenty mid-write pulls across five drives with
  nothing for `e2fsck` to fix, which is why the privileged barrier daemon was
  retired. It remains an observation about this macOS, not a guarantee.
  [The whole story.](notebook/write-ordering-and-the-barrier.md)
- **Mount options arrive at `activate`**, after the volume is opened and a
  dirty journal replayed, so an option cannot change how it was opened. The
  one that matters, `-o ro`, does not need to: FSKit reports the resource as
  non-writable and the load already acts on that.
- **A notification when a locked volume appears** needs the menu-bar agent
  running; without it the event is recorded and `Ext4Mac status` shows it,
  but nothing pops up.
- **LUKS**: detached headers and ciphers other than `aes-xts-plain64` are
  refused by name; reading a header from media the user does not own
  (`root:operator` device nodes) is untested against a physical stick.
- **Refused ext4 features:** `bigalloc`, `inline_data`, `meta_bg`, `casefold`,
  `large_dir`, `ea_inode`, fscrypt, compression and external journals, each
  with a message that names it. `quota`, `project` and `verity` mount
  read-only.
- **Apple Silicon only**; no Intel or universal build.

## How it is tested

The oracle is never this driver. `make validate` runs 29 stages unattended
in about ten minutes: every read against `debugfs`, `e2fsck` after every
write, crash cuts and reordered writes replayed by the Linux kernel, both
directions of a differential round trip, LUKS containers judged by real
`cryptsetup`, a mutation campaign and 20 hostile fixtures, and — with the
extension approved — the live mount: crash snapshots by `SIGSTOP`, kill
recovery with a timed remount, encrypted volumes, newfs, user-visible
events. CI runs the offline set on macOS, the sanitizer build, a fuzz smoke
with a coverage gate, and the oracle suites on Ubuntu; a nightly fuzzes for
an hour each way. The stage table is in the [README](../README.md#how-it-is-tested);
how each suite came to exist is in the notebook.

## The record

| what | latest | where |
|---|---|---|
| full validation | 2026-09-04: 29 stages green, 580 s | `make validate` |
| soak | 2026-09-02: **17** clean rounds of the full set (20 requested; three spanned a lid-close and were excluded although each passed) | [notebook/soak.md](notebook/soak.md) |
| pull test | twenty mid-write pulls across five drives, USB-2 sticks to an NVMe SSD behind a bridge; every one `e2fsck`-clean, no synced file lost | [the five-drive verdict](notebook/write-ordering-and-the-barrier.md#the-barrier-daemon-is-retired-a-five-drive-verdict) |
| hardware loop | the runbook and its last session | [HARDWARE.md](HARDWARE.md) |
| fuzzing | 20 hostile fixtures, one per finding; the nightly's latest (an inode count that could not cover its groups) fixed 2026-09-04 | `Tests/fixtures/hostile/MANIFEST` |
| bugs found in lwext4 | 78 numbered patches, each with its reason | [patches/lwext4/README.md](../patches/lwext4/README.md) |

The counts on this page are checked against the tree by
`Tests/run_docs_tests.sh` where they can be, and dated where they cannot.

## The notebook

Dated, in the order the work happened, content untouched. Start with
[write ordering and the barrier](notebook/write-ordering-and-the-barrier.md)
if you want to know what this driver can and cannot promise, and with
[the pre-hardware hardening pass](notebook/pre-hardware-hardening-pass.md)
for how the fuzzing and error-injection work began. The full index with
one line per entry is [notebook/README.md](notebook/README.md).
