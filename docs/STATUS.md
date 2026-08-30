# Status

| Phase | State |
|---|---|
| 0 — pipeline & packaging | **complete — signed, installed, loads** |
| 1 — read-only ext2/3/4 | **complete; read suite green** |
| 2 — kernel-offloaded I/O | **disabled** — see below |
| 3 — write path | **complete and working on real mounts** |
| 4 — correctness harness | **complete: image, crash-consistency, differential-vs-Linux, and mounted-driver** |
| 5 — polish & distribution | **format implemented**; check is a mountability check only; no DMG yet |

## What works today

```bash
make          # builds Ext4Mac.app with the FSKit extension inside
make test     # the read suite against real ext2/3/4 images
```

The whole project builds with the **Command Line Tools** — full Xcode is not
required.

**Core (verified):** probe and feature gating; mount and statfs; inode
attributes, hard links and symlinks; directory enumeration including
HTree-indexed directories; file reads across 1 KiB and 4 KiB block sizes on
both ext2 indirect-block and ext4 extent layouts; logical→physical extent
mapping; extended attributes. Every content read is compared byte-for-byte
against `debugfs`, and every fixture is checked with `e2fsck`.

**Extension (signed, installed, loads and mounts):** the full FSKit surface —
`FSUnaryFileSystem` probe/load/unload, `FSVolume.Operations`,
`FSVolume.ReadWriteOperations`, `FSVolume.XattrOperations`,
`FSVolume.PreallocateOperations`, and `FSManageableResourceMaintenanceOperations`
(format/check) — plus Info.plist, entitlements and bundle layout matching what
shipping FSKit modules use. (`FSVolumeKernelOffloadedIOOperations` is
implemented but held out of the build; see below.)

## It reads and writes

A volume written entirely from macOS through the driver, then read back by the
real Linux kernel:

```
content : created on macOS
symlink : /docs/nested/mac.txt
hardlink: shares inode
xattr   : macos
payload : 2d52119dcb45412e...   (sha256 matches byte-for-byte)
kernel complaints: 0
```

`e2fsck` reports the volume clean afterwards with no journal replay required.

Working through a real mount: nested `mkdir`, file create and write, multi-MB
files, `cp`, symlinks, hard links, rename, `rm`, `rmdir`, extended attributes,
and a clean unmount that closes the journal and writes back the superblock.

## It mounts

```
/dev/disk5 on /private/tmp/ext4mnt (ext4, local, nodev, nosuid, noowners,
                                    noatime, fskit, mounted by h3ct0r)
```

Verified on a real mount of the full fixture: directory listings, nested
directories, symlink targets (including a deliberately broken one), hard links
sharing an inode, a 500-entry HTree directory enumerated completely, `statfs`
reporting correct capacity, and file contents byte-identical to the same reads
through the offline core — including a 3 MB extent-mapped file. `e2fsck` is
clean after a mount/unmount cycle.

Loading requires a **Developer ID certificate and a provisioning profile**
carrying `com.apple.developer.fskit.fsmodule` (a paid Apple Developer account;
see `docs/SIGNING.md`). Building and testing the core needs none of that.

### Known gaps on the mounted path

- **Kernel-offloaded I/O is off.** Conforming to
  `FSVolumeKernelOffloadedIOOperations` makes FSKit route writes through
  `blockmapFile` even for files reporting `inhibitKernelOffloadedIO`, and a
  write blockmap must allocate blocks and journal the extent-tree change before
  returning, with no way to undo it if the kernel then fails the I/O. All I/O
  currently goes through `FSVolume.ReadWriteOperations`. The code is kept as
  `Ext4Volume+KernelIO.swift.disabled`.

- **No explicit write barrier.** `metadataRead` fails with EIO both during
  probe *and* after load, so the metadata-cache family — and with it
  `metadataFlush` — is unusable here. Direct device I/O is what runs, so
  ordering rests on `FSBlockDeviceResource.write` reaching the medium in issue
  order, which FSKit does not document.

  That assumption is now tested rather than asserted: see *Crash safety on the
  mounted path* below. It holds in every case measured, but it is an
  observation about this macOS version, not a guarantee.

- **Mount options arrive late, at `activate`.** They do arrive — an earlier
  note here said they did not, which was measured at the wrong callback and is
  corrected under *Mount options* below. What is true is that they arrive
  *after* `loadResource`, which is where the volume is opened and a dirty
  journal replayed, so an option cannot change how the volume was opened. The
  one that matters, `-o ro`, does not need to: FSKit reports the resource as
  non-writable and `loadResource` already acts on that.

### Getting from "signed" to "mounts"

Four defects sat between a correctly signed bundle and a working mount, none of
them in the filesystem code:

| Symptom | Cause |
|---|---|
| Extension exits 0 after ~50 ms; `Couldn't communicate with a helper application` | Wrong entry point. Xcode's `extensionkit-extension` product type links with `-e _EXExtensionMain`; the default `_main` sets up and returns |
| `probe: I/O error` reading the superblock | `metadataRead` is unusable before the resource is loaded; use direct device I/O |
| `Loading resource: Resource temporarily unavailable` (EAGAIN) | `containerStatus` left at NotReady. FSKit needs Ready before `loadResource` returns, then Ready ⇄ Active around activation |
| Extension never launches | Missing `application-identifier` / `team-identifier` entitlements, so the provisioning profile cannot be matched |

A minimal do-nothing extension reproduced the first one identically, which is
what proved it was packaging rather than our code.

## Writing

Implemented and passing: create, mkdir, symlink, hard link, unlink, rmdir,
rename (including across directories, over an existing file, and moving a
non-empty directory), write, append, multi-block writes, truncate both
directions, sparse regions, chmod/chown/times, and xattr set/remove.

Each operation is a single JBD2 transaction that either commits or aborts
leaving the volume untouched.

**A healthy volume mounts read-write by default, and `-o ro` opts out.**
Read-only is honoured properly — the mount is marked read-only at the VFS
layer, writes are refused, and the volume is not touched at all: no journal
replay, no superblock update. Measured by hashing the image either side of a
mount:

```
before any mount:      clean
while mounted -o ro:   clean          image byte-identical: YES
while mounted (rw):    not clean      image byte-identical: NO
```

One consequence is worth knowing. A volume with an unreplayed journal still
mounts read-only, and stays untouched — which means the journal is *not*
replayed and you are looking at the volume as of the last checkpoint, not the
last committed transaction. Linux replays even on a read-only mount unless you
pass `norecovery`; it can, because it is allowed to write. Mount read-write, or
run `e2fsck`, to see the recovered state.

The reverse — mounting read-write something the driver has rated read-only — is
not offered, and deliberately so. Unsupported features, a dirty journal that
would not replay, or a `metadata_csum_seed` that no longer matches the UUID all
force read-only, and those are exactly the cases where writing is how a volume
gets destroyed.

### Mount options

An earlier version of this document said mount options never reach the module.
That was wrong, and wrong in an instructive way: it was measured at
`mount(options:)`, whose own header says *"there are no defined options
currently"* — which is true of that callback and of no other. `loadResource`
is empty too, despite its header documenting `-f` and `--rdonly`.

They arrive at **`activate(options:)`**, and only because `Info.plist` declares
`FSActivateOptionSyntax` — the same key Apple's `msdos` module uses for its
`-u/-g/-m/-o`. Measured against a live mount:

| `mount -F -t ext4 …` | what `activate` receives |
|---|---|
| *(no options)* | `[]` |
| `-o ro` | `["-o", "ro"]` |
| `-r` | `["-o", "ro"]` — `mount(8)` normalises it |
| `-o rw` | `["-o", "rw"]` |
| `-o ro,noatime` | `["-o", "ro", "-o", "noatime"]` |

So a comma list is split into repeated `-o value` pairs, and everything the
user typed comes through.

What this does **not** buy is a way to change how the volume was opened.
`activate` runs after `loadResource`, and `loadResource` is where the journal
gets replayed and `VALID_FS` cleared — by the time an option is legible, any
writing has happened. Read-only works regardless, because it travels by a
different road: FSKit marks the resource non-writable and `loadResource` reads
*that*.

The options are therefore not acted on today. The one thing they could add is
defence in depth — refusing to activate if `ro` was asked for and the volume
somehow came up writable — which is worth doing but is not a behaviour change.

### Files Linux marked as protected

`chattr +i` and `chattr +a` are how a Linux user says *do not change this*. A
driver that ignores them removes the protection silently, and the user finds
out when the file is gone — so every mutating entry point checks:

| | what is refused |
|---|---|
| immutable | writes, truncate, chmod/chown/times, xattrs, rename, hard link, and removal — and, for a directory, gaining or losing any entry |
| append-only | truncate, removal, rename, xattrs, and any write that lies wholly inside the file |

They are reported to macOS as `UF_IMMUTABLE` and `UF_APPEND`, which are exactly
the same two ideas in the BSD vocabulary, so `ls -lO` shows `uchg` / `uappnd`
and Finder shows the file as locked. That matters more than it sounds: it turns
an unexplained *Operation not permitted* into something the user can see the
reason for. macOS then does the enforcement itself — an append-only file cannot
even be **opened** for ordinary writing.

Which is what makes the obvious rule for append-only the wrong one. Requiring a
write to start at end-of-file refuses real appends: the buffer cache rewrites
whole pages, so appending five bytes to a five-byte file arrives as a ten-byte
write at offset zero. That was measured on a live mount, not reasoned about,
and the check is now the one no cache produces — a write that lies entirely
inside the file and does not reach its end.

Setting or clearing the flags is not supported. lwext4 offers no way to rewrite
the inode's flags word, and on Linux only root may clear either flag in any
case. A `chflags` that would really change something is refused rather than
reported as a success that did not happen; use `chattr -i` on Linux.

### How it is tested

`e2fsck` runs after **every** mutating operation, not once at the end — a write
path that corrupts and then repairs two operations later still loses data on
power failure. Results are cross-checked against `debugfs`, an independent
implementation, so the suite cannot agree with a bug in our own reader.

`make test-asan` reruns everything under AddressSanitizer and UBSan. That is
how two genuine lwext4 defects were found; see `patches/lwext4/README.md`.

## Validation

```bash
make validate           # the full chain (18 stages), unattended
make validate-asan      # the same under AddressSanitizer + UBSan
make test-format        # stage 3 on its own
make test-orphan        # stage 4 on its own
make test-mount-crash   # stage 7 on its own
```

