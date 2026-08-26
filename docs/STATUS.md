# Status

| Phase | State |
|---|---|
| 0 — pipeline & packaging | **complete — signed, installed, loads** |
| 1 — read-only ext2/3/4 | **complete; 41 tests green** |
| 2 — kernel-offloaded I/O | **disabled** — see below |
| 3 — write path | **complete and working on real mounts** |
| 4 — correctness harness | **complete: image, crash-consistency, differential-vs-Linux, and mounted-driver** |
| 5 — polish & distribution | **format implemented**; check is a mountability check only; no DMG yet |

## What works today

```bash
make          # builds Ext4Mac.app with the FSKit extension inside
make test     # 41 assertions against real ext2/3/4 images
```

The whole project builds with the **Command Line Tools** — full Xcode is not
required.

**Core (verified):** probe and feature gating; mount and statfs; inode
attributes, hard links and symlinks; directory enumeration including
HTree-indexed directories; file reads across 1 KiB and 4 KiB block sizes on
both ext2 indirect-block and ext4 extent layouts; logical→physical extent
mapping; extended attributes. Every content read is compared byte-for-byte
against `debugfs`, and every fixture is checked with `e2fsck`.

**Extension (builds, not yet loadable):** the full FSKit surface —
`FSUnaryFileSystem` probe/load/unload, `FSVolume.Operations`,
`FSVolumeKernelOffloadedIOOperations`, `FSVolume.ReadWriteOperations`,
`FSVolume.XattrOperations` — plus Info.plist, entitlements and bundle layout
matching what shipping FSKit modules use.

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

- **Mount options do not reach the module.** FSKit's `mount(options:)` states
  "there are no defined options currently", and `taskOptions` arrives empty for
  `-o rw`, `-o ro` and `-r` alike. The volume therefore mounts read-write when
  the probe says that is safe and read-only otherwise; a user-supplied
  preference is not expressible.

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

