# lwext4 patches

Applied automatically by the build (`make patch`, and as a prerequisite of every
object file). Idempotent — a clean checkout builds with a plain `make`.

**These files are the only copy of our changes to lwext4.** The submodule is
pinned at an upstream commit; anything edited into its working tree and not
written down here exists on one machine and nowhere else. `make check-patches`
replays the whole set onto the pinned commit in a temporary directory and
diffs the result against `Core/lwext4`, so that cannot go unnoticed again — it
had happened twice by the time it was checked, and both times the build was
green.

Two rules follow from `git apply` being all-or-nothing:

* **A patch may not disturb another patch's context.** Adding a line in the
  middle of a hunk an earlier patch already touched means that earlier patch
  can no longer be checked on its own, and the build's per-patch "is this still
  applied?" test starts failing on a tree that is perfectly correct. 0016 put
  an `#include` between two lines of 0010's context and did exactly this.
* **Regenerate a patch against the patches before it, not against the working
  tree.** 0014 was first produced as a whole-tree diff, so it carried hunks
  belonging to 0005 and 0008. Applied in order those hunks were already
  present, the patch failed as a unit, and the build skipped it with a note —
  a clone got a driver with no write barrier and no visible error.

| Patch | What it does |
|---|---|
| `0001-guard-EXT_FINCOM_IGNORED` | Lets the build extend the INCOMPAT bits lwext4 tolerates, so we can accept `metadata_csum_seed` (which modern `mke2fs` enables by default) after the bridge has verified the seed still matches the UUID. |
| `0002-fix-xattr-remove-ibody-finder` | **Bug fix.** NULL dereference (SIGSEGV) when removing an xattr stored in the inode body — the common case. |
| `0003-avoid-null-pointer-arithmetic-in-xattr-list` | Replaces a `sizeof`-via-null-pointer idiom that UBSan flags on every `listxattr`. |
| `0004-fix-htree-leaf-block-init-and-checksum-order` | **Bug fix.** New HTree leaf blocks were never cleared (stale buffer contents written into a directory block) and were checksummed before the last field was written, so `e2fsck` reported `directory passes checks but fails checksum`. |
| `0005-keep-journal-sequence-monotonic-across-mounts` | **Bug fix, data loss.** `jbd_journal_stop()` reset the on-disk journal sequence to 0, so every session restarted at 1 and stale log records from an earlier session were indistinguishable from current ones. A crash in the window after the journal superblock is published but before the transaction commits let recovery replay **old metadata over the live filesystem**. |
| `0006-do-not-fake-an-error-flag-while-mounted` | **Bug fix.** lwext4 marked a mounted volume by setting the superblock's `ERROR_FS` bit, so any volume that lost power came back reading *"not clean with errors"* even though nothing had gone wrong — and a clean unmount then cleared a genuine error flag. Now it clears `VALID_FS` on mount and ORs it back on unmount, which is what Linux does. |
| `0007-assert-must-not-spin-forever` | **Bug fix, availability.** A failed `ext4_assert` ran `while (1);`. On a mounted volume that means the driver stops answering while still holding the mount: every process touching it enters uninterruptible wait, `umount` hangs, and only `SIGKILL` clears it — at 100% CPU throughout. Now it aborts, so the mount is torn down and callers get `EIO`. |
| `0008-treat-block-zero-as-a-hole-not-a-block` | **Bug fix.** Block 0 is ext4's hole marker, but `ext4_block_get_noread()` accepted it, cached a buffer with `lb_id == 0`, and then tripped `ext4_assert(b->lb_id)` on release — reaching 0007's infinite loop. A lookup in a directory with a hole, or in an inode freed underneath a stale reference, wedged the whole driver. |
| `0009-clamp-the-last-block-groups-free-count` | **Bug fix.** `mkfs` gave every block group `blocks_per_group` free blocks, including a final partial one, so any volume that was not an exact multiple of the group size came out of `mkfs` with a free-block count that was too high — and `e2fsck` reported `Free blocks count wrong` on a brand-new filesystem. |
| `0010-set-the-bitmap-tail-padding-mkfs-writes` | **Conformance, not a bug fix.** `mkfs` wrote block and inode bitmaps as all zeroes; `mke2fs` sets the bits past the end of the group. Verified *not* load-bearing once 0011 is applied — kept so the on-disk result matches the reference implementation rather than relying on nobody reading those bits. |
| `0011-inodes-per-group-must-be-a-multiple-of-8` | **Bug fix.** `inodes_per_group` was aligned only to the inode-table stride (`block_size / inode_size`), which is 4 for 1 KiB blocks with 256-byte inodes. ext4 requires a multiple of 8 so each group's inode bitmap starts on a byte boundary; without it `e2fsck` reports `Padding at end of inode bitmap is not set`. `mke2fs` masks off the low three bits for the same reason. |
| `0012-honour-the-stored-metadata-checksum-seed` | **Bug fix, corruption.** Every metadata checksum was seeded with `crc32c(~0, uuid)`. ext4 stores the seed explicitly in `s_checksum_seed` when `metadata_csum_seed` is set — which `mke2fs` enables by default — precisely so that `tune2fs -U` can change a volume's UUID without rewriting every checksum on it. The two agree until somebody does that, and then *every* checksum lwext4 writes is wrong: `e2fsck` reports nine invalid group descriptor and inode checksums after a single `mkdir`. The bridge used to force such volumes read-only to avoid it; they are now writable. |
| `0013-an-inode-with-no-xattr-header-is-not-an-io-error` | **Bug fix.** `ext4_xattr_ibody_find_entry()` reported `EIO` for an inode whose in-inode attribute area carried no header — the ordinary state of almost every file — because `ext4_xattr_is_ibody_valid()` folds "absent" together with "malformed". Absence is now "not found"; corruption still returns `EIO`. The set path had been *relying* on that error to know when to lay a header down, so it now asks directly; without that it dereferences NULL on the first attribute written to a bare inode. |
| `0014-give-the-journal-a-write-barrier` | **Bug fix, corruption.** `struct ext4_blockdev_iface` had no way to ask the medium to commit, so jbd wrote a transaction and the commit block that vouches for it with nothing between them, and checkpointed with nothing between that and the commit. A drive is free to reorder all three. On a disk image this never shows — writes reach APFS through the page cache in issue order — while a USB stick pulled from under a live mount came back inconsistent five times out of five. Adds an optional `flush` to the interface and calls it on both sides of `jbd_trans_write_commit_block`. A NULL `flush` leaves jbd behaving exactly as before. |
| `0015-write-the-commit-checksum-big-endian` | **Bug fix.** lwext4 wrote the journal commit block's checksum in host byte order and verified it against `to_be32()` of the same computation, so on a little-endian machine it rejected every commit block it had written — as does Linux, which requires big-endian throughout the journal. That is why journal checksums looked unimplemented; it was one missing byte swap. |
| `0016-turn-journal-checksums-on-at-format-time` | **Conformance and defence in depth.** `mkfs` wrote a bare JBD superblock: no feature bits, no checksum type, no uuid, so the journal it laid down was the 1998 format. Sets `JBD_FEATURE_INCOMPAT_CSUM_V3` with crc32c, as `mke2fs` has by default for years, and copies the filesystem uuid into the journal superblock — the checksums are seeded from it, so without that every one computes against zeroes and Linux rejects the journal. A checksummed journal is the only defence against firmware that reports a cache flush without performing one, which no barrier can help with: recovery stops at the first commit block that does not verify, losing that change, instead of replaying a half-written transaction over a live filesystem. |
| `0017-checksum-the-tag-sequence-big-endian` | **Bug fix.** CSUM_V3 tag checksums covered the host-order sequence number where jbd2 checksums `cpu_to_be32(sequence)` — self-consistent, so lwext4 recovered its own journals, and wrong for everyone else: the Linux kernel rejected every data block of every transaction (`JBD2: Invalid checksum recovering data block…`), so a volume this driver left dirty could not be mounted by Linux at all. Same family as 0015: the journal is big-endian, including inside checksum computations. |
| `0018-the-revoke-count-is-records-not-reservations` | **Bug fix.** With checksums on, the revoke block's `count` folded in the 4-byte checksum-tail reservation, so every reader — lwext4, e2fsck, the Linux kernel — parses one entry past the last real one, into unset bytes: a fabricated revoke of an arbitrary block, silently installed on every recovery. Measured: sixty revoke blocks from a delete-heavy run, sixty garbage final entries. `Tests/run_revoke_tests.sh` is the red-first test. |
| `0019-revoke-what-you-free-not-what-you-remember` | **Bug fix.** Revokes were emitted only for blocks with a live `block_rec` — still tracked by an uncheckpointed transaction. The replayable log reaches further back than the checkpoint queue: a block journaled, checkpointed, freed, and reused as file data got no revoke, and replay clobbers it. Now every free is revoked, as Linux does; re-journaling in the same transaction still cancels it. Also the precondition for 0020's lazy tail. |
| `0020-advance-the-log-tail-lazily-and-durably` | **Bug fix, corruption.** The log tail was written on every checkpoint completion with no barrier — a tail that reached the medium before its checkpoint left the change in neither the log nor its home, and one that was lost while the freed log space was reused left recovery replaying nothing (both measured via the trace classifier). Now jbd2's shape: the tail is staged in memory and written durably only where the world must agree with it — the wrap path and the lap guard (barrier, superblock, barrier, once per ring cycle), stop, and recovery. Steady state is cheaper than before. |
| `0021-a-failed-checkpoint-read-is-not-an-invariant-violation` | **Bug fix, availability.** `jbd_journal_flush_trans` asserted that reading a log block back succeeds; pull the medium under a live mount and unmount's checkpoint flush hits the assert — SIGABRT mid-teardown (measured, USB yank during a write flood). The flush now returns the error and the purge stops rather than retrying a transaction that can never complete. The unflushed transaction stays covered by the staged tail, so the next mount replays it — which is what recovery is for. |
| `0022-block-zero-is-a-real-block` | Untangles three meanings of "block 0": the release-time validity assert now checks the buffer pointer (not `lb_id`), the hole-marker refusal from 0008 stays for every mapping-derived fetch, and `ext4_block_get_sb()` is the one sanctioned door to the superblock's home block — it computes the lba itself, so no caller-supplied hole can reach it. |
| `0023-journal-the-superblock` | **Bug fix, data loss.** `ext4_sb_write_trans()` commits superblock updates atomically with their transaction — `s_last_orphan` published separately from the unlink it points at stranded an inode at four consecutive cut points. The direct `ext4_sb_write` becomes cache-coherent, and `jbd_recover` reloads the superblock after replay (the 1 KiB-block path restored the disk but left the in-memory copy stale, and cleanup then undid the replay). jbd's tag-0 replay branch existed upstream, unreachable; it has a writer now. Kernel-verified at every cut. |