| Stage | What it proves |
|---|---|
| 0 / 0b — patches, ship surface | the patch set reproduces the vendored tree; the shipping core reads no environment |
| 1 — read suite | content verified byte-for-byte against `debugfs` |
| 2 / 2b — write suite, bounds | `e2fsck` after **every** mutating operation; overflow and POSIX-semantics refusals, including hostile journal geometry under deadlines |
| 3 — format | a size/block-size/generation sweep must be `e2fsck`-clean and round-trip through the Linux kernel; big formats and lazy-init mounts are bounded in device *commands* |
| 4 / 4b / 4c — orphans, prealloc, revoke | every cut point of a deferred delete recovers by *mounting*; unwritten-extent lifecycle; every revoke entry names a real block |
| 5 / 5b — crypto, error injection | AES-XTS known answers; a medium that answers EIO must surface every failure (exit codes, kept journals, e2fsck-clean end states) |
| 6 — LUKS | fixtures made by real cryptsetup, read back by the Linux kernel |
| 7 / 7b — crash, reordered writes | the write stream severed at every cut point, replayed by the **real Linux kernel**; then the same on a medium that also **reorders** what was in flight |
| 8 / 8b — differential, replay speed | round-trips between our driver and Linux ext4 with a silent kernel log; a deep dirty journal must mount inside DiskArbitration's ~20 s budget on a modelled USB stick |
| 9–12 — mounted stages | the real FSKit mount: crash sweeps, encrypted volumes, kill recovery (now with a timed deep-journal remount), newfs/fsck |

The per-suite assertion counts drift as suites grow; the suites print their
own tallies and the validation driver records PASS/FAIL/SKIP per stage —
those, not this table, are the record.

Stages 5–7 use Docker, which on Apple Silicon is a real Linux VM — so the
oracle is the actual ext4 implementation, not another copy of our assumptions.
They skip with a warning if Docker is not running; stage 7 also skips if the
signed extension is not installed and enabled. Stages 3 and 4 run either way —
only one section of each needs Docker.

The power-failure model matters: after the cut point, writes are **silently
discarded while still reporting success**. A real power loss does not hand the
filesystem an errno it can react to. Returning `EIO` would exercise error
handling instead, which is a far easier test to pass.

### Why a second crash suite

The crash sweep above has always passed, and for a long time that was not
evidence of anything. A disk image's writes reach the host filesystem in issue
order and stay there, so a torn image is always a clean prefix of the write
stream — the one state that is safe by construction. Forty-two cut points
across two image sizes: all clean. The same driver against a USB stick:
damaged five times out of five.

`make test-reorder` closes that gap by modelling the medium instead of trusting
it. With `EXT4DUMP_WRITE_CACHE` set, `ext4dump` behaves like a drive rather
than a file: reads are served from the cache, only a barrier makes a write
durable, a full cache evicts a seeded-random half **out of order**, and at the
cut whatever is still pending is permuted and only a prefix of that permutation
is committed. The seed is the whole reproduction recipe.

The suite is a matrix now — geometries × workloads × batch sizes — because
its worst failure was structural: every cell it had ran on a 16 MB journal
that never wrapped during a workload, and the wrap path is where lwext4's
ordering bugs lived (patches 0017–0020). The 64 MB fixtures carry the 4 MB
minimum journal; the wrap-heavy workloads cycle creates and deletes so
revokes and log laps actually happen; `--quick` runs the load-bearing cells
in under thirty seconds for the dev loop. Every torn image is replayed by the
Linux kernel; a trace classifier (`Tests/classify_trace.sh`, fed by
`EXT4DUMP_TRACE`) attributes any failure to the write class that landed out
of order — filesystem superblock, journal superblock, log, or home metadata —
which is how the tail-advance bug was diagnosed rather than guessed at.

Two things are asserted, and the second matters as much as the first:

```
236 cut points, 15 cells                 every one clean
barriers ignored (three controls)        every one damaged
```

A crash-consistency test that cannot be made to fail is not evidence. This
project has shipped one check that could only report success — it reported it
on a volume the driver had never touched — which is why the negative control is
part of the suite rather than a thing someone remembers to run.

The knobs, following the existing `EXT4DUMP_*` idiom:

| variable | meaning |
|---|---|
| `EXT4DUMP_WRITE_CACHE` | cache size in bytes; unset leaves behaviour exactly as before |
| `EXT4DUMP_REORDER_SEED` | permutation used for eviction and for the crash |
| `EXT4DUMP_REORDER_DROP` | percentage of the pending queue lost at the cut |
| `EXT4DUMP_IGNORE_BARRIERS` | a drive that reports a cache flush and does not perform one |

One trap, since it invalidated a whole run before anyone noticed: counting the
workload's writes must be done against a *copy* of the fixture. Run against the
fixture itself it mutates it, every later clone starts with the workload's
directories already present, the script aborts on its first `mkdir`, and the
suite reports that a filesystem nobody touched recovered perfectly.

## Crash safety on the mounted path

Stages 1–4 all drive the core through a plain file. They say nothing about
`FSBlockDeviceResource`, which is what a real mount uses. Stage 5 closes that.

The cut is made by stopping the **extension process** with `SIGSTOP`. Every
thread freezes where it stands, so whatever has reached the medium at that
instant is exactly what a power failure would have left — no cooperation from
the driver, no errno it could have reacted to. The device is then imaged, the
driver resumed, and the image handed to the Linux kernel to replay.

| What it checks | Why |
|---|---|
| concurrent readers and writers finish, and the extension goes idle afterwards | FSKit issues volume operations in parallel; every core entry must be serialised or lwext4's block cache corrupts and the volume wedges |
| seven metadata operations survive a cut taken after a `sync` | recovering to *some* consistent state is not enough — a driver that discarded everything would also pass |
| a batch that was never synced still leaves a volume the kernel recovers | losing recent work is the deal; taking the filesystem with it is not |
| a deleted-but-still-open file is on the volume's orphan list, and a snapshot taken while one exists is reclaimed by *mounting* it | the orphan list is the only thing that can find such an inode afterwards; this is the check that it is engaged on the FSKit path and not only offline |
| every snapshot taken under load recovers clean | the actual crash-consistency claim |
| no snapshot falsely reports filesystem errors | a volume that recovers but reports itself damaged sends the user to a repair tool they do not need |
| the extension produced no crash report | FSKit relaunches a dead extension and the volume keeps working, so a driver that traps on every unmount otherwise looks perfectly green |

In the last five consecutive runs every snapshot caught the volume
mid-transaction — 24 of 24 needing journal replay each time — and every one
recovered clean with no repairs.

Only file *data* is exempt from the durability check. It travels through the
unified buffer cache, which is entitled to hold it; metadata operations are
synchronous by VFS design and are held to the stricter standard.

### What this suite found

Four defects, none of which the offline stages could see:

- **Core entry outside the executor.** `getAttributes` resolved `parentID` by
  reading the directory's `..` entry *after* leaving the serial executor, so two
  kernel threads could enter lwext4 at once. One freed a block-cache buffer the
  other had already released, tripping `ext4_assert(buf->refctr)` — which spun.
  The volume wedged at 200% CPU and `umount` hung in uninterruptible wait, and
  only `kill -9` on the extension cleared it. During enumeration the parent is
  known for free, so it is now passed in and the `..` lookup skipped entirely.
- **`ext4_assert` spun forever** rather than failing (`patches/lwext4/0007`).
  This is what turned each of the two bugs above and below from a failed
  syscall into a lost volume.
- **Block 0 was accepted as a real block** rather than treated as ext4's hole
  marker (`patches/lwext4/0008`), so a lookup in a directory with a hole cached
  a buffer with `lb_id == 0` and then tripped `ext4_assert(b->lb_id)`.
- **A nil dereference on every unmount.** `synchronize` arrives *after*
  `unmount` has closed the volume, and the `device` accessor force-unwrapped.
  Every stage passed while the extension trapped and was relaunched each time —
  the data was already safely on disk, so nothing failed. The only evidence was
  a crash report per run, which is why the suite now checks for those. The
  accessor is fallible now, and a sync of a closed volume is a no-op.

Stage 0 exists for the first of these and runs first: reverting the fix makes
it fail in 120 seconds with the extension at 195% CPU.

The pattern worth noting is that three of the four were invisible in the test
results. Two hung instead of failing, and one crashed a process the system
silently restarts. A suite that only checks whether the filesystem is correct
afterwards would have called all of them green.

## Formatting

macOS ships two module-agnostic drivers, `/sbin/newfs_fskit` and
`/sbin/fsck_fskit`, which dispatch to an FSKit module by name. Conforming to
`FSManageableResourceMaintenanceOperations` is all it takes to be reachable
from them:

```bash
newfs_fskit -t ext4 -L MYDISK /dev/disk5
newfs_fskit -t ext4 -g 3 -b 1024 /dev/disk5     # ext3, 1 KiB blocks
fsck_fskit  -t ext4 /dev/disk5
```

`-t` selects the *module*, by its `FSShortName` — not a personality — so which
of ext2/ext3/ext4 to create is `-g`. The options are declared in `Info.plist`
under `FSFormatOptionSyntax` (`g:b:L:I:N:J:n`) and `FSCheckOptionSyntax` (`n`);
FSKit parses them with getopt before the module sees them.

Formatting clears any previous filesystem's signatures first — 64 KiB of
zeroes over each end of the partition, inside `ext4b_format` itself, since
ext4 never touches the boot area where FAT/exFAT/NTFS keep their magic and a
surviving boot sector would win the next probe. (FSKit's `wipeResource` was
tried and is unreachable from a CLI-initiated format.) Then it builds the
volume.
Each volume gets a fresh random UUID — lwext4's `mkfs` copies whatever UUID it
is handed straight into the superblock and never generates one, so every
volume would otherwise be all-zero and indistinguishable to DiskArbitration.

### What the volumes look like

lwext4's `mkfs` is conservative. Compared with `mke2fs` it omits `ext_attr`,
`resize_inode`, `metadata_csum`, `64bit`, `flex_bg`, `dir_nlink`, `extra_isize`
and `huge_file`, producing:

```
has_journal dir_index filetype extent sparse_super large_file
```

That is a valid ext4 the Linux kernel mounts without complaint, but it has **no
metadata checksums**, so it is less able to detect corruption than a volume
`mke2fs` would create. Anyone with `mke2fs` available is better off using it;
this exists so that a Mac with no e2fsprogs installed can still make a volume.

The lack of `64bit` also caps a volume at 2³² blocks — 16 TiB at the default
4 KiB block size, which is `FSFormatMaximumSize` in the personality.

### `startCheck` is a mountability check, not `fsck`

It parses the superblock, applies the feature gate, verifies the checksum seed
still matches the UUID, and replays a dirty journal. It does **not** walk the
inode table, cross-check bitmaps against extent trees, or repair anything —
lwext4 has no fsck. A volume that passes can still be corrupt in ways only
`e2fsck` will find, and the operation says so in its own output.

## Auto-mount

ext4 volumes now mount by themselves, the way any native disk does:

