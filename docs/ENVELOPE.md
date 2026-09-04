# Operating envelope

What this driver will mount, what it will refuse, what it downgrades to
read-only, the limits it has been tested to, and the one guarantee it cannot
give. Every table here that has a counterpart in the code is checked against
it by `Tests/run_envelope_tests.sh` (`make test-envelope`, validation stage
`0c`), so a row that stops describing the code is a red cell rather than a
stale sentence.

## Feature policy

The probe parses the superblock by hand, before anything is mounted, and
decides by this table. It is data in `Core/shim/ext4_bridge.c`
(`ext4b_feature_rules`); `ext4dump policy` prints it; the suite diffs this
copy against that one.

| set | bit | feature | policy | what a person is told |
|---|---|---|---|---|
| incompat | 0x00001 | compression | refused | filesystem uses compression |
| incompat | 0x00002 | filetype | supported |  |
| incompat | 0x00004 | needs_recovery | supported |  |
| incompat | 0x00008 | journal_dev | refused | this is an external journal device |
| incompat | 0x00010 | meta_bg | refused | filesystem uses meta_bg descriptor placement, which this driver reads incorrectly |
| incompat | 0x00040 | extent | supported |  |
| incompat | 0x00080 | 64bit | supported |  |
| incompat | 0x00100 | mmp | supported |  |
| incompat | 0x00200 | flex_bg | supported |  |
| incompat | 0x00400 | ea_inode | refused | filesystem uses EA inodes |
| incompat | 0x02000 | metadata_csum_seed | supported |  |
| incompat | 0x04000 | large_dir | refused | filesystem uses large directories |
| incompat | 0x08000 | inline_data | refused | filesystem uses inline data |
| incompat | 0x10000 | encrypt | refused | filesystem uses encryption (fscrypt) |
| incompat | 0x20000 | casefold | refused | filesystem uses case-folding |
| ro_compat | 0x00001 | sparse_super | supported |  |
| ro_compat | 0x00002 | large_file | supported |  |
| ro_compat | 0x00008 | huge_file | supported |  |
| ro_compat | 0x00010 | uninit_bg | supported |  |
| ro_compat | 0x00020 | dir_nlink | supported |  |
| ro_compat | 0x00040 | extra_isize | supported |  |
| ro_compat | 0x00100 | quota | read-only | filesystem uses quotas |
| ro_compat | 0x00200 | bigalloc | refused | bigalloc (clustered allocation) is not supported by this driver; the volume itself is fine |
| ro_compat | 0x00400 | metadata_csum | supported |  |
| ro_compat | 0x02000 | project | read-only | filesystem uses project quotas |
| ro_compat | 0x08000 | verity | read-only | filesystem uses fs-verity |

A bit that is not in the table is refused if it is INCOMPAT (the on-disk
layout may differ in ways the driver cannot see) and downgraded to read-only
if it is RO_COMPAT (safe to read, not to write). That is the allow-list rule;
the rows above are the bits that have been looked at and given a reason.

Two rows deserve a sentence. **meta_bg** is refused, not downgraded, because
it was measured: on a meta_bg volume e2fsck calls clean and this driver reads
the wrong descriptors past the first meta block group -- a driver that returns
the wrong bytes is worse than one that declines. **bigalloc** is RO_COMPAT by
ext4's rules and refused by this driver's, because lwext4 has no cluster
concept and sizes bitmap checksums by `blocks_per_group`, which on a bigalloc
volume is clusters x ratio -- a 64 KB read out of a 4 KB buffer at mount. The
volume itself is fine; the message says so.

## Limits

| limit | value | where it comes from |
|---|---|---|
| block sizes mounted | 1 KiB to 64 KiB (`s_log_block_size` 0..6) | the probe's geometry gate |
| block sizes formatted | 1, 2 or 4 KiB | `ext4b_format` |
| largest volume formatted | 17592186044416 bytes (16 TiB) | `FSFormatMaximumSize`; the formatter omits `64bit`, so 2^32 blocks at 4 KiB |
| smallest volume formatted | 1 MiB | `FSFormatMinimumSize` |
| formatted feature set | `has_journal dir_index filetype extent sparse_super large_file` | lwext4's mkfs; no `metadata_csum`, no `64bit`, no `flex_bg` -- use `mke2fs` when you have it |
| directory entries | HTree-indexed directories are read and written | 300-entry directories in every seed corpus |
| xattrs | in-inode and in a separate block; `user.*` namespace through the mount | the write suite |
| ext2 / ext3 | mount, read and write | no journal on ext2, so direct-write ordering is the only durability |

## Journals

- A **read-write** mount of a volume with an unreplayed journal replays it
  first, and refuses the mount if replay fails -- never writes over an
  unreplayed log.
- A **read-only** mount does not replay. You see the volume as of its last
  checkpoint, not its last committed transaction, and the core logs
  `read-only mount of an unreplayed journal: contents predate the last crash`
  at its error level so the app can show it. Linux replays even on a read-only
  mount; this driver cannot, because read-only means read-only here.
