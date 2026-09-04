<!-- Moved from docs/STATUS.md on 2026-09-04; content unchanged apart from heading levels. -->

# Preallocation

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
