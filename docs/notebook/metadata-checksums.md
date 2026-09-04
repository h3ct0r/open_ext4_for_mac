<!-- Moved from docs/STATUS.md on 2026-09-04; content unchanged apart from heading levels. -->

# Metadata checksums

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
