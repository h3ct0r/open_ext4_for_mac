# Status

| Phase | State |
|---|---|
| 0 — pipeline & packaging | **complete — signed, installed, loads** |
| 1 — read-only ext2/3/4 | **complete; 41 tests green** |
| 2 — kernel-offloaded I/O | **disabled** — see below |
| 3 — write path | **complete and working on real mounts** |
| 4 — correctness harness | **complete: image, crash-consistency, differential-vs-Linux, and mounted-driver** |
| 5 — polish & distribution | not started |

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

### How it is tested

`e2fsck` runs after **every** mutating operation, not once at the end — a write
path that corrupts and then repairs two operations later still loses data on
power failure. Results are cross-checked against `debugfs`, an independent
implementation, so the suite cannot agree with a bug in our own reader.

`make test-asan` reruns everything under AddressSanitizer and UBSan. That is
how two genuine lwext4 defects were found; see `patches/lwext4/README.md`.

## Validation

```bash
make validate           # all five stages, unattended
make validate-asan      # the same under AddressSanitizer + UBSan
make test-mount-crash   # stage 5 on its own
```

| Stage | What it proves |
|---|---|
| read suite | 41 assertions, content verified byte-for-byte against `debugfs` |
| write suite | 82 assertions, `e2fsck` after **every** mutating operation |
| crash consistency | 256 cut points across 12 operations; the write stream is severed at every point, the **real Linux kernel** replays the journal, and `e2fsck` must be clean |
| differential vs Linux | 28 assertions; volumes round-trip between our driver and the real Linux ext4 driver in both directions, with the kernel log required to be silent |
| mounted driver | 15 assertions against a **real mount** — the only stage that goes through FSKit |

Stages 3–5 use Docker, which on Apple Silicon is a real Linux VM — so the
oracle is the actual ext4 implementation, not another copy of our assumptions.
They skip with a warning if Docker is not running; stage 5 also skips if the
signed extension is not installed and enabled.

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

## Not yet done
- Auto-mount in Finder without an explicit `mount -F -t ext4`
- Kernel-offloaded I/O for writes (reads already use it)
- `startCheck` / `startFormat` for Disk Utility integration
- Notarised DMG