**Writes are not opt-in, because they cannot be.** The intent was to mount
read-only unless the user passed `-o rw`. FSKit gives the module no way to see
that: `taskOptions` arrives empty for `-o rw`, `-o ro` and `-r` alike, and the
header states there are no defined mount options. A volume therefore mounts
read-write whenever the probe rates it safe, and read-only otherwise —
unsupported features, a dirty journal, or a `metadata_csum_seed` that no longer
matches the UUID all force read-only.

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
make validate           # all seven stages, unattended
make validate-asan      # the same under AddressSanitizer + UBSan
make test-format        # stage 3 on its own
make test-orphan        # stage 4 on its own
make test-mount-crash   # stage 7 on its own
```

| Stage | What it proves |
|---|---|
| read suite | 41 assertions, content verified byte-for-byte against `debugfs` |
| write suite | 101 assertions, `e2fsck` after **every** mutating operation |
| format | 29 assertions; 117 size/block-size/generation combinations must be `e2fsck`-clean, and the volume must round-trip through the Linux kernel |
| open-unlink recovery | 23 assertions; every cut point of a deferred delete recovers by *mounting*, and the orphan lists we write are cleaned up by `e2fsck` and by the Linux kernel |
| crash consistency | 303 cut points across 14 operations; the write stream is severed at every point, the **real Linux kernel** replays the journal, and `e2fsck` must be clean |
| differential vs Linux | 36 assertions; volumes round-trip between our driver and the real Linux ext4 driver in both directions, with the kernel log required to be silent |
| mounted driver | 23 assertions against a **real mount** — the only stage that goes through FSKit |

Stages 5–7 use Docker, which on Apple Silicon is a real Linux VM — so the
oracle is the actual ext4 implementation, not another copy of our assumptions.
They skip with a warning if Docker is not running; stage 7 also skips if the
signed extension is not installed and enabled. Stages 3 and 4 run either way —
only one section of each needs Docker.

The power-failure model matters: after the cut point, writes are **silently
discarded while still reporting success**. A real power loss does not hand the
filesystem an errno it can react to. Returning `EIO` would exercise error
handling instead, which is a far easier test to pass.

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
| seven metadata operations survive a cut taken the instant they return | recovering to *some* consistent state is not enough — a driver that discarded everything would also pass |
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

Formatting clears any previous filesystem's signatures first, via FSKit's
`wipeResource` (a wrapper around libutil's `wipefs`), then builds the volume.
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

**Where it is not atomic, and why that is the shape it is.** Linux journals the
superblock alongside the inode, so a list edit and the change it protects
commit together. lwext4 writes the superblock outside the journal
(`ext4_block_writebytes` goes straight to the device, past both the block cache
and the transaction), so the two halves land separately and the *order* has to
do the work instead:

| | order | what a cut in the middle leaves |
|---|---|---|
| adding | publish the head, **then** commit the unlink | an inode that is on the list and still has its name — which recovery recognises by the link count and drops. Nothing lost |
| removing | free the inode, **then** drop it from the list | a list entry pointing at an inode that is already free — which recovery recognises from the inode bitmap and skips |

Both orderings were chosen by measurement, not argument: the opposite choice on
the removal side failed 6 of 41 cut points with `Deleted inode has zero dtime`,
and the sweep is what said so.

One case is still imperfect and is documented rather than hidden. The new head
carries its own next pointer inside the transaction, so a cut between
publishing the head and committing loses the *rest* of the chain — every other
inode that happened to be deleted-but-open at that instant. Those leak exactly
as they did before any of this existed, so it is not a regression; it means a
volume with two simultaneous open-unlinks is protected for one of them rather
than both. Closing it needs the superblock inside the transaction, which needs
the block cache to accept block 0, which `patches/lwext4/0008` deliberately
forbids.

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

Formatting *through* Disk Utility is untested, because it ends up in
`newfs_fskit`, which does not work yet — see below.

### `newfs_fskit` does not work yet

`newfs_fskit -t ext4 <device>` fails with `ENOTSUP` and never calls our
`startFormat`. What has been ruled out, each with a control:

| Suspected | Evidence against |
|---|---|
| the device or permissions | Apple's `msdos` and `exfat` format the same device fine, without `sudo` |
| the probe gating format | fails on an already-ext4 volume too |
| extension-declared conformance | `FSVolume.RenameOperations` is declared the same way and works |
| missing selectors | `startFormatWithTask:options:error:` and the protocol are both in the shipped binary |
| unregistered conformance | the earlier `does not support operation newfs` message is gone |
| `EXExtensionPrincipalClass` | adding it *deregisters* the module entirely |

Instrumentation (`FSTask.logMessage` as the first statement of `startFormat`)
never prints, while Apple's exfat module's own messages do — so the call never
arrives. The remaining theory is that the Swift overlay's
`UnaryFileSystemExtension.configuration` does not wire maintenance operations;
its `swiftinterface` never mentions them. Unconfirmed.

The same core path is fully covered offline: `ext4dump format` builds volumes
across 117 geometries, all `e2fsck`-clean.

## Not yet done
- `newfs_fskit` reaches the module but never calls `startFormat`; see below
- A real structural check; `startCheck` only decides mountability
- Two simultaneous open-unlinks are crash-protected for one of them, not both
- `FSVolumeAccessCheckOperations`
- `FSVolumePreallocateOperations` — deliberately, for now; see below
- Kernel-offloaded I/O for writes (reads already use it)
- Notarised DMG

### Why `preallocateSpace` is not implemented

`fcntl(F_PREALLOCATE)` asks for blocks without content, and ext4 answers it
with **unwritten extents**: allocated, marked as not-yet-written, and read back
as zeroes without anyone having written zeroes. lwext4 can *read* unwritten
extents — `ext4_fs_get_inode_dblk_idx` returns a hole for them — but exposes no
way to create one.

That leaves two possible implementations and neither is worth shipping.
Allocating ordinary initialised blocks past end-of-file would hand back
whatever those blocks previously held the moment the file was extended into
them, which is a disclosure bug, not a feature. Zero-filling them instead is
correct but defeats the point: the whole reason to preallocate is that it is
cheap, and a caller asking for a gigabyte would block writing a gigabyte of
zeroes — slower than the writes it was trying to avoid.

Not conforming means `F_PREALLOCATE` returns `ENOTSUP`, which callers already
handle, because plenty of filesystems do not support it. Doing this properly
means teaching lwext4's extent code to create unwritten extents, which is the
most delicate code in the vendored tree.
