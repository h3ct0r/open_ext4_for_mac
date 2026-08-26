# lwext4 patches

Applied automatically by the build (`make patch`, and as a prerequisite of every
object file). Idempotent — a clean checkout builds with a plain `make`.

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

Everything except 0001, 0003 and 0010 is a genuine upstream defect and worth
sending upstream. 0002 and 0004 were found by running the write suite under
`-fsanitize=address,undefined` (`make test-asan`); 0005 by the crash-consistency
sweep; 0006 by reading the superblock state of volumes snapshotted out from
under a live mount; 0007 and 0008 together by the mounted-driver suite, which
caught a volume that had stopped answering and sampled the extension to find
out where it was; 0009 and 0011 by formatting across a range of volume sizes
and block sizes and handing every result to `e2fsck`.

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