- Mounting read-write something the driver rated read-only is not offered.
- Replay speed is a tested number, not a hope: a 128 MiB journal with ~1700
  transactions left unreplayed, priced like a USB stick (500 us per command,
  40 MB/s), replays in about 14 s modelled against DiskArbitration's ~20 s
  patience. The incident that produced that test took over eight minutes.

## Encrypted volumes (LUKS)

| | |
|---|---|
| formats | LUKS1; LUKS2 with 512- and 4096-byte encryption sectors |
| cipher | `aes-xts-plain64` only, 256- or 512-bit master keys |
| KDFs | PBKDF2 (sha1 / sha256 / sha512), Argon2id, Argon2i |
| key slots | every enabled slot is tried |
| headers | both LUKS2 copies, checksum-verified; the newer valid one wins |
| key storage | the login keychain first; the extension's container as fallback; `Ext4Mac forget` verifies removal and says which half it cleared |

Anything else is refused by name rather than guessed at. A cipher mismatch
does not fail; it produces well-formed nonsense, and on a write it destroys the
volume, so the refusal is the safe verdict.

## Performance, as measured

| | |
|---|---|
| 256 MB sequential write, real mount | 62.7 MB/s (batched transactions) |
| 400 small files | 1.30 s |
| kernel-offloaded I/O | off: FSKit routes writes through `blockmapFile` even for files that inhibit it, and a write blockmap must allocate before it knows the I/O succeeded |

All I/O goes through `FSVolume.ReadWriteOperations`. The code for the
offloaded path is kept as `Ext4Volume+KernelIO.swift.disabled`.

## The barrier: what this driver cannot promise

ext4's journal orders metadata writes so that a crash leaves either the old
state or the new one. That ordering holds up to the drive's write cache. To
push it through the cache a filesystem asks the drive to commit -- on macOS,
`DKIOCSYNCHRONIZE`, which HFS+ and APFS use.

This module cannot ask. `metadataFlush`, the only barrier in the `FSResource`
API, returns `EIO` here along with the whole metadata I/O family, during probe
and after load, while a plain `read` of the same bytes succeeds. Apple's
`msdos` module uses that family; `exfat` does not; nothing observable
explains why it is closed to this one. The device descriptor FSKit holds is
real, but `DKIOCSYNCHRONIZE`, `DKIOCSYNCHRONIZECACHE` and even the getter
`DKIOCGETBLOCKSIZE` on it are refused with `EPERM` by the sandbox.

**What runs instead:** every write is handed synchronously to the device
through FSKit's raw descriptor, in issue order. The only cache left between
the journal and the medium is the drive's own.

**What that was measured to cost:** twenty power-cut pulls across five drives
-- three USB sticks, a USB SSD and an NVMe enclosure with real DRAM behind its
bridge -- each with rename-heavy fenced loads and unfenced 1-2 MB sustained
writes, autopsied with `e2fsck` on a dd image and `debugfs rdump` against
sha256 manifests. Every round replayed its journal on remount; every image was
clean; ~7,500 sync-fenced files verified bit-for-bit; **zero synced files
lost.** Two of the five drives were run as an A/B against a privileged helper
issuing real barriers, and the unbarriered arm recovered exactly as cleanly.
That is why the helper is gone. The full record is in
[docs/STATUS.md](STATUS.md#the-barrier-daemon-is-retired-a-five-drive-verdict)
and the sessions in [docs/HARDWARE.md](HARDWARE.md).

**What remains:** an observation about five drives on this macOS version is
not a guarantee. A drive that reorders across its cache and loses power in the
window can, in principle, leave a journal commit ahead of the data it covers.
Nothing in this project has seen it happen.

**What you can do:** eject before you unplug -- a clean unmount commits the
journal and the drive flushes on eject. For a disk you only need to read, mount
it read-only from the menu bar and the question does not arise.

**Filed with Apple:** `FB________ (filed YYYY-MM-DD)` -- the report is
[docs/feedback/metadata-flush-eio.md](feedback/metadata-flush-eio.md), drafted
and not yet filed.

## Platform

Apple Silicon, macOS 15.4 or later; developed and tested on macOS 26. Intel
Macs are not supported: no Intel or universal build is produced or tested.

## What is tested where

- **CI, every push** (`.github/workflows/ci.yml`): the offline suites on
  macOS 26; the same core built with AddressSanitizer and UBSan; a five-minute
  fuzz smoke each way with a coverage gate; and the five oracle suites on an
  Ubuntu runner where the Linux kernel's own ext4 judges every crash cut,
  reordered write, differential round trip and LUKS container. 17 hostile
  fixtures, one per finding, each proven red before its fix and green after.
- **Nightly** (`nightly.yml`): an hour of fuzzing each way with the corpus
  that has been growing across runs, and an offline soak.
- **Only on a Mac with the extension installed and approved**
  (`make validate`, `make soak`): the mounted stages -- the real FSKit mount,
  crash snapshots by `SIGSTOP`, kill-recovery, mounted LUKS, newfs, scale --
  and the pull test, which needs hands on a stick. No runner can grant an
  extension approval, so these stay local, and CI's job is to make everything
  else impossible to forget.
