# The hardware day

A runbook, because hardware iterations are the most expensive kind: each one
needs a signed install, a granted extension, physical media, and — when
something wedges — sometimes a reboot. The 2026-08-29 replay incident cost
days because the failing mount reported nothing and every hypothesis needed
another plug-in. The rule that follows from that:

*For the maintainer, before a session with real media. Users do not need
this page; [INSTALL.md](INSTALL.md) is theirs.*

Contents: [0. Before leaving the desk](#0-before-leaving-the-desk) ·
[1. Prepare the device](#1-prepare-the-device) · [2. The ladder](#2-the-ladder) ·
[3. Evidence before retry](#3-evidence-before-retry) · [4. When it wedges](#4-when-it-wedges) ·
[Appendix: every knob](#appendix-every-knob)

**The stick is the last step.** Anything discoverable offline is discovered
offline first. The offline harness now models the two things a disk image
otherwise hides — per-command cost (`EXT4DUMP_IO_LATENCY_US`) and a medium
that fails (`EXT4DUMP_EIO_*`) — so "it only happens on hardware" should be
rare, and when it does happen, the mount path logs enough numbers to
diagnose it in one iteration.

## 0. Before leaving the desk

**Unmount your own media first.** The mounted suites crash-test the driver
by `SIGSTOP`ing and `kill -9`ing the extension — the *shared* extension
process, which serves every ext4 volume on the machine. A drive of yours
mounted at the time gets crash-tested whether you meant it or not, and a
copy in flight is interrupted mid-write. The journal is built for exactly
that and kill-recovery passes it 12 rounds out of 12, but a file written
in that window can still be incomplete, and it is a needless risk to take
with real data.

The same goes the other way: heavy I/O from your own work while a suite
runs makes the machine slower, and two fixtures build their journals by
running a load for a fixed number of seconds. Starve them and they come
out shallow, which reads as a driver failure rather than a busy machine.


```bash
bash scripts/run_full_validation.sh
```

Everything green (or SKIP for stages whose prerequisites are absent — a
FAIL is a stop). This includes the replay-speed stage (8b) and the
error-injection stage (5b), which are the offline stand-ins for exactly the
failures hardware produces.

Then install and gate:

```bash
make install
```

Kill any running extension so fskitd relaunches the new binary — a
long-lived `Ext4FS` process keeps serving from the old one and a fix looks
like it did nothing (this cost half an hour once):

```bash
pkill -9 -f '/Ext4FS.appex/Contents/MacOS/Ext4FS'
```

```bash
bash scripts/preflight.sh
```

Preflight is THE gate: tools built, extension enabled **and answering a real
mount** (not pluginkit's guess), installed build matching this tree by
CDHash. With a device argument it also checks the `.fs` bundle, primed sudo,
and that the device mounts read-write and takes a write. Every hardware
suite calls it; run it yourself first anyway — its failure messages carry
the fix commands.

Open a second terminal with the log following before anything mounts:

```bash
log stream --predicate 'subsystem == "dev.h3ct0r.ext4"' --info
```

## 1. Prepare the device

BSD names change on every replug — check `diskutil list` every time, never
trust a remembered name.

```bash
sudo make prepare-device DEVICE=diskN CONFIRM=ERASE EXT4_SIZE=8g
```

`EXT4_SIZE=8g` deliberately: the pull-test autopsy `dd`s the whole
partition, and a full-disk partition on a 64 GB stick turns each autopsy
into an hour.

Formatting goes through the **raw** node (`/dev/rdiskN`) now, falling back
to the buffered one if a device refuses it. The buffered node routes every
transfer through the block layer a sector at a time: an 8 GB volume
measured **0.4 MB/s** on a USB stick, five minutes to write 129 MB that the
medium can stream in seconds. The tool aligns its own transfers, which is
what a character device requires — a format's one sub-sector write is the
superblock at offset 1024, and it now becomes a read-modify-write of the
sector holding it.

## 2. The ladder

Cheapest first; each rung proves something the next rung assumes, and each
has a log line (or a number) that says it worked. If a rung fails, stop and
collect evidence (§3) — do not climb past a failure.

| Rung | Do | Expect |
|---|---|---|
| probe | insert the stick | volume appears in Finder; log shows the probe accepting it |
| format | `prepare-device` above | progress output; on a stick, seconds-to-a-minute now (the inode tables write in 1 MiB runs — minutes means a regression) |
| clean mount | eject, replug | mounts within seconds; no `replaying journal` line |
| flood | copy a few thousand small files onto it | steady progress; the log stays quiet |
| timed eject | eject while watching the clock | completes in seconds; past ~20 s the OS force-ejects and the next rung becomes a recovery test whether you meant it or not |
| deep kill | `make test-kill-recovery EXT4_KILL_DEVICE=diskNsM` | all rounds green, including the deep round's `remount fits DiskArbitration's ~20s budget` line with a real number |
| pull | `make test-pull DEVICE=diskN` — the operator pulls on cue | per-round verdicts; results keyed by drive under `build/pulltest/` |

The line to watch on any recovery mount:

```
journal replayed: 1674 transaction(s), 28191 block(s), log 32768 blocks, in 812 ms
```

If a mount is slow, that line says where the time went. If the volume never
appears, `log show` will contain either that line (recovery finished but
something after it failed), a `journal recovery failed (errno N)` line, or
neither — meaning DiskArbitration gave up first; the transaction count from
a later manual mount tells you how deep the log was.

Safety notes carried from the suites' own headers: a pull can panic the
whole machine via xnu's busy-timeout watchdog (save work before each
round); killing the driver mid-write can leave the device serving no reads,
where even `kill -9` on e2fsck is a no-op and only a replug clears it.

## 3. Evidence before retry

One failure must yield a complete offline reproduction. Before touching the
stick again, in this order:

1. **Image the partition** — the medium is the crime scene and every retry
   overwrites it:
   ```bash
   sudo dd if=/dev/diskNsM of=corpse.img bs=1m
   ```
2. Save the log window:
   ```bash
   log show --last 10m --predicate 'subsystem == "dev.h3ct0r.ext4"' --info > oslog.txt
   ```
3. If the extension is alive but stuck: `sample Ext4FS 5 -file sample.txt`
   (this is how the replay incident was diagnosed).
4. Reproduce offline against the corpse: `build/bin/ext4dump corpse.img …`
   drives the identical core, and the media model prices it like the stick
   it came from.

### Which build is actually running

```bash
/Applications/Ext4Mac.app/Contents/MacOS/Ext4Mac version
```

Prints the git revision stamped into the installed app and extension at build
time; `make install` prints the same thing when it finishes. Two traps this
exists to close, both of which have cost a day each:

- A **mounted volume keeps the extension process it started with**, so a fresh
  install changes nothing until the volume is ejected and re-attached. Until
  then every log line comes from the old binary and reads exactly like the new
  one.
- The work may be on a **branch the build does not use**. Sessions run in a
  worktree under `.claude/worktrees/`, while builds come from `master` in the
  main checkout. If they have diverged, `make install` installs a tree that
  never contained the change under discussion.

Accounting lines in the log carry `[build <rev>]` for the same reason: a log
line should say which code produced it rather than leave it to inference.

### Core warnings in the log

Since patch `0059`, lwext4's own `[warn]` and `[error]` lines reach the log
instead of being compiled out. On a healthy volume there should be **none** --
every offline suite runs silent, and both the offline and mounted suites assert
it. So a `core: [warn]` line means something.

With one expected exception. Reading a volume whose **journal has not been
replayed** shows structures caught mid-update, and their checksums legitimately
do not match:

```
core: free-space accounting disagrees ... the journal is unreplayed
core: [warn]  Inode checksum failed.Inode: 12
```

That is the check working, not failing: the journal holds the correct copies and
replay would fix them. Read the accounting line above it before reading anything
into the checksum line -- a read-only mount does not replay, so this is the
normal appearance of a crash snapshot.

It is also the constraint on the work still outstanding. `ext4_balloc.c` and
twenty-one other sites currently continue after a failed checksum, and
`ext4_balloc.c` goes further and writes a fresh checksum over the bitmap it just
modified. Making those failures *act* is the obvious fix and must not be done
naively: on a pre-recovery mount they are expected, and refusing there would
turn every recoverable crash into an unmountable volume.

### Reading the write-run meter

`data write runs: N runs, M MB, avg B blocks` measures how long a contiguous
run the shim could hand the medium. 256 blocks is the ceiling, because the
largest write request macOS issues is 1 MB.

**A short average is not by itself an allocator problem.** The meter is bounded
by the file, so a 16 KB file cannot produce a run longer than 4 blocks no
matter how healthy allocation is. A copy of many small files therefore reports
a small average by construction, and reading that as fragmentation sent one
investigation the wrong way -- a broken free map was blamed for short runs, and
repairing it made the average *worse* because the workload had changed.

To ask whether the allocator itself is healthy, remove the workload variable:
one large file onto a freshly formatted volume.

```bash
build/bin/datafile write /Volumes/<vol>/one.bin 536870912 77
```

Measured on a fresh 4 GB volume, 512 MB in one file: **avg 252 blocks, longest
256** -- at the ceiling, both for a plain write and for a preallocated one. If
you see that, allocation is not the problem and the slow copy is somewhere
else.

One asymmetry worth knowing, and currently an open item: a preallocated write
fragments the extent tree, because each `mark_written` splits the extent it
lands in -- roughly one extent per write chunk.

| size      | written plainly | preallocated |
|-----------|-----------------|--------------|
| 1,052,136 | 1 extent        | 2            |
| 3,000,001 | 1 extent        | 4            |
| 512 MB    | 10 extents      | 256          |

Patch 0057 folds those runs back together, and in isolation it works: a 3 MB
preallocated file goes from four extents to one.

**It does not explain a corpus that reports 89% non-contiguous, and neither
does anything else measured so far.** That number was blamed on this
fragmentation and it survived the fix unchanged (89.1% before, 89.2% after).

*Read the rest of this section knowing how it ends: the percentage itself was
part of the problem, and every row below is a comparison of file counts that
could not have distinguished a two-piece file from a two-hundred-piece one.
The layout question is settled and the answer is in "The fix is to allocate
ahead" further down; what follows is the investigation that got there, kept
because the refuted explanations are worth not re-testing.*

Two further guesses were tested and are also wrong:

| shape                                   | non-contiguous |
|-----------------------------------------|----------------|
| 60 files, roomy volume, `cp`            | 2.7%           |
| 110 files, volume filled to 69%, `cp`   | 3.3%           |
| 407 files, volume filled to 74%, Finder | **89.2%**      |

The copy engine was tested too, by driving Finder itself through AppleScript
over the same corpus and volume, and it makes no difference either:

| shape (512 MB volume, 378 MB corpus, 200 files)   | non-contiguous |
|---------------------------------------------------|----------------|
| `cp(1)`                                            | 2.3%           |
| **Finder**, scripted, same corpus                  | **2.3%**       |
| `cp` with a second writer hammering the volume     | 0.5%           |

So five explanations were measured and refuted: preallocation, file
count, volume fullness, the copy engine, and concurrent background writes. None
of them reproduces anything near 89% on a disk image.

The one remaining difference was **the medium**, and that is now a mechanism
rather than a suspicion. It is **interleaving**, and it reproduces on an image
in seconds with no stick, no threads and no timing at all.

Slowing the device down was the planned route in, and `EXT4DUMP_IO_LATENCY_US`
already exists for it. It was not needed. Slowness is not the variable --
ordering is, and ordering can be dialled directly.

`ext4dump <img> interleave <n> <MiB-each> <chunk-KiB> [round|serial]` writes the
same bytes to the same files inside one mount in two orders: `serial` finishes
each file before starting the next, `round` walks them a chunk at a time.
Everything else is identical.

| eight 32 MiB files, 2 GB volume | extents in one file |
|---|---|
| `serial`, 64 KiB writes | **2** |
| `round`, 64 KiB writes | **256** |
| `round`, 1 MiB writes | **34** |

The last row is the field's shape exactly: roughly one extent per megabyte, and
1 MiB is the largest write macOS issues. The physical addresses say why. Each
file's extents sit 128 blocks apart when eight files interleave at 16 blocks
apiece -- the allocator honours the goal (the end of that inode's last extent),
finds it taken by whichever file allocated next, and takes the first free block
after it. Nothing is wrong with the allocator; the space it wanted is genuinely
occupied.

So the medium is the **condition**, not the cause. A fast image lets the copy
engine finish one file before the next begins, so nothing interleaves; a slow
stick keeps several in flight, and every write call becomes its own extent.

Incremental preallocation does the same thing, and worse, because it happens
before any data is written: preallocating eight files to 32 MiB in one call
each gives 2 extents apiece, while preallocating them a megabyte at a time
round-robin gives 34. Whole-file preallocation immunises a file completely --
which is why `cp(1)`, which does not preallocate but does finish one file at a
time, is also unaffected.

Finder, for its part, does not preallocate at all here. That was worth
checking rather than assuming, and the check is now permanent: the `io`
category logs a `preallocate: N calls over M file(s)` line every 64 requests,
and a scripted Finder copy of 120 files produced no line at all. Calls per
file is the number to read -- one per file means the copier knows the size up
front and the allocation is one run; many per file means it is asking
incrementally, and with several files in flight every increment lands
somewhere else.

**Do not measure this with e2fsck's `% non-contiguous`.** That number is a
file *count*: any file with more than one extent is in it. A corpus where
every file arrived as two clean halves reports 100%, and so does one where
every file arrived as two hundred pieces, so it cannot tell a fixed allocator
from a broken one. It did not: the field corpus read 89.2% before writes
reserved space ahead of themselves and 89.3% after, while the same workload
measured properly went from 978 KB per extent to 7282 KB.

`ext4dump <image|node> fragstat [path]` reports the number that moves --
extents per file, KB per extent, the distribution, and the worst file.

**The fix is to allocate ahead**, which is what whole-file preallocation was
doing by accident. A bulk write that extends a file now takes an unwritten
run beyond what it is about to write, and the driver remembers how far each
inode's run reaches, so the next write to that file continues inside it
whatever else allocated in between. Eight 32 MiB files interleaved a megabyte
at a time:

| | extents per file | KB per extent |
|---|---|---|
| before | 33.5 | **978** |
| after | 4.5 | **7282** |

978 KB per extent is one extent per write call, which is exactly what the
field corpus looked like. It works through a real mount too, which is not the
same test: eight 100 MB files written concurrently by separate processes come
out at 11 extents each. `make test-fragmentation` is the regression.

**On the stick, measured** -- the same 1.2 GB corpus that produced the 89%,
copied in Finder onto a freshly formatted 7.3 GB volume and surveyed cold:

```
fragstat: 408 file(s), 1267.0 MB, 880 extent(s)
  2.2 extent(s) per file, 1474 KB per extent
  1: 35   2-4: 368   5-16: 5   17-64: 0   65+: 0
  worst: <a 498 MB screen recording>, 7 extent(s)
```

The 65+ bucket is empty and the largest file on the volume is seven extents,
which is 71 MB apiece. The same volume's log says macOS handed the driver
1 MiB per write call; one extent per call would have put that file near five
hundred. e2fsck read 89.3% non-contiguous over exactly this layout, which is
the whole reason that number is not used here any more.

This is not a before/after on the same corpus -- the earlier run recorded only
the percentage, so there is no extent count to compare against. What there is
instead is three independent measurements agreeing: offline before/after,
concurrent writers through a mount, and this.

One side effect worth recognising rather than investigating twice. `e2fsck`
reports `extent tree could be shorter` on 144 inodes here where the earlier
run said 16. A file gets a depth-1 tree once it passes four extents and keeps
that depth after 0057 merges the runs back together, so 144 is the count of
files that grew past four extents and were folded back to four or fewer. It
measures the merging working, not damage.

Three things bound it, and they matter more than the extent count:

- only writes of 256 KiB or more take a reservation, so a volume full of
  small files never sees one;
- at most eight inodes hold one at a time, and taking a ninth returns the
  oldest -- so the space in flight is capped by the table, not by how many
  files are being copied;
- below 256 MiB free the driver not only stops reserving, it gives back what
  it is holding. Stopping at "take no more" is not enough: a 512 MB volume
  filled to ENOSPC one file at a time took 8 MiB less data than the same
  volume without reservations -- one reservation left holding, because the
  threshold that stopped new ones also stopped the evictions that would have
  returned it. Releasing restores the figure exactly.

An inode that already has space past end-of-file never gets a reservation.
That space belongs to an explicit `F_PREALLOCATE`, and trimming it later
would undo an `fcntl` the application was told had succeeded -- which, since
Finder preallocates every file it copies, is the common case rather than a
corner.

**Beware measuring a Finder copy by file count.** Finder creates every
destination file early, so a wait loop that counts names finishes long before
the data lands; unmounting there truncates the copy and measures nothing. The
first run of this comparison reported 0.9% and 4124 blocks for a 378 MB corpus
that way. Wait on bytes.

One consequence of 0057 worth knowing: merging can leave a tree deeper than its
contents now need, so `e2fsck -fn` may say `extent tree could be shorter.
Optimize?`. On the field corpus that is 16 inodes. It is a suggestion, not an
error, and the tree is not collapsed back -- an open item.

### Free-space accounting

`df` on a mounted volume can report nonsense -- more available space than the
volume has size -- and a broken free-space picture is also what collapses
allocation into short runs, so a copy that should stream crawls instead. The
numbers the OS is given come from one call, and the tool exposes it:

```bash
build/bin/ext4dump corpse.img df
```

It prints total/free/available, marks any impossible value `IMPOSSIBLE`, and
exits non-zero if one appears. Mounting also logs one line naming *which*
record is wrong:

- *"free-space accounting agrees"* -- the superblock's cached total and the
  group descriptors match; look elsewhere.
- *"only the cached total is impossible"* -- the descriptors are fine, so
  allocation is healthy and the bad number is cosmetic until `e2fsck -fy`.
- *"the descriptors themselves are impossible"* -- the allocator is working
  from a broken map; expect short runs and poor throughput. This fires when
  the descriptors sum to more than the volume holds **or** when any single
  group claims more free blocks than it holds; a follow-up line names how
  many and the first offender.

The distinction matters because the two have different causes and only the
second explains slow copies.

**Check whether the journal is unreplayed before believing any of it.** A
read-only mount does not replay, so the superblock it reads is the one the
last crash left behind, and its cached total can be wildly wrong while the
journal holds the correct value. The field stick reported 2,471,492 free of
1,920,357 blocks that way; one read-write mount replayed the log and the same
volume read 1,750,596, in agreement with its descriptors. The audit now says
`these are pre-recovery values` when that is the case, and `probe` shows
`journal: yes (NEEDS RECOVERY)`. Replay first, then re-read.

Replay corrects the totals. It does **not** correct a group whose descriptor
claims more blocks than the group holds -- on that volume all three survived
recovery unchanged. So the per-group line is the durable finding and the
totals are the one to re-read.

Do not read the second verdict as "the descriptors are fine". A group can be
impossible on its own while the sum stays plausible -- the field stick had
three such groups summing to less than the volume size -- so check the
per-group breakdown before concluding the map is healthy. The audit tested
only the sum until 2e77aa7 and called that volume "accounting agrees".

That line names which record is wrong, not where. The breakdown behind it:

```bash
build/bin/ext4dump corpse.img groups          # add `bad` for only the bad ones
```

It prints each group's free count with its `BLOCK_UNINIT` / `INODE_UNINIT`
flags, sums the descriptors, and prints the superblock's counter beside that
sum. Read-only, and it does not materialise a lazily-formatted group -- so it
is safe to point at the evidence, and at an unmounted `sudo ext4dump
/dev/rdiskNsM groups` if you have not imaged yet. Image first anyway: §3.

Two things it is worth knowing it does:

- It reports the superblock counter **as stored**, not as `df` reports it.
  `df` clamps free to the volume size so the OS is never handed an impossible
  number; that clamp hides the value you want here. On the field stick it is
  the difference between reading a 60,207-block drift and the real 611,347.
- It exits 1 when the two records disagree, so it can gate a script.

If the damaged groups are the ones still flagged `BLOCK_UNINIT`, the fault is
in the lazy-format series (patches 0051-0053) rather than in ordinary
allocation. If they are initialised groups, it is the allocator. That is the
fork, and this is the command that settles it.

## 4. When it wedges

Known states, from mildest to worst (docs/notebook/write-ordering-and-the-barrier.md has the histories):

- **Extension serving stale code** — `pkill -9 -f Ext4FS`; fskitd relaunches
  on the next probe.
- **Mount comes up read-only right after a kill** — fskitd has not released
  the dead instance's claim, so the relaunched extension sees a non-writable
  resource and (correctly) mounts read-only *without replaying* — the log
  says `read-only mount of an unreplayed journal`. The volume shows
  pre-crash contents; this is not data loss. Unmount, give it a few
  seconds, remount: the read-write mount replays.
- **Device claimed by a dead mount** — `diskutil unmountDisk force diskN`,
  give it ~10 s; if a process is stuck in uninterruptible I/O on the node,
  only a physical replug clears it.
- **Two mounted-suite results that are about the machine, not the driver**
  — the LUKS app-flow stage skips unless the app is signed into the
  extension's keychain group (needs `App/Ext4Mac.provisionprofile`), and
  the "no plaintext key after unlock" check is not asserted when the
  screen is locked: the keychain then refuses the key (-25308) and the
  extension takes its container fallback. Run the LUKS stage with the
  screen unlocked to exercise the keychain path.
- **DiskArbitration wedged** (mounts then deactivates ~2 ms later,
  status 0x204, after heavy kill/pull abuse) — a replug sometimes clears
  it; SIP forbids kickstarting fskitd; only a reboot fully resets it.
  `fsck_fskit` can stay wedged (ENOTSUP) the same way. Re-run the mounted
  suite once before blaming a code change.

## Appendix: every knob

The tool reads these (none ship in the appex — `scripts/check_ship_surface.sh`
enforces that):

| ext4dump env | Meaning |
|---|---|
| `EXT4DUMP_DEVICE_BSIZE` | device block size the core is told (default 512; the appex passes the real sector size, commonly 4096) |
| `EXT4DUMP_LUKS_KEYFILE` | treat the image as a LUKS container; file holds the passphrase |
| `EXT4DUMP_FAIL_AFTER=N` | power-cut model: from write N on, writes vanish *silently* |
| `EXT4DUMP_WRITE_CACHE=B` | volatile write-cache model of B bytes; only barriers flush it |
| `EXT4DUMP_REORDER_SEED` / `EXT4DUMP_REORDER_DROP` | reorder/drop behavior of the cache model at the cut |
| `EXT4DUMP_IGNORE_BARRIERS` | a drive that lies about flushing (negative control) |
| `EXT4DUMP_IO_LATENCY_US` | media model: fixed cost charged per read/write command |
| `EXT4DUMP_IO_BW_MBS` | media model: transfer rate charged per byte |
| `EXT4DUMP_IO_STATS=1` | print `IOSTATS reads= read_bytes= writes= write_bytes= flushes=` at exit |
| `EXT4DUMP_EIO_READ_AT=N` / `EXT4DUMP_EIO_WRITE_AT=N` | the N-th read/write answers EIO once (prints an `EIO-INJECT` line) |
| `EXT4DUMP_EIO_STICKY=1` | …and every later one too (dead stick) |
| `EXT4DUMP_EIO_READ_OFF=B` / `EXT4DUMP_EIO_WRITE_OFF=B` | bad-sector model: every I/O covering byte offset B fails |
| `EXT4DUMP_TRACE` | trace I/O (`-` for stderr): `TRC R/W seq= off= len=` plus the cache-model events |
| `EXT4DUMP_JOURNAL_BLOCKS` | journal size for `format` |
| `EXT4DUMP_UUID` | pin the volume UUID (reproducible images) |
| `EXT4DUMP_KEEP_ORPHANS` | skip orphan cleanup at mount (inspection) |
| `EXT4DUMP_IO_STATS=1` with `put <path> <file> [n]` | the data-path measurement: copy a host file in, n bytes per write, and read the command count off IOSTATS |
| `EXT4DUMP_SCRIPT_CONTINUE=1` | `script` keeps going after a failing command instead of stopping — models an application that keeps writing to a volume that has started refusing |
| `EXT4DUMP_REPORT_WRITES` | print `writes=N` at exit (predates IOSTATS) |
| `EXT4B_TXN_BATCH` | mutations per journal transaction (tool only; appex uses the compiled default) |

| Harness env | Suite | Meaning |
|---|---|---|
| `EXT4_KILL_DEVICE=diskNsM` | kill-recovery | run against real media (ERASES it) |
| `DEVICE=diskN` | pull, prepare-device | target disk (pull ERASES it every round) |
| `EXT4_BENCH_DEVICE` | throughput | mounted read-only benchmark target |
| `EXT4_SIZE`, `EXT4_LABEL`, `CONFIRM=ERASE` | prepare-device | partition size / label / consent |
| `ROUNDS`, `WARMUP`, `HARSH`, `KEEP_CORPSE`, `TAG` | kill-recovery / pull | round count, pre-pull warmup seconds, unfenced mode, keep dd images, results key |
| `EXT4_FSCK_TIMEOUT`, `EXT4_STAGE_TIMEOUT` | kill-recovery / validation | deadlines in seconds |
| `EXT4_REQUIRE_FRESH=1` | freshness check | stale (or unverifiable) install is fatal — preflight always uses this |
| `EXT4_KILL_FORCE_FORMAT` | kill-recovery | reformat even if the volume looks reusable |
| `EXT4_REORDER_CACHE` | reorder | cache size for the write-cache model |
| `SWEEP_SNAPSHOTS` | mount-crash | snapshots per sweep |

Three names for "the device" is historical debt (documented here rather than
renamed mid-flight; unification is on the backlog).