```
/dev/disk6 on /Volumes/AUTOMOUNT (ext4, local, nodev, nosuid, journaled,
                                  noowners, noatime, fskit, mounted by h3ct0r)
```

No `mount -F -t ext4` needed. Attach a disk and it appears in Finder under its
own label; writes, symlinks and extended attributes all work through it, and
the Linux kernel reads the result back byte-for-byte with a silent log.

This was blocked on Paragon's ExtFS, which was winning the probe. With it out
of the way our module claims the media.

**`diskutil eject` fails on whole-disk images** — but so does Apple's own
exFAT module on the same kind of device, while a *partitioned* exFAT ejects
fine. It is a property of whole-disk raw images, not this driver. `umount(8)`
works either way.

## Open-unlink

A file can be deleted while something still has it open. ext4 frees the inode
as soon as its last link goes, which is too early: the kernel keeps using the
descriptor afterwards, and writes through it then allocate blocks onto an inode
nothing references. The data reads back correctly for the life of the
descriptor, so nothing looks wrong — but the blocks are never recovered, and
`e2fsck` reports `Block bitmap differences` once the volume is unmounted.

The fix has two halves. `FSVolume.OpenCloseOperations` tracks which inodes are
open; `removeItem` defers freeing **only** for those, and
`FSVolume.ItemDeactivation` (with `.forRemovedItems`) plus `reclaimItem` and
unmount all drain the deferred set.

Deferring every delete instead was tried and is worse. The inode then sits with
no links and no owner until FSKit reclaims it, widening the window in which a
power cut leaves exactly the leak described above — the crash-consistency suite
caught it as `Block bitmap differences` in 4 of 24 snapshots.

### The orphan list

That in-memory set says what to do while the driver is running. It says nothing
about a driver that stops running. ext4's answer is the **orphan list**, and
this driver now keeps one: a chain of exactly the inodes in that state, rooted
in the superblock's `s_last_orphan` and threaded through each inode's `i_dtime`
— which is meaningless until an inode is really deleted, so it is free to be a
pointer until then.

It is the same on-disk convention Linux and `e2fsck` use, which is the point.
All three settle a volume the others left:

```
ours     orphan list: reclaimed 3 interrupted delete(s), dropped 0 stale entries
e2fsck   Clearing orphaned inode 526 (uid=501, gid=20, mode=0100644, size=60000)
Linux    EXT4-fs (loop0): 3 orphan inodes deleted
```

Cleanup runs at the end of every read-write mount, after journal recovery, so a
volume this driver crashed on comes back whole without anyone reaching for a
repair tool. Entries whose link count is zero are finished off; entries that
still have a name are dropped and left alone, which is how an interrupted
*addition* undoes itself.

**It is atomic now, the way Linux does it.** The superblock is a journaled
block (patches 0022/0023): the chain-head publish goes through the current
transaction and commits together with the inode change it points at, on both
the add and the remove side. The careful measured orderings this section used
to describe — publish-then-commit on add, free-then-drop on remove — existed
because the two halves landed separately and the order had to pick which
half-state a cut could leave. There is no half-state any more: before the
commit neither happened, after it both did.

The case this closed was measured before and after. Two simultaneous
open-unlinks, the write stream cut between publishing the second head and
committing it: four consecutive cut points stranded the first orphan — off
the chain, out of every directory, invisible to everything but a full fsck.
The two-orphan sweep in `Tests/run_orphan_tests.sh` now covers every cut
point of exactly that scenario, and the Linux kernel replays the
superblock-carrying transactions clean at every cut (fourteen kernel
recoveries in the tag-0 check).

What made it possible in lwext4: the block cache now admits block 0 — the
superblock's home on all volumes with blocks over 1 KiB — through one
sanctioned door (`ext4_block_get_sb`), while the hole-marker refusal that
patch 0008 introduced stays exactly where it was for every mapping-derived
fetch. And jbd's replay had a tag-0 superblock branch all along, unreachable
upstream because nothing ever journaled the superblock; it has a writer now.
Volumes without a journal (ext2) keep the old direct-write ordering, which is
the best a journal-less mode can offer.

**`FSKit`'s own `enableOpenUnlinkEmulation` is deliberately not enabled**, and
the reason it appeared to do nothing earlier turned out to be a mistake worth
recording: the property was declared get-only, and FSKit's protocol declares it
read-write, so it never satisfied the requirement and was never read. The
compiler said as much — *"nearly matches optional requirement"* — in a warning
that was easy to scroll past. `requestedMountOptions` and
`isVolumeRenameInhibited` were silently inert for the same reason and are now
fixed; the emulation is left off on purpose, because it works by keeping a
hidden directory entry that only FSKit knows to clean up, and an orphan record
is both invisible and understood by Linux.

### Renaming

`FSVolume.RenameOperations` is implemented, so Finder's Rename and
`diskutil rename` work. The label is a fixed 16-byte superblock field: a name
longer than that is refused rather than truncated, and the write goes through
immediately instead of waiting for unmount, because a rename the user can see
but that vanishes on power loss is worse than one that fails.

### Disk Utility

`diskutil listFilesystems` and Disk Utility's Erase menu are driven by `.fs`
bundles in `/Library/Filesystems`, not by FSKit — which is how Paragon's extFS
appears in that list. `Packaging/ext4.fs` is such a bundle, and **it works**:

```
EXT2                            ext2
EXT3                            ext3
EXT4                            ext4
```

A plist plus two shell wrappers was enough — no probe helper, no
`FSMediaTypes`, no signing. `diskutil info` on a mounted ext4 volume now
reports its name and mount point instead of `File System: None`.

One cosmetic flaw: it reports `File System Personality: EXT2` for an ext4
volume. All three personalities share the `Linux` content mask and the bundle
has no prober of its own, so DiskArbitration picks the first match.



```bash
sudo make install-diskutil      # sudo make uninstall-diskutil to remove
diskutil listFilesystems | grep -i ext
```

It carries no filesystem logic. `FSFormatExecutable` points at a shell wrapper
that calls `newfs_fskit -t ext4 -g N`, so there is still exactly one
implementation, in the extension. It deliberately declares no
`FSProbeExecutable` or `FSMediaTypes` — DiskArbitration already probes through
FSKit, and a second prober would race it for the same media — and no
`FSMountExecutable`, because mounting goes through FSKit.

The `FSRepair` entry is a half-truth worth knowing about: First Aid passes
`-y`, meaning "repair without asking", and the wrapper prints that it can
verify but not repair rather than reporting a repair that never happened.

Formatting *through* Disk Utility's Erase runs the wrapper as **root**
(diskmanagementd invokes formatters that way), and FSKit module enablement is
per user — root has no modules, so a direct exec fails with "No extension
with fsShortName found" and Erase reports "File system formatter failed".
Both wrappers therefore re-dispatch when run as root: `launchctl asuser`
into the console user's bootstrap context, `sudo -n` to their uid, and the
enablement that exists is the one consulted. The device stays accessible
because fskit_helper (root) opens it, not the calling user.