Everything except 0001, 0003, 0010 and 0016 is a genuine upstream defect and worth
sending upstream. 0002 and 0004 were found by running the write suite under
`-fsanitize=address,undefined` (`make test-asan`); 0005 by the crash-consistency
sweep; 0006 by reading the superblock state of volumes snapshotted out from
under a live mount; 0007 and 0008 together by the mounted-driver suite, which
caught a volume that had stopped answering and sampled the extension to find
out where it was; 0009 and 0011 by formatting across a range of volume sizes
and block sizes and handing every result to `e2fsck`.

0013 is what stopped Finder copying a file off an ext4 volume at all: macOS probes `com.apple.FinderInfo` on everything it touches, and an `EIO` there is
fatal to the copy. `cp` never showed it, because `cp` does not ask.

0012 is invisible unless a fixture has had its UUID changed after creation, which
is why one is built deliberately (`tune2fs -U` in `Tests/make_fixtures.sh`).
Reverting the patch and writing to that volume is the whole demonstration.

0009 and 0011 are both invisible at the sizes a casual test picks. 0009 needs a
volume that is *not* an exact multiple of the block-group size, and 0011 needs
1 KiB blocks specifically — at 2 KiB and 4 KiB the inode-table stride is already
a multiple of 8, so the alignment happens to be right by accident.

0007 and 0008 are one failure between them: 0008 is how the invariant gets
broken, 0007 is why breaking it costs the user their volume rather than one
failed syscall. Both are worth fixing — an assertion is not a plan for what to
do when it fails.

0005 is the most serious of the four. It is invisible to any test that does
not actually sever the write stream, because in normal operation the journal is
written, committed and checkpointed without ever being replayed. It only bites
on the recovery path — which is the one path that exists specifically to
protect data.

0004 is a good illustration of why the suite runs `e2fsck` after *every*
operation and why it runs under sanitizers: in an ordinary optimised build the
bug is invisible, because the freshly-allocated block happens to be zeroed and
the stale checksum still matches.
