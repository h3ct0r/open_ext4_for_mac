<!-- Moved from docs/STATUS.md on 2026-09-04; content unchanged apart from heading levels. -->

# The pre-hardware hardening pass

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

**Two things the mounted stages say that are not driver defects.**

The LUKS app-flow stage (stage 5 of the mounted LUKS suite) needs the app
and the extension to share a keychain access group, and signing the app
into it needs `App/Ext4Mac.provisionprofile`, which this build does not
have -- `scripts/sign.sh` says so and carries on, because nothing else
needs it. The consequence is sharper than that line suggested and is now
spelled out where it is printed: the extension stores master keys in the
shared group, so an app outside that group cannot see or delete them.
`Ext4Mac list` reports no unlocked volumes when there are some, and
`Ext4Mac forget` deletes nothing while printing "forgot the key" --
SecItemDelete answers "no such item", which is indistinguishable from
success. **A container unlocked once then keeps mounting without its
passphrase** (measured: keychain empty of app-visible items, no key file
in the container, extension killed, volume still mounted and served
plaintext -- the driver's own log says "master key came from the
keychain"). The suite now detects the missing group and skips the stage
with that explanation instead of reporting six failures that read like
driver bugs.

The durability cell ("<op> is durable once synced") fails intermittently,
about once in forty observations, on a different operation each time. It
is not the journal: the same build passes the cell 3 runs in 4, a focused
loop of sixteen freeze-and-snapshot cycles kept every synced unlink (with
shell `sync` and with an explicit directory `fsync` alike), and the Linux
kernel agrees with our replay everywhere else. The likely mechanism is
macOS `sync(2)` delivery -- the suite freezes the extension the instant
`sync` returns, and the module's commit is not ordered against that
return. It predates this pass (it appeared against the pre-session build
in the same session). Left asserted, because the contract is right; noted
here so a hardware day does not chase it.