Live-verified, both verbs. `diskutil eraseVolume EXT4 <name> diskN` over an
existing volume reformats it and DiskArbitration auto-mounts the result
through this driver, read-write; `diskutil eraseDisk EXT4 <name> GPT diskN`
on blank media builds the partition map, types the partition `Linux
Filesystem` (the personality's `FSFormatContentMask`), formats it through
`startFormat`, and mounts it the same way — e2fsck-clean in both cases, with
the extension's own task messages visible in diskutil's output. One
diskutil-ism worth knowing: `eraseVolume` on a *blank* whole-disk fails
earlier with "Couldn't open disk" (-69879) before any formatter runs — blank
media wants `eraseDisk`, which is also what Disk Utility's GUI does.

### `newfs_fskit` works — and what its long failure actually was

`newfs_fskit -t ext4 [-g 2|3|4] [-b size] [-L label] <device>` formats
through the extension, all three generations, and `fsck_fskit -t ext4` runs
the mountability check. Neither needed an ObjC principal class, a different
entry point, or any of the structural surgery the failure seemed to demand.

For most of this project's history the command failed with `ENOTSUP` and
`startFormat` was never called, and the investigation record accumulated a
table of ruled-out suspects pointing at the Swift `@main` entry point as the
remaining explanation. That hypothesis was wrong, and the tracing that
disproved it is worth keeping:

* fskitd's own log showed the extension **launching** for the format
  (assertion grabbed, user client configured) — the Swift entry point,
  manifest and conformance all worked. The glue's launch log even said so
  outright: `Got delegate conformance ... Maintenance 1`.
* the msdos control's only trace difference was one fskitd line — `Adding
  taskID to resource` — which disassembly places in the *success callback*
  of the load that precedes every format.
* our own appex log then completed the story: `loadResource` ran, probed the
  blank device, logged `refusing to mount`, and returned ENOTSUP. **The
  error `newfs_fskit` printed was this module's own refusal**, relayed back
  through fskitd from a load that was never a mount.

fskitd loads a resource before it will format or check it. Media with no
recognisable filesystem on it — the thing `newfs` exists to fix — must
therefore *load* successfully. `loadResource` now answers unrecognised media
with `Ext4UnformattedVolume`, a shell that can be the target of `startFormat`
and `startCheck` but fails activation with the ENOTSUP the load used to
give; auto-mount is unchanged because the probe still refuses everything the
shell stands in for. Two consequences got fixed in the same motion:
`startFormat` closes any volume the preceding load mounted (or the old
handle would write its superblock over the fresh filesystem on unload), and
foreign-signature wiping moved into `ext4b_format` — FSKit's `wipeResource`
facility turned out to be unreachable from a CLI-initiated format ("no
connector talking to fskitd is available"), and 128 KiB of zeroes over the
signature-bearing head and tail of the partition needs no facility. The
format suite covers the wipe offline: planted FAT and end-anchored
signatures are gone after `ext4dump format`, and the volume is e2fsck-clean.

`EXExtensionPrincipalClass` remains poison for a Swift `@main` module — that
part of the old record stands, the two entry-point mechanisms really are
mutually exclusive — it was just never the reason formatting failed.
`@objc(Ext4FileSystem)` was kept; it costs nothing and pins a name that was
otherwise incidental.

The same core path is fully covered offline: `ext4dump format` builds volumes
across 117 geometries, all `e2fsck`-clean.

## Encrypted volumes (LUKS)

ext4 inside a LUKS container reads and writes, both LUKS1 and LUKS2:

```bash
EXT4DUMP_LUKS_KEYFILE=/path/to/passphrase ext4dump container.img ls /
```

LUKS is not an ext4 feature — it is a block layer *underneath* the filesystem,
which is exactly where `BlockDeviceBridge` already sits. So it went in as a
decorator over the same three callbacks `ext4b_device_create` already takes,
and that function did not change:

```
lwext4  →  ext4b_device  →  [ luks_device ]  →  read/write/flush
                              offset shift        FSBlockDeviceResource, or a plain file
                              AES-XTS per sector
```

lwext4 never learns that anything is encrypted. Putting it in the C core rather
than the Swift bridge is what makes it testable: `ext4dump` gets it for free,
so encrypted volumes are exercised with no extension, no signing and no
mounting.

### What is implemented

| | |
|---|---|
| formats | LUKS1, and LUKS2 with both 512- and 4096-byte encryption sectors |
| cipher | `aes-xts-plain64` only, at 256 or 512-bit master keys |
| KDFs | PBKDF2 (`sha1`/`sha256`/`sha512`) and Argon2id/Argon2i |
| key slots | all enabled slots are tried, so any valid passphrase opens it |
| LUKS2 headers | both copies, checksum-verified; the newer *valid* one wins |

Anything outside that list is refused **by name** rather than guessed at —
`cipher "aes-cbc-essiv:sha256" (only xts-plain64 is implemented)`. That
matters more here than in the feature gate: a cipher mismatch does not fail, it
produces well-formed nonsense, and on a write it would destroy the volume.

Argon2 is [vendored unmodified](../Core/crypto/argon2/README.md) from the
reference implementation (CC0/Apache-2.0). macOS ships nothing that can do it —
CommonCrypto has PBKDF2 and no more, and `libsodium` fixes Argon2 at one lane
while cryptsetup writes four by default.

### The trap worth knowing about

With a 4096-byte encryption sector, dm-crypt still counts the XTS tweak in
**512-byte units**. Get that wrong and sector 0 decrypts perfectly anyway — its
tweak is zero under either reading — so the superblock parses, the label is
right, the probe says `USABLE`, and every other byte on the volume is garbage.

It looks exactly like success. It cost an hour during the proof of concept and
then reappeared in the real implementation, where the run of sectors in a
single read advanced the tweak by one per sector instead of eight. The suite
now reads a 400 KB file from both a 4096-sector and a 512-sector volume, which
is the only thing that catches it.

### How it is tested

The oracle is never our own reader — a decryption bug that is *symmetric*, in
the same way in both directions, passes every test we could run against
ourselves. So:

- fixtures are built by **real cryptsetup**, in Docker
- what we decrypt is checked with `e2fsck` and `debugfs`, via
  `ext4dump ... decrypt`, which writes the plaintext payload out so that tools
  which know nothing about LUKS can inspect it
- what we **write** is handed back to `cryptsetup luksOpen` and the Linux
  kernel to read

AES-XTS itself is checked against known answers generated by OpenSSL rather
than transcribed from a specification: a hand-copied vector tests the
transcription, and a wrong one would "verify" the implementation against our
own mistake. `Tests/gen_xts_vectors.sh` regenerates them.

The JSON reader for LUKS2 metadata parses a structure an attacker chooses every
byte of, so it is tested on unterminated strings, mismatched brackets, control
bytes, nesting past its ceiling, and integers too large for 64 bits. It has no
recursion and the token budget is fixed by the caller.

### Encrypted volumes mount

An ext4 filesystem inside a LUKS container mounts, reads and writes through the
real driver, both formats:

```
/dev/disk6 on /tmp/ext4-mount-luks (ext4, local, nodev, nosuid, journaled,
                                    noowners, noatime, fskit, mounted by h3ct0r)
```

The decrypting layer is rebuilt inside the extension. `loadResource` opens the
container, finds a master key, then **throws the plain device away and builds
the stack again with the cipher in the middle** — because the device `init`
made addresses the container, header and key slots included, and everything
above has to address the payload instead. Its block count is the payload size,
not the container size: a filesystem told it has more blocks than exist
eventually writes past the end of the medium.

Verified end to end, in both directions, by real cryptsetup and the real Linux
kernel: `Tests/run_mount_luks_tests.sh`, 35 assertions, wired into
`make validate` as its own stage.

| | LUKS1 | LUKS2 |
|---|---|---|
| encryption sector | 512 B | 4096 B |
| KDF | PBKDF2 | argon2id, 1 GiB, t=12, 4 lanes |
| mount time | immediate | ~5 s per derivation |

The 4096-byte case reads a 400 KB file and compares it byte-for-byte, which is
the only thing that catches the IV-units trap on the mounted path — with a
4096-byte sector dm-crypt still counts the XTS tweak in 512-byte units, and
getting it wrong still decrypts sector 0, so the volume mounts and its label
reads correctly while everything else is garbage.

#### Where the key comes from

The extension cannot ask. It draws no UI, FSKit has no callback that delivers a
passphrase, and the sandbox refuses to open a path named on the mount command
line — all three measured. So the key has to be waiting before the mount
begins, and putting it there is the container app's job:

Plug one in and a menu-bar agent asks for the passphrase; after that the
volume mounts by itself, under its own name, for as long as the key is
remembered. The same thing without the GUI:

```
Ext4Mac unlock /dev/disk6      # prompts, derives, stores the master key
Ext4Mac mount /dev/disk6       # or just plug it in again
Ext4Mac forget <uuid|disk>     # locked again
Ext4Mac list                   # which volumes are unlocked, never the keys
```

The passphrase is typed into the app and never leaves it. What crosses over is
only the master key, which opens exactly one volume.

**Why the app and not the extension.** `loadResource` runs **twice per mount,
in two separate extension processes**, so deriving there costs argon2id twice —
about five seconds and a gigabyte each time. Deriving in the app costs it once,
and the mount that follows is instantaneous. (Argon2id at cryptsetup's defaults
*does* survive inside the sandboxed extension — measured, no jetsam kill — so
this is about arithmetic, not about whether it fits.)

**Two places a key can live**, tried in that order:

| | where | encrypted at rest | who can clear it |
|---|---|---|---|
| keychain | shared access group | yes | the app |
| container file | `…/Application Support/luks/<UUID>.key` | **no** | the app, or anyone with the user's account |

The keychain needs a provisioning profile for the *app's* bundle ID, since a
Developer ID binary that claims a keychain access group it cannot prove is
killed by AMFI the moment it launches — `Killed: 9`, no crash report, nothing
in the log. `scripts/sign.sh` therefore adds the entitlement only when
`App/Ext4Mac.provisionprofile` is present, and says which way it signed. See
`docs/SIGNING.md`. Without it everything still works; the key just sits in the
container in the clear, and the suite reports which of the two is in use.

Both halves are in place here, so `Ext4Mac unlock` puts the key in the
keychain and leaves nothing on disk — which the suite checks, because a
plaintext copy left behind would quietly outlive `forget`.

The container directory also accepts a `<UUID>.pass` file holding a passphrase,
which needs no app and no entitlement at all. That is what an unattended
machine can use, and what the test suite uses.

**The extension never creates keychain items — it only reads them.** When it
does derive a key from a passphrase file it caches it in the container, not the
keychain, even though it is entitled to write there. Ownership has to sit in
one place and it belongs with the app, because that is what a person reaches
for when they want a volume to stop being unlocked. A key cached somewhere the
app cannot delete is a key nothing can forget.

#### Two refusals, deliberately different

| situation | error | what `mount` prints |
|---|---|---|
| no key stored for this volume | `ENEEDAUTH` | Need authenticator |
| a key was found and does not open it | `EAUTH` | Authentication error |

Collapsing them would leave someone retyping a passphrase that was never going
to be consulted.

Both are raised from **`loadResource`**, and that placement is not a style
choice. FSKit activates the volume whatever the container status says, and it
calls neither `deactivate` nor `unloadResource` after `activate` throws — so
the resource stays registered to that extension instance, and every later probe
of the same media fails with *Resource busy*, through a detach and re-attach
both. A load that throws unwinds cleanly; a volume that refuses to activate
does not. The suite has a check for exactly that regression.

`FSContainerStateBlocked` was tried first and is **inert for a third-party
module**: it is documented as a state a password would resolve, with
`ENEEDAUTH` as the example, but setting it changes nothing — the load is
recorded as successful, nothing prompts anywhere in the system log, and FSKit
activates the volume anyway.

#### The trap that stays shut

Kernel-offloaded I/O must never be used for an encrypted volume: that path
hands the kernel physical extents to read for itself, below the cipher, so it
would return ciphertext — and that presents as filesystem corruption rather
than as a decryption bug. Every file reports `inhibitKernelOffloadedIO`, and
for an encrypted volume that is now a *condition* rather than a comment, so
finishing the blockmap work cannot quietly undo it.

#### The agent, and what plugging a disk in actually does

The app bundle is already `LSUIElement` — it exists to host the extension, not
to be looked at — so the agent is a status item and needed no manifest change,
which matters when Info.plist edits are what have deregistered this module
before.

It watches DiskArbitration. A volume whose name came from our probe is one of
ours; when a locked one appears and no key is stored, it asks, derives off the
main thread, and then asks DiskArbitration to mount. It asks **once** per
volume, and again if the disk is unplugged and returned — which is when someone
expects to be asked, and is not the same as asking every time a mount is
retried.

Launched with no arguments the binary decides between the agent and a status
report by looking at its parent process: LaunchServices reparents an app to
launchd, a shell does not. `isatty` was tried first and is wrong — it hands the
agent to any script that captures the output, and the agent never returns.
`scripts/check_extension.sh` hung on exactly that, and now asks for `status`
explicitly.

#### Two things only the DiskArbitration path revealed

`mount -F -t ext4` and Finder do not take the same route. DiskArbitration runs
an FSKit **check** before it mounts anything, and `mount(8)` does not — so two
bugs hid behind a working command line.

The check opened the device itself and probed it, which on a LUKS container
reads a header where a superblock should be: `NOT_EXT`, then `ENOTSUP`, and
DiskArbitration abandoned the mount. Every entry point that opens a device for
the *filesystem* now goes through the same unlock path, not just
`loadResource`.

Worse, FSKit **loads the resource before calling the check** — it says so in
its own log — so the check ran against a volume that was already mounted, with
its journal already attached. Opening a second independent view of that device
is not a check, it is a second writer: the journal looks unrecovered from
outside and replaying it under the live mount fails with `EINVAL`.
DiskArbitration then fell back to mounting **read-only**, which is a silent
downgrade that a command-line mount never showed. A volume that is already
mounted has answered the only question this check asks, so it now says so and
stops.

Reporting `EROFS` for a dirty journal on a read-only resource had the same
effect for the same reason. Refusing the *check* is not the same as refusing
the *volume*; the replay happens on the next read-write mount either way.

#### Still to do

Key material is zeroed on every path, but not `mlock`ed against swap.

Nothing tells you a volume is locked except that it does not appear. A
notification when the agent is not running would be kinder than silence.

## Metadata checksums

Every checksum ext4 defines is computed and verified: superblock, group
descriptors, inode, directory block, HTree node, extent block, block and inode
bitmaps, and the journal's own. lwext4 already had all of them.

What it did not have was the **seed**. Checksums are seeded with
`crc32c(~0, uuid)` — unless the volume carries `metadata_csum_seed`, which
freezes the seed into `s_checksum_seed` at creation so that `tune2fs -U` can
change the UUID afterwards without rewriting every checksum on the disk.
`mke2fs` enables that feature by default, so the derived and stored seeds agree
on a fresh filesystem and diverge the moment anyone changes the UUID.

lwext4 had no notion of the field — its superblock struct did not declare it —
and derived the seed from the UUID everywhere, in eight separate places. On a
volume whose UUID had been changed, *every* checksum it wrote was wrong:
`e2fsck` reports nine invalid group-descriptor and inode checksums after a
single `mkdir`. This driver used to avoid that by refusing write access to such
volumes.

`patches/lwext4/0012` declares the field, adds one `ext4_sb_csum_seed()` that
decides which seed applies, and routes all eight call sites through it. The
read-only downgrade is gone, and the write suite now writes a directory, a
file, an extended attribute and sixty more entries — enough to push the
directory into an HTree, whose checksums are a separate path — onto that
fixture and hands the result to `e2fsck`. Reverting the patch turns that check
red, which is the only reason to believe it.

## Finder could not copy files off an ext4 volume

`cp` worked. `ditto` and Finder did not, with *Input/output error*.

Between them, two bugs in the same call. macOS probes `com.apple.FinderInfo`
and `com.apple.ResourceFork` on essentially every file it copies, so
"this attribute is not set" is the most common extended-attribute answer a
driver gives — and this one was giving the wrong answer twice over.

**`EIO` for an inode that had never carried an attribute.** lwext4's
`ext4_xattr_is_ibody_valid()` folds "there is no header here" together with
"the header here is malformed" and reports `EIO` for both. The first is the
ordinary state of almost every file. Fixed by `patches/lwext4/0013`, which
separates them — absence is "not found", corruption is still `EIO`.

That error turned out to be **load-bearing**: `ext4_xattr_set()` used it as the
signal to initialise a header before writing the first attribute. Removing it
left the search context zeroed and the set path dereferenced NULL — a real
crash, found by the extension dying mid-copy on a live volume. It now asks
whether the header exists rather than inferring it from an error.

**`ENODATA` once the file did have a header.** That is Linux's name for the
condition, and lwext4 is right to use it. macOS calls it `ENOATTR` and gives
it a different number — 93 against 96. `getxattr(2)` on macOS never returns
`ENODATA`, so a caller switching on the errno falls through to its error path,
which is exactly what Finder does. Translated at the bridge, since lwext4 is
correct about Linux.

Both are covered in the write suite, and reverting 0013 turns the first red
with the original *Input/output error*.

## Write ordering is not enforced, and that is not theoretical

> **This section is history, kept because the measurements in it justify
> everything that came after — and it now has two endings.** As of
> 2026-08-27 write ordering *was* enforced: a privileged helper daemon
> (`ext4barrierd`) issued real `DKIOCSYNCHRONIZE` barriers, lwext4 patches
> 0014–0021 made the journal use them correctly, and the same abuse
> described below — kills and pulls on real USB — was measured clean.
> Then, on 2026-08-29, the question was remeasured as a five-drive A/B with
> the daemon as the control arm, and the unbarriered arm recovered exactly
> as cleanly as the barriered one — the hazard below is a property of the
> old cached write path, not the current direct one. **The daemon and the
> read-only policy are gone**; removable media mounts read-write like
> everything else. The full verdict is in
> [the retirement section](#the-barrier-daemon-is-retired-a-five-drive-verdict).

**The mounted driver was not crash-safe on removable media.** This was written
down as an assumption from the start; a real USB stick falsified it.

lwext4 issues journal barriers faithfully. Nothing enforces them.
`BlockDeviceBridge.flush()` returns success without doing anything, because
there is nothing for it to call: `metadataFlush` is the only write barrier in
the entire `FSResource` API, and it belongs to the metadata I/O family, which
does not work here.

### What the stick showed

A 16 GB ext4 USB stick, written to through a real mount, with the extension
killed twice while it was mounted. `e2fsck` afterwards:

```
Entry '.fseventsd' in / (2) has deleted/unused inode 15
Inode 2 ref count is 3, should be 5
Block bitmap differences:  -(9257--9259)
Inode bitmap differences:  -(15--16)
Directories count wrong for group #0 (7, counted=6)
```

Read together that is one thing: directory entries reached the medium while
the metadata that must accompany them did not. Root's link count is two too
low — two directories whose entries landed and whose parent-link-count update
did not. No file content was lost; every file checksummed identical before and
after.

Killing the process only loses writes still in flight. It cannot produce half
a committed transaction on a filesystem whose barriers work. The writes
reached the device out of the order they were issued in.

A disk image never shows this: writes reach it through the page cache and land
on APFS in issue order. A USB stick has its own write cache and reorders
freely. That is the difference between 303 green cut points and one pendrive.

### Why there is no barrier to use

The metadata family fails with `EIO` on every call — instantly, identically,
on a disk image and on physical media alike. Ruled out by measurement:

| Explanation | Ruled out by |
|---|---|
| block-size alignment | fails on a perfectly aligned one-block read at offset 0 |
| physical-sector alignment | `blockSize` and `physicalBlockSize` are both 512 here |
| buffer alignment | heap-, block- and page-aligned buffers all fail alike |
| request size or offset | six combinations, all fail |
| lifecycle | fails during probe, during load, and with the volume active |
| disk images only | fails identically on a physical USB stick |
| entitlements | Apple's `exfat` module has strictly *fewer* than this one |
| a missing manifest key | no FSKit key Apple's own modules declare is absent from ours |

Two measurements settle what it is not. A **plain `read` of the same offset
and length, into the same buffer, microseconds apart, succeeds** — so the
resource is fine and the request is well formed; the difference is the family.
And **`metadataFlush` fails too**, though it takes no buffer and no range at
all — so the family is gated as a whole rather than any call being malformed.
That also kills the obvious workaround of keeping direct writes and borrowing
just the flush.

Apple's own `msdos` module references the entire family — `metadataRead`,
`metadataWrite`, `delayedMetadataWrite`, `metadataFlush`,
`asynchronousMetadataFlush`. Its `exfat` module references none of it and
reads directly, exactly as this driver does. So the API demonstrably works in
production, and nothing observable from outside explains why it is closed
here. Nothing appears in fskitd's log or the kernel's, and every probe fails
within the same millisecond, so the call is refused before it reaches a
device.

### A barrier the API does not offer, through a descriptor it left behind

`metadataFlush` is closed. The medium is not.

FSKit performs the resource's I/O from inside the extension's own process, and
to do that it has to hold the device open. It does: **`/dev/rdiskN`, fd 3, in
our own descriptor table.** A descriptor is a capability and the sandbox check
happened when it was opened, so `ioctl(DKIOCSYNCHRONIZE)` on it is a question
the sandbox has no further opinion about. That is the barrier — the same call
HFS+ and APFS use, asking the drive to commit its volatile cache and not to
reorder across the point.

`Core/shim/device_barrier.c` tries three, most specific first:
`DKIOCSYNCHRONIZE` with `DK_SYNCHRONIZE_OPTION_BARRIER` (order, without
waiting — what a journal actually wants), then `DKIOCSYNCHRONIZECACHE`
(commit, and wait), then `F_FULLFSYNC` for a plain file. The descriptor is
found by path rather than by number, since nothing documents that it is fd 3
or that it exists at all, and a miss is reported as the correctness problem it
is rather than passed over.

The descriptor is real. The ioctls are refused:

| call | result |
|---|---|
| `DKIOCSYNCHRONIZE` (barrier) | `EPERM` |
| `DKIOCSYNCHRONIZECACHE` | `EPERM` |
| `F_FULLFSYNC` | `ENOTTY` — expected; it is the file-level call, and this is a character device |
| `DKIOCGETBLOCKSIZE` | **`EPERM`** |

That last row is the one that matters. `DKIOCGETBLOCKSIZE` is a pure getter
that every disk answers and that no device has grounds to refuse. Getting
`EPERM` from it means **no disk ioctl reaches this descriptor at all** — so
the barrier was never actually asked for. This is a permission boundary, not a
property of the medium, and it reads identically on a disk image and on a USB
stick.

Diagnosing this took one wrong turn worth recording. The first version tried
the three calls in order and returned the last one's `errno`, which is
`F_FULLFSYNC`'s `ENOTTY`. Reported as the verdict, that pointed the diagnosis
squarely at the medium — "this drive has no barrier" — while the ioctls
underneath had been saying `EPERM` the whole time. Each call reports its own
result now.

The kernel then named it. Turning on sandbox violation reporting while the
probe runs:

```
Sandbox: Ext4FS deny(1) file-ioctl path:/dev/rdiskN ioctl-command:(_IO "d" 22)
Sandbox: Ext4FS deny(1) file-ioctl path:/dev/rdiskN ioctl-command:(_IO "d" 24)
```

`_IO('d', 22)` is `DKIOCSYNCHRONIZECACHE` exactly; `'d', 24` is
`DKIOCGETBLOCKSIZE`. So this is not a guess about what `EPERM` implies — it is
the **App Sandbox's `file-ioctl` rule**, refusing the barrier by name. FSKit
hands us the descriptor and lets us read and write through it; what is denied
is the ioctl, not the access.

### The metadata family is not a sandbox denial

That made the entitlement worth testing, because Apple's two modules differ in
exactly one place. `msdos` uses the whole metadata family and carries
`com.apple.security.exception.iokit-user-client-class` for
`AppleLIFSUserClient`; `exfat` uses none of the family and carries no such
exception. Otherwise their entitlements are identical to this module's. The
family is documented as access to the Kernel Buffer Cache, and `lifs` is a
loaded kext — a good three-point fit.

It was tested and it is wrong. Signing with the third-party form,
`com.apple.security.temporary-exception.iokit-user-client-class`, changed
nothing: `metadataRead` still returns `EIO`, from a build verified to carry
the entitlement. More decisively, **`metadataRead` produces no sandbox
violation at all** — the log names every denied `file-ioctl` and says nothing
about an `iokit-open`. Whatever refuses the metadata family, it is not the
sandbox, so no entitlement will open it.

Two separate walls, then, not one:

| | what refuses it | evidence |
|---|---|---|
| `DKIOCSYNCHRONIZECACHE` | App Sandbox `file-ioctl` | denial logged by name and ioctl number |
| metadata I/O family | something inside FSKit or LiveFS | `EIO` with no violation logged anywhere |

The entitlement was reverted rather than left in: one that demonstrably does
nothing has no business in a signed binary.

What is left, in ascending order of unpleasantness:

- ~~**Widen the sandbox.**~~ Tested, and it does not work. The denial is a
  file rule, so the matching exception is
  `com.apple.security.temporary-exception.files.absolute-path.read-write`.
  Signed with `/dev/` — the only form that could cover a device node whose
  name is not known until mount time — the denial comes back **byte for byte
  identical**, same operation, same ioctl numbers. A file-path exception
  grants `file-read` and `file-write`; it does not grant `file-ioctl`, and
  there is no public entitlement that does. Reverted immediately: it was a
  diagnostic, and shipping read-write access to every device node on the
  machine in exchange for nothing would have been a poor trade even if it had
  worked.
- **A privileged helper** holding the device open and issuing the barrier over
  XPC — **this is what shipped**, for a while. No widening of the extension's
  sandbox, since the helper does the ioctl. It cost a root daemon, an XPC
  round trip per transaction, a manual Full Disk Access grant no installer
  can automate — and, once, a trust-boundary bug: the caller check passed
  static-validation flags to `SecCodeCheckValidity`, which refuses them
  (-67070), so the daemon refused every caller and nothing noticed until a
  physical stick asked. It was retired on 2026-08-29 by the remeasurement
  below; `sudo make uninstall-barrier` removes an installed copy.

### Two ordering holes remain above it

A barrier is a primitive, not a fix. Two things still have to use it.

**lwext4 cannot ask for one.** `struct ext4_blockdev_iface` has `open`,
`bread`, `bwrite`, `close`, `lock`, `unlock` — and no flush. Every "flush" in
`ext4_journal.c` writes buffers out of lwext4's own cache; none of them reaches
the device. So the journal cannot request a barrier between writing a
transaction and writing the commit block that vouches for it, which is the one
place it matters most. The bridge's `flush_fn` is called at the bridge's own
boundaries — `txn_finish`, `ext4b_sync`, unmount — so a barrier there separates
one transaction from the next, but not a transaction from its own commit block.
Closing that needs a patch adding the hook and calling it in
`__jbd_journal_commit_trans`, on both sides of `jbd_trans_write_commit_block`.
Journal blocks carry `BC_TMP` and are written through immediately on release,
so at those two points everything before has been issued and the barrier lands
where it should.

**Cache pressure can checkpoint before commit.** `ext4_block_cache_shake`
evicts the least-recently-used dirty buffer whenever the cache is full, with no
regard for whether the transaction that owns it has committed. That is a
checkpoint write issued ahead of its commit block, and no barrier can un-issue
it — the buffers have to be pinned until their transaction commits.

### What the reproducer says

`ext4dump script <file>` runs many mutations inside one mount, which is the
shape the driver has and the shape nothing else tested: every other path
through the tool mounts, does one operation and unmounts, checkpointing the
journal each time. So the 303-cut-point sweep, thorough as it is, has only ever
tested a filesystem with a single transaction in flight.

Cutting the write stream of a 1,200-operation script at points spread across
its whole length:

| target | after journal replay |
|---|---|
| 64 MB image | 31 of 31 clean |
| 31 GB image | 11 of 11 clean |

Same geometry as the stick that fails, same workload, same cut. **Volume size
is not the variable, and the journal and its recovery are correct at this
layer.** What that leaves is the layer `ext4dump` does not have: the mounted
FSKit path, on physical media.

### Concurrent core entry is now measured, not assumed

lwext4 has no internal locking, and the transaction in flight lives in a single
shared field — `fs->curr_trans`. A second thread entering `txn_begin` does not
get its own transaction; it silently joins the first thread's, and whichever
finishes first commits a half-built transaction on the other's behalf. The
Swift side serialises everything through `Ext4Executor`, but that discipline is
a convention spread across a dozen files held up by comments, and it has been
broken once already — found by a hang, not by a check.

The bridge now watches both scales: block I/O, where two threads overlap inside
a single read or write, and transactions, where they need not overlap in time
at all. It reports rather than blocks, since a detector that changes the timing
it is trying to observe is worth less than one that does not, and the count is
logged at every unmount. Eight concurrent writers against a mounted image
report **no concurrent entry** — so the discipline holds on that path, and any
future value above zero is a bug rather than a statistic.

### What this means in practice

**Eject before unplugging**, which flushes and closes the journal cleanly.
Not because of the driver — the sweep below could not hurt it — but because
the last seconds of unsynced writes are only as durable as on any
filesystem, and because a mid-write pull can panic macOS itself: xnu's 60 s
busy-timeout watchdog fires when a drive's bridge chip hangs its in-flight
commands on surprise removal and the media object cannot finish terminating
(`busy timeout ... 'IOMediaBSDClient'`, panicked task `watchdogd`; observed
once during the sweep). That lives in Apple's storage stack, below anything
a filesystem can reach.

### The barrier daemon is retired: a five-drive verdict

The write-ordering hazard above was measured on the driver's earliest write
path, which buffered in the host. The current path hands every write
synchronously to the device through FSKit's raw descriptor — the only cache
left between the journal and the medium is the drive's own. Whether *that*
cache reorders enough to hurt is a question for hardware, so it was put to
hardware: `Tests/run_pull_tests.sh` formats a stick, runs a
rename-heavy load with sha256 manifests and `sync` fences (or, `HARSH=1`,
sustained 1–2 MB writes with no fences at all), has the operator physically
pull the stick mid-write, and autopsies the reinserted corpse — `e2fsck` on
a dd image for consistency, `debugfs rdump` against the manifest for
durability.

Twenty pulls, five drives, two of them run first as an A/B against the
daemon's real barriers:

| drive | media class | rounds (fenced + harsh) | e2fsck | synced files lost |
|---|---|---|---|---|
| DataTraveler 3.0, 15 GB | physicallyDetachable | 2 + 2 | clean | 0 |
| DataTraveler 3.0, 31 GB | physicallyDetachable | 2 + 2 | clean | 0 |
| Flash Drive FIT, 128 GB | physicallyDetachable | 2 + 2 | clean | 0 |
| DataTraveler Max, 256 GB | fixed (self-reported) | 2 + 2 | clean | 0 |
| RTL9210 NVMe enclosure, 1 TB | fixed (self-reported) | 2 + 2 | clean | 0 |

Every round replayed its journal on remount (verified in the logs — these
were genuine mid-transaction interruptions) and recovered to a filesystem
`e2fsck -fn` found nothing wrong with; `e2fsck -fy` on a clone had zero
repairs to make; ~7,500 sync-fenced files verified bit-for-bit.

Two findings beyond the zeros made the decision:

- **The policy never covered the drives most likely to cache.** Large
  sticks, USB SSDs and enclosures report *fixed, non-ejectable* media on the
  USB bus, so the removability-keyed policy classed them exempt and they
  wrote unbarriered all along — including the NVMe enclosure, the one device
  here with real DRAM behind the bridge. The daemon guarded exactly the
  subset of drives that the measurement says do not need it, and could not
  be extended to the rest without making every external SSD read-only.
- **The worst outcome was never reachable by a daemon.** The one casualty of
  the sweep was the kernel panic above, in Apple's stack, on the teardown
  path — barriers have no say there.

So the daemon, its LaunchDaemon plist, the `BarrierClient`, the
removable-write policy and its marker are gone; `BlockDeviceBridge.flush()`
is a documented no-op again, and the harness stays in the tree as the
regression instrument — if a future change to the write path re-widens the
reorder window, the pull test is the thing that can say so.

### It is the medium, and that is now a controlled result

Two mechanisms could produce the damage, and they have opposite fixes: the
device reordered the writes, or dirty metadata never left lwext4's cache. The
second is fixable here; the first is not.

`Tests/run_kill_recovery_tests.sh` settles it. It kills the extension outright
in the middle of a metadata-heavy workload — directories, inodes, blocks, link
counts and an extended attribute apiece — then lets the driver replay its own
journal on the next mount and hands the result to `e2fsck`. That is precisely
what happened to the stick, twice.

| target | after journal replay |
|---|---|
| 64 MB disk image | **5 of 5 clean** |
| 31 GB USB stick | **5 of 5 damaged** |

Each round is independent: the volume is repaired with `e2fsck -fy` between
rounds and each round's directory carries the run's PID, so damage is always
attributable to the round that caused it. An earlier version checked with
`-fn`, which repairs nothing, and every round after the first re-reported the
first one's wreckage — one data point wearing five results. Worth knowing when
reading any suite that checks without repairing.

Same driver, same workload, same kill, same journal code. The only variable is
what the writes land on, and the failure is deterministic rather than a race —
five rounds, five failures, on demand.

The damage takes more than one shape. Usually a round's directory entry exists
while the inode it names was never written; once it was *multiply-claimed
blocks in two inodes*, which is block-allocation metadata landing out of order
rather than inode writes. Different surfaces of the same cause. The journal machinery and its recovery are correct —
five rounds of arbitrary process death recover perfectly — and what fails is
the medium preserving the order that recovery depends on. An image reaches
APFS through the page cache in issue order; a USB stick has its own write
cache and reorders freely.

The suite runs on an image in `make validate`, where it proves recovery works.
Pointed at real media with `EXT4_KILL_DEVICE=diskN` — which erases it — it
becomes the detector for the barrier this driver does not have, and the way to
tell whether any future fix actually worked.

### Journal transactions are batched, and what that changed

Every mutation used to commit its own journal transaction before returning.
That made metadata durable the instant a call returned — a guarantee **stronger
than Linux ext4, HFS+ or APFS**, none of which promise anything of the sort;
`fsync` is what that is for. It also cost two write barriers per operation,
because jbd barriers either side of the commit block and a barrier is an XPC
round trip to the privileged helper plus a real `DKIOCSYNCHRONIZE`.

Up to 16 mutations now share a transaction, which commits when the batch fills,
when `sync` arrives, or at unmount.

| | per-operation | batched |
|---|---|---|
| 400 small files | 14.3s | **1.30s** |
| 256 MB sequential write | 31.4 MB/s | **62.7 MB/s** |

Eleven times faster on metadata-heavy work, and 15× against where the day
started. What it costs is stated rather than buried:

- **An operation is not on the medium when the call returns.** It is durable
  once something asks — `sync(2)`, the batch filling, or unmount. This is the
  ordinary contract for a journalling filesystem.
- **A failed operation batched with others can leave partial changes.** Alone
  in its transaction it still rolls back completely, and almost every error
  path returns before touching anything; but aborting a shared transaction
  would discard work that succeeded, so a failure with siblings commits the
  batch and returns the error.

**Verified on real hardware** (Kingston DataTraveler, USB): five rounds of
kill-recovery with genuine e2fsck verdicts, all clean; a physical mid-write
pull — 3,750 files into a write flood — replayed to a volume e2fsck passes
untouched; the write barrier observed live on the device through the
privileged helper; and the durability window measured directly — a file
written with no sync survived a SIGKILL minutes later, so macOS's periodic
sync drains idle batches and no timer is needed. The pull also found patch
0021's bug: unmount asserting on I/O errors from a device that is gone.

One issue is Apple's, documented rather than fixed: after repeated
kill/pull abuse, DiskArbitration can wedge — the module mounts, activates,
and is deactivated 2 ms later with DA status 0x204, while direct
`mount -F` works perfectly. A replug sometimes clears it; SIP forbids
kicking the daemons; a reboot resets it. First-run guidance should say: if
the volume stops appearing, unplug and reinsert, then reboot before
suspecting the driver.

Crash consistency under batching has a history worth keeping. The first
version of this feature shipped, was caught corrupting volumes under write
reordering the same afternoon, and was turned off. The mechanism was not
batching itself: lwext4 wrote the journal's tail pointer on every checkpoint
completion with no barrier, and batching merely made the log wrap inside a
test run — which is what let anyone see it. Patches 0017–0020 fixed the
journal's ordering protocol (recoverable-by-Linux tag checksums, parseable
revoke counts, revoke-on-free, a lazily advanced tail written durably where
reuse makes it matter), and batching came back on top of a journal that
earns it: 236 torn images across geometries × workloads × batch sizes, every
one recovered by the Linux kernel, with the negative controls still failing.
The mounted suite asserts both halves — a synced operation survives a cut,
and an **unsynced** batch still leaves a volume the kernel mounts and
recovers. Losing recent work is the deal; taking the filesystem with it would
not have been.

`EXT4B_TXN_BATCH=1` restores the old behaviour exactly, which is how the two
columns above were measured.

### `startCheck` checks something now

It used to verify nothing. The intent was a mountability check, and the guard
was "if the volume is already mounted, it is mountable, so return" — but FSKit
loads the resource *before* calling check, so every volume reaching it is
mounted and the early return was the only path ever taken. `fsck_fskit -t ext4`
printed a note about itself and exited 0.

`ext4b_check_tree` (`Core/shim/ext4_check.c`) walks the directory tree through
the **existing** handle — safe in a way opening a second one is not, since it
only reads, and reads what the live mount would read — and cross-checks the
answers against each other:

| what | catches |
|---|---|
| a directory's link count against its subdirectory count | `Inode 2 ref count is 12, should be 13` |
| every entry against the inode it names | `Entry '…' has deleted/unused inode 13` |
| the entry's cached type against the inode's | `Entry '…' has an incorrect filetype` |
| a directory reachable twice | loops, and hard-linked directories |

Those are not hypothetical: every failure the kill-recovery suite reported
against real hardware was one of them, and none of them prevents a volume from
mounting.

It is not `e2fsck` and says so on every run, including clean ones — blocks
claimed twice, free counts that disagree with the bitmaps, and inodes with no
directory entry at all are invisible to a tree walk, and a check that reports
"no problems" without qualifying what it looked at invites the reader to
conclude more than it found.

Also available offline as `ext4dump check`, which is what makes it testable:
the write suite asserts both that a healthy volume reports zero problems **and**
that a corrupted link count is detected and named.

### Access checks answer before the operation, not after

`FSVolume.AccessCheckOperations` is implemented. The driver already refused a
write to an immutable file, but it refused it *at the write*, so `access(2)`
had nothing to consult and answered yes — `[ -w frozen.txt ]` said writable on
a `chattr +i` file, and Finder would offer to edit a locked file and discover
otherwise only on save.

Ownership is deliberately not checked. These volumes mount `noowners`, which
macOS applies to foreign and removable media because a uid written on someone
else's Linux box means nothing here; VFS presents every file as owned by the
mounting user and disregards the mode bits. Re-imposing ext4's uid, gid and
mode on top would contradict the mount options the volume is actually mounted
with, and would lock a user out of their own disk on the strength of a number
that happens to match a different machine's account. So the check answers only
for what is true regardless of who is asking: the volume being read-only, and
the two inode flags this driver enforces.

One trap, and it is the same one that made the `device` accessor fallible.
FSKit asks this **after `unmount` has closed the volume**. Throwing there does
not merely fail the check — it fails the *unmount*, and the volume stays
mounted. The symptom is a busy mount with nothing anywhere mentioning access,
and it cost 24 of 24 freeze/resume cycles in the mounted suite to surface. A
closing volume is not the place to enforce a flag: it answers yes and lets VFS
deal with it, and the write paths refuse independently in any case.

### Kernel-offloaded I/O silently discards writes

The read half of `FSVolumeKernelOffloadedIOOperations` has been written and
switched off for a long time, on the grounds that conforming makes FSKit route
*writes* through `blockmapFile` even for files reporting
`inhibitKernelOffloadedIO`. That was measured rather than inherited, since
`FSSupportsKernelOffloadedIO` is already `<true/>` in the manifest and the
experiment therefore needs no change to it — the one kind of change that has
deregistered this module before.

The claim holds, and the failure is worse than the note suggested. With the
conformance in the build, `blockmapFile` throws `notSupported` for a write and
FSKit turns that into **nothing at all**:

```
$ dd if=/dev/zero of=/Volumes/ext4/probe.bin bs=1m count=16
0+0 records out
0 bytes transferred in 0.001831 secs (0 bytes/sec)
```

No error to `dd`, no error in the log, a zero-byte file. Silent data loss, not
a refusal. So the conformance stays out until the write blockmap exists, and
the reason is now a measurement.

It also produced a good lesson about benchmarks. The throughput suite reported
**2844 MB/s** for that run, because it timed a `dd` that did nothing and divided
by a duration close to zero. Every measurement in `Tests/run_throughput_tests.sh`
now checks the work actually happened before it will print a rate: a benchmark
that cannot verify its own work is not a benchmark.

### One barrier in three was redundant

Patch 0014 has jbd issue barriers on both sides of the commit block, and
`txn_finish` issued a third afterwards. On a journalled volume that one buys
nothing: once the commit block is on the medium the transaction is durable,
because a crash replays it, whether or not the metadata has reached its home
location yet. It was costing a third of every mutation — a barrier is an XPC
round trip to the privileged helper plus a real `DKIOCSYNCHRONIZE`.

| | before | after |
|---|---|---|
| 400 small files | 20.0s | **14.3s** |
| 256 MB sequential write | 21.6 MB/s | **31.4 MB/s** |

It stays for volumes without a journal, where there is no commit block and
nothing to replay, so that barrier is the only thing making the change durable.

The remaining cost is structural rather than wasteful: this driver opens a
journal transaction per filesystem operation, so a file creation pays two
barriers. Linux ext4 batches hundreds of operations into one commit every few
seconds and pays two barriers for all of them. Batching is the next real
performance work, and it is a change to durability semantics, not a tuning
knob.

### Two ordering defects that turned out not to exist

Both were predicted by reading the code, and the instrument above refuted both.
Worth recording so they are not predicted again.

**`ext4_block_cache_shake` does not checkpoint before commit.** It evicts the
least-recently-used dirty buffer whenever the cache fills, with no visible
regard for whether the transaction owning that buffer has committed — which
reads like a checkpoint write issued ahead of its own commit block, and no
barrier can un-issue one. It cannot happen. `jbd_trans_set_block_dirty` calls
`ext4_bcache_inc_ref` on every journaled buffer and holds that reference until
the transaction commits, and `ext4_bcache_free` only inserts a buffer into the
LRU once its reference count reaches zero. `shake` walks the LRU, so a
journaled buffer is not reachable from it. Measured as well as argued: the
reorder suite is clean at every cut point with the block cache cut from 1024
entries to 8, which is as much eviction pressure as the code can be given.

**Journal checksums are on** — and the table this section used to carry, in
which enabling them corrupted every reordered cut and the kernel refused the
result outright, was three lwext4 bugs wearing one trenchcoat: the commit
checksum written host-order (patch 0015), the tag checksums seeded with a
host-order sequence number (0017), and revoke counts that fabricated a
phantom entry under checksums (0018). All fixed, all kernel-verified; `mkfs`
sets `JBD_FEATURE_INCOMPAT_CSUM_V3` (0016) and every torn image in the
reorder matrix replays clean through the Linux kernel. A checksummed journal
is the only defence against a drive that reports a cache flush and does not
perform one, and it costs nothing measurable.

**metadata_csum is on at format time too** (patch 0024). `mkfs` used to strip
it under an upstream *"TODO: handle this features some day"*; the some day
turned out to need three targeted fixes — self-checksumming superblock
copies, backup descriptor tables checksummed at build time, the frozen
`s_checksum_seed` — because everything else mkfs writes already flows
through the runtime code that maintains checksums on a mounted volume. The
format suite's geometry sweep now e2fsck-verifies every checksum across
thirteen sizes × three block sizes × three generations.

## Not yet done
- A notification when a locked volume appears and the agent is not running;
  today it simply does not show up
- Reading a LUKS header from media the user does not own — untested against a
  physical stick, where `/dev/diskN` may be `root:operator`
- LUKS detached headers, and ciphers other than `aes-xts-plain64`
- Kernel-offloaded I/O, for reads as well as writes: the conformance is out
  of the build entirely, so *all* I/O is byte-copy today

## Preallocation

`fcntl(F_PREALLOCATE)` asks for blocks without content, and ext4 answers it
with **unwritten extents**: allocated, marked as not-yet-written, and read
back as zeroes without anyone having written zeroes. lwext4 could *read*
unwritten extents — `ext4_fs_get_inode_dblk_idx` returns a hole for them —
but exposed no way to create one. Patch 0025 adds the writer:
`ext4_extent_preallocate` inserts extents already carrying the unwritten
bit, and the existing split/convert machinery (which upstream shipped but
nothing could reach) turns exactly the written part initialised when data
lands, zeroing any remainder of a partially-converted extent.

The FSKit side is `FSVolume.PreallocateOperations`. macOS always extends
from end-of-allocation — the SDK says to ignore the offset — so the bridge
allocates from `max(size, alloc_size)` and never touches `i_size`; `getattr`
reports the allocation separately and Finder's sizes stay honest. A
preallocation that was not flagged `.persist` is released when FSKit
deactivates the item (`.forPreallocatedItems`), which is the same
space-lives-until-close contract HFS+ and APFS honour.

There are exactly three ways this feature corrupts data, and the suite
(`Tests/run_prealloc_tests.sh`, stage 4b of validation) tests each one by
name. *Disclosure*: write a secret, delete it, preallocate into the freed
blocks, extend the file over them — the read must be all zeroes, never the
secret. *State merge*: a written and an unwritten extent must refuse to
merge (both merge predicates now compare the bit), or one extent lies about
half its blocks. *The leak*: truncate and unlink must free blocks the file's
size never admitted to — e2fsck's block-usage count is asserted identical
before and after. The conversion path also stopped pushing zero-fill through
the journalled cache: zeroing goes direct to disk with an explicit cache
invalidate, so data blocks stay out of the journal.

The oracles are the usual ones: debugfs's `[u]` markers confirm our extents
command, e2fsck accepts blocks past EOF, and the Linux kernel replays every
crash cut of a prealloc/write/truncate/rm history — 21 cuts, none dirty,
none refused. Against the mounted driver, `F_PREALLOCATE` for 4 MiB returns
`fst_bytesalloc=4194304` with the size still 0, the write into it reads
back, and after unmount the deactivation trim has released exactly the
unwritten tail.

One deliberate crudity remains: blocks are allocated one at a time, so a
large preallocation is physically contiguous but recorded as a run of
single-block extents (256 MiB preallocates in about a second regardless).
Teaching the balloc layer to hand out runs would collapse those into a few
extents; that is a planned lwext4 improvement, not a correctness issue.

## Journal replay speed

A real-hardware incident (2026-08-29): a LUKS2+ext4 stick unplugged mid-write
took **over eight minutes** to replay its journal on the next mount, and
DiskArbitration abandons a mount after about twenty seconds (`0x3C`
`ETIMEDOUT`) — so the volume simply never appeared, with a healthy driver
grinding away invisibly behind it. A `sample` of the wedged extension told the
whole story: `jbd_iterate_log → jbd_replay_block_tags` issuing one 4 KiB
`pread` per journal block through the LUKS layer, and 43% of samples inside
`ext4_bcache_free → ext4_block_flush_buf` writing replayed blocks back one
flush at a time. Nearly every sampled instruction was a syscall in flight:
replay was priced entirely in device commands, and a USB stick charges a
fixed setup cost per command.

Patches 0027–0029 restructure recovery around that fact:

* **0027** — the recovery pass reads the log through a 1 MiB read-ahead
  window, one device command per physically-contiguous run. Replay is the one
  reader that knows its access pattern is a strictly forward sweep.
* **0028** — replayed blocks collect in a 4 MiB batch and flush sorted,
  deduplicated (newest copy per block — the state sequential replay ends
  with), and coalesced into one command per contiguous run. A hot metadata
  block logged in two hundred transactions is written once per batch, not two
  hundred times. Replay write errors now fail `jbd_recover` instead of
  vanishing inside a `void` callback with the journal cleared regardless.
* **0029** — a log the scan pass saw no revoke blocks in skips the revoke
  pass, which otherwise re-reads every header block to build an empty tree.
  The common case for removable media: files copied on, nothing deleted.

The red-first test is `Tests/run_replay_speed_tests.sh` (`make
test-replay-speed`). It rebuilds the incident — LUKS2 container, `mkfs.ext4
-J size=128`, our driver killed with `SIGKILL` mid-load, ~1700 transactions
left unreplayed — and prices recovery like the medium that produced it:
ext4dump's media model charges 500 µs per device command plus 40 MB/s of
transfer (`EXT4DUMP_IO_LATENCY_US` / `EXT4DUMP_IO_BW_MBS`), with
`EXT4DUMP_IO_STATS` counting commands so the access-pattern claim is asserted
without timing flakiness. Before the patches that fixture cost **43,038 reads
+ 29,464 writes = 72,502 device commands, 44 s modelled — timeout**. After:
**~6,900 reads + ~4,100 writes, 14 s modelled — mounts**. On a revoke-free
journal, 7,451 commands. Replay correctness is checked the way every other
suite checks it: `e2fsck -fn` over the decrypted payload, files created
before the kill still present, and the full battery (image crash sweep at 274
cut points, reorder, revoke, orphan, LUKS, ASan) green on the patched tree.

Two questions the incident raised, answered:

*Can the mount path report progress?* No. FSKit's `loadResource` reply is
all-or-nothing and DiskArbitration exposes no way for an extension to extend
or feed its timeout. The fix has to be speed, not communication.

*Should recovery be bounded against the ~20 s budget?* Deliberately not.
Replay is now bounded by media **bandwidth** (the physical floor — the dirty
span must be read once) instead of command latency; a 128 MiB journal fits
the budget with margin on an ordinary stick, and ~256 MiB fits on anything
USB3. A maximal journal on a very slow stick can still exceed 20 s, but
every alternative bound is worse: mounting read-only without replay serves
stale, torn metadata; replaying after mount shows the same; and refusing the
mount is what the timeout already does. Replay is idempotent, so a mount DA
abandons leaves the journal intact and the next attempt starts clean — with
batches landing as they fill, a retry also redoes no *durable* harm. If the
pathological tail ever matters in practice, the next step is checkpointed
replay (advance the durable log tail after each flushed batch, behind a
barrier), so consecutive attempts make forward progress; jbd2 does not do
this either, and it is not worth the risk until a real journal needs it.

## The pre-hardware hardening pass

After the replay incident, a systematic audit (2026-08-29) swept the tree
for the incident's three ingredient classes — per-command access patterns
on paths with OS timeouts, errors swallowed on their way up, and coverage
the offline suites could not express — and a phased fix landed before the
next hardware day. The principle: a hardware iteration is only spent
confirming what the desk already predicts, never discovering.

**The harness learned to fail like real media.** ext4dump gained EIO
injection (`EXT4DUMP_EIO_READ_AT`/`WRITE_AT`, sticky mode, and the
bad-sector model `EXT4DUMP_EIO_*_OFF` — every I/O covering one offset
fails, which ordinal injection cannot express because the cache
legitimately retries), flush counting in IOSTATS, and reads in the trace.
`Tests/run_eio_tests.sh` (validation stage 5b) holds the cells; every one
asserts the fault fired *and* the failure surfaced.

**Errors now leave as errors.** The audit found the replay bug's shape in a
dozen places; all are fixed red-first. In the bridge: orphan cleanup no
longer guesses "in use" over an unreadable bitmap (the guess routed a read
error into truncate-and-free — a measured double-free); partial reads no
longer pose as EOF; fsync and unmount no longer return 0 over failed
write-back; short FSKit I/O throws. In lwext4 (patches 0030–0034): replay,
checkpointing and stop keep the journal covering anything that failed to
land — the tail freezes at an errored transaction, stop refuses to clear
what it could not flush, the cache latches the write-back errors
`ext4_bcache_free` used to swallow, and mkfs propagates its teardown. The
headline red test: forty files onto a bad sector used to exit 0 with
needs_recovery cleared and every inode gone; now the journal is kept and
the next mount hands all forty back, e2fsck-clean.

**A corrupt or dying stick cannot crash the driver** (patches 0035–0039):
journal geometry is validated at the door (a corrupt blocksize was an
out-of-bounds *write* on every recovery), revoke counts are bounded (an
underflow walked ~2^30 fabricated entries), a zero rec_len is EIO instead
of a wedged executor, and five asserts that fired on plain I/O errors
return errors instead. The fixtures for those cells found a latent upstream
use-after-free in checkpoint completion (0039) that crashed the *shipped*
build on a 4 MiB mke2fs journal wrapping under a power-cut load — exactly
the small-journal foreign-formatted stick a hardware day would meet.

**The remaining timeout paths batch** (0040–0041): inode tables zero in
1 MiB runs (2 GB format: 8,300 → 105 write commands; a dirty
lazy_itable_init volume's recovery mount: ~7,000 → 77 — that walk runs
inside DiskArbitration's budget), and checkpoints ride the replay
machinery from 0027/0028, which also fixed a latent escaped-block bug.
Recovery now reports its shape (0042): `journal replayed: N
transaction(s), M block(s), log L blocks, in T ms` in os_log — the line
whose absence made the incident cost days. Measured for scale: 500
orphans reclaim in 389 commands and 309 ms, so orphan cleanup needed no
change (the audit's estimate had assumed unjournaled head writes).

**The gates close the loop.** `scripts/preflight.sh` is the one hardware
gate (real-mount check, CDHash freshness — strict, "could not verify" now
fails), every hardware suite calls it, kill-recovery times its remounts
against the ~20 s budget including a new deep-journal round, and
`docs/HARDWARE.md` is the runbook: the ladder, the log lines each rung
should print, evidence-before-retry, and the full knob reference.

**And the first mounted run caught the pass's own regression** (0043).
The re-run of the mounted suites — the P0 exit gate — ended with e2fsck
counting one more subdirectory than the root inode's link count on a
cleanly unmounted LUKS2 volume. The autopsy: 0041's checkpoint batcher
inherited the replay batch's cache-sync, which is correct in recovery
(the log outranks any resident) and inverted at checkpoint time —
flushing an older transaction synced its stale logged copy over a newer
transaction's dirty resident, so every hot metadata block could land one
transaction stale under a green unmount, and later commits journaled the
clobbered bytes (the mount-crash suite's intermittent "durable once
synced" failures were this same bug seen through a crash). Reproduced
offline in four mkdirs (`EXT4B_TXN_BATCH=1` — one transaction each, all
sharing one inode-table block), fixed by one rule (a checkpoint's
cache-sync leaves dirty residents alone), and guarded in the write suite
("a checkpointed hot block keeps its newest copy"). A reminder of why
the exit gate exists: the offline suites all passed because eager
release-time flushing usually empties the checkpoint queue before two
transactions can share a block — the mounted driver, with fseventsd
committing around it, is what stacked the queue.

**And the second one, which the first one's fix had introduced** (0044).
With the checkpoint regression gone, the mounted kill-recovery suite still
failed five of twelve rounds -- but the Linux kernel replayed the same
crashed images to the same inconsistent filesystem, which said the fault
was not in recovery at all. The driver's log showed the real one:
hundreds of `no space left on device` on a fresh 64 MB volume. Patch
0041's completion drain lifts a transaction off the checkpoint queue, so
no completion advances the journal tail; the tail advance was left to the
purge loop, and the purge the allocator calls when the ring is full
flushed a transaction and returned without retiring it. The ring never
drained. Measured: 273 of 1800 operations refused with the volume 17%
full, where the pre-session build -- rebuilt from the patch series and run
on the identical fixture -- completes all 1800. A driver that cannot
allocate log space also stops checkpointing, which is why the crashed
images were beyond redo. 0044 makes the purge re-inspect after flushing;
kill-recovery went from 7/12 to 12/12.

Two harness gaps let this reach hardware, both now closed: `ext4dump
script` stopped at the first failing command, so nothing offline modelled
an application that keeps writing to a volume that has started refusing
(`EXT4DUMP_SCRIPT_CONTINUE=1`), and the kill-recovery suite accepted
read-only mounts, which after a kill replay nothing -- a round that
measured nothing while still reporting a verdict.
