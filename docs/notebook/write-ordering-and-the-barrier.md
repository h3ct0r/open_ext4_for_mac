<!-- Moved from docs/STATUS.md on 2026-09-04; content unchanged apart from heading levels. -->

# Write ordering is not enforced, and that is not theoretical

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

## What the stick showed

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

## Why there is no barrier to use

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

## A barrier the API does not offer, through a descriptor it left behind

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

## The metadata family is not a sandbox denial

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

## Two ordering holes remain above it

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

## What the reproducer says

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

## Concurrent core entry is now measured, not assumed

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

## What this means in practice

**Eject before unplugging**, which flushes and closes the journal cleanly.
Not because of the driver — the sweep below could not hurt it — but because
the last seconds of unsynced writes are only as durable as on any
filesystem, and because a mid-write pull can panic macOS itself: xnu's 60 s
busy-timeout watchdog fires when a drive's bridge chip hangs its in-flight
commands on surprise removal and the media object cannot finish terminating
(`busy timeout ... 'IOMediaBSDClient'`, panicked task `watchdogd`; observed
once during the sweep). That lives in Apple's storage stack, below anything
a filesystem can reach.

## The barrier daemon is retired: a five-drive verdict

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

## It is the medium, and that is now a controlled result

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

## Journal transactions are batched, and what that changed

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

## `startCheck` checks something now

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

## Access checks answer before the operation, not after

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

## Kernel-offloaded I/O silently discards writes

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

## One barrier in three was redundant

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

## Two ordering defects that turned out not to exist

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
