<!-- Moved from docs/STATUS.md on 2026-09-04; content unchanged apart from heading levels. -->

# Open-unlink

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

## The orphan list

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

## Renaming

`FSVolume.RenameOperations` is implemented, so Finder's Rename and
`diskutil rename` work. The label is a fixed 16-byte superblock field: a name
longer than that is refused rather than truncated, and the write goes through
immediately instead of waiting for unmount, because a rename the user can see
but that vanishes on power loss is worse than one that fails.
