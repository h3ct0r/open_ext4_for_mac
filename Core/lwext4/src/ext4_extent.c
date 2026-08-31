/*
 * Copyright (c) 2017 Grzegorz Kostka (kostka.grzegorz@gmail.com)
 * Copyright (c) 2017 Kaho Ng (ngkaho1234@gmail.com)
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 */

#include <ext4_config.h>
#include <ext4_types.h>
#include <ext4_misc.h>
#include <ext4_errno.h>
#include <ext4_debug.h>

#include <ext4_blockdev.h>
#include <ext4_trans.h>
#include <ext4_fs.h>
#include <ext4_super.h>
#include <ext4_crc32.h>
#include <ext4_balloc.h>
#include <ext4_extent.h>

#include <stdlib.h>
#include <string.h>
#include <inttypes.h>
#include <stddef.h>

#if CONFIG_EXTENTS_ENABLE
/*
 * used by extent splitting.
 */
#define EXT4_EXT_MARK_UNWRIT1 0x02 /* mark first half unwritten */
#define EXT4_EXT_MARK_UNWRIT2 0x04 /* mark second half unwritten */
#define EXT4_EXT_DATA_VALID1 0x08  /* first half contains valid data */
#define EXT4_EXT_DATA_VALID2 0x10  /* second half contains valid data */
#define EXT4_EXT_NO_COMBINE 0x20   /* do not combine two extents */

#define EXT4_EXT_UNWRITTEN_MASK (1L << 15)

#define EXT4_EXT_MAX_LEN_WRITTEN (1L << 15)
#define EXT4_EXT_MAX_LEN_UNWRITTEN \
    (EXT4_EXT_MAX_LEN_WRITTEN - 1)

#define EXT4_EXT_GET_LEN(ex) to_le16((ex)->block_count)
#define EXT4_EXT_GET_LEN_UNWRITTEN(ex) \
    (EXT4_EXT_GET_LEN(ex) & ~(EXT4_EXT_UNWRITTEN_MASK))
#define EXT4_EXT_SET_LEN(ex, count) \
    ((ex)->block_count = to_le16(count))

#define EXT4_EXT_IS_UNWRITTEN(ex) \
    (EXT4_EXT_GET_LEN(ex) > EXT4_EXT_MAX_LEN_WRITTEN)
#define EXT4_EXT_SET_UNWRITTEN(ex) \
    ((ex)->block_count |= to_le16(EXT4_EXT_UNWRITTEN_MASK))
#define EXT4_EXT_SET_WRITTEN(ex) \
    ((ex)->block_count &= ~(to_le16(EXT4_EXT_UNWRITTEN_MASK)))

/*
 * Array of ext4_ext_path contains path to some extent.
 * Creation/lookup routines use it for traversal/splitting/etc.
 * Truncate uses it to simulate recursive walking.
 */
struct ext4_extent_path {
    ext4_fsblk_t p_block;
    struct ext4_block block;
    int32_t depth;
    int32_t maxdepth;
    struct ext4_extent_header *header;
    struct ext4_extent_index *index;
    struct ext4_extent *extent;
};


#pragma pack(push, 1)

/*
 * This is the extent tail on-disk structure.
 * All other extent structures are 12 bytes long.  It turns out that
 * block_size % 12 >= 4 for at least all powers of 2 greater than 512, which
 * covers all valid ext4 block sizes.  Therefore, this tail structure can be
 * crammed into the end of the block without having to rebalance the tree.
 */
struct ext4_extent_tail
{
    uint32_t et_checksum; /* crc32c(uuid+inum+extent_block) */
};

/*
 * This is the extent on-disk structure.
 * It's used at the bottom of the tree.
 */
struct ext4_extent {
    uint32_t first_block; /* First logical block extent covers */
    uint16_t block_count; /* Number of blocks covered by extent */
    uint16_t start_hi;    /* High 16 bits of physical block */
    uint32_t start_lo;    /* Low 32 bits of physical block */
};

/*
 * This is index on-disk structure.
 * It's used at all the levels except the bottom.
 */
struct ext4_extent_index {
    uint32_t first_block; /* Index covers logical blocks from 'block' */

    /**
     * Pointer to the physical block of the next
     * level. leaf or next index could be there
     * high 16 bits of physical block
     */
    uint32_t leaf_lo;
    uint16_t leaf_hi;
    uint16_t padding;
};

/*
 * Each block (leaves and indexes), even inode-stored has header.
 */
struct ext4_extent_header {
    uint16_t magic;
    uint16_t entries_count;     /* Number of valid entries */
    uint16_t max_entries_count; /* Capacity of store in entries */
    uint16_t depth;             /* Has tree real underlying blocks? */
    uint32_t generation;    /* generation of the tree */
};

#pragma pack(pop)


#define EXT4_EXTENT_MAGIC 0xF30A

#define EXT4_EXTENT_FIRST(header)                                              \
    ((struct ext4_extent *)(((char *)(header)) +                           \
                sizeof(struct ext4_extent_header)))

#define EXT4_EXTENT_FIRST_INDEX(header)                                        \
    ((struct ext4_extent_index *)(((char *)(header)) +                     \
                      sizeof(struct ext4_extent_header)))

/*
 * EXT_INIT_MAX_LEN is the maximum number of blocks we can have in an
 * initialized extent. This is 2^15 and not (2^16 - 1), since we use the
 * MSB of ee_len field in the extent datastructure to signify if this
 * particular extent is an initialized extent or an uninitialized (i.e.
 * preallocated).
 * EXT_UNINIT_MAX_LEN is the maximum number of blocks we can have in an
 * uninitialized extent.
 * If ee_len is <= 0x8000, it is an initialized extent. Otherwise, it is an
 * uninitialized one. In other words, if MSB of ee_len is set, it is an
 * uninitialized extent with only one special scenario when ee_len = 0x8000.
 * In this case we can not have an uninitialized extent of zero length and
 * thus we make it as a special case of initialized extent with 0x8000 length.
 * This way we get better extent-to-group alignment for initialized extents.
 * Hence, the maximum number of blocks we can have in an *initialized*
 * extent is 2^15 (32768) and in an *uninitialized* extent is 2^15-1 (32767).
 */
#define EXT_INIT_MAX_LEN (1L << 15)
#define EXT_UNWRITTEN_MAX_LEN (EXT_INIT_MAX_LEN - 1)

#define EXT_EXTENT_SIZE sizeof(struct ext4_extent)
#define EXT_INDEX_SIZE sizeof(struct ext4_extent_idx)

#define EXT_FIRST_EXTENT(__hdr__)                                              \
    ((struct ext4_extent *)(((char *)(__hdr__)) +                          \
                sizeof(struct ext4_extent_header)))
#define EXT_FIRST_INDEX(__hdr__)                                               \
    ((struct ext4_extent_index *)(((char *)(__hdr__)) +                    \
                    sizeof(struct ext4_extent_header)))
#define EXT_HAS_FREE_INDEX(__path__)                                           \
    (to_le16((__path__)->header->entries_count) <                                \
                    to_le16((__path__)->header->max_entries_count))
#define EXT_LAST_EXTENT(__hdr__)                                               \
    (EXT_FIRST_EXTENT((__hdr__)) + to_le16((__hdr__)->entries_count) - 1)
#define EXT_LAST_INDEX(__hdr__)                                                \
    (EXT_FIRST_INDEX((__hdr__)) + to_le16((__hdr__)->entries_count) - 1)
#define EXT_MAX_EXTENT(__hdr__)                                                \
    (EXT_FIRST_EXTENT((__hdr__)) + to_le16((__hdr__)->max_entries_count) - 1)
#define EXT_MAX_INDEX(__hdr__)                                                 \
    (EXT_FIRST_INDEX((__hdr__)) + to_le16((__hdr__)->max_entries_count) - 1)

#define EXT4_EXTENT_TAIL_OFFSET(hdr)                                           \
    (sizeof(struct ext4_extent_header) +                                   \
     (sizeof(struct ext4_extent) * to_le16((hdr)->max_entries_count)))


/**@brief Get logical number of the block covered by extent.
 * @param extent Extent to load number from
 * @return Logical number of the first block covered by extent */
static inline uint32_t ext4_extent_get_first_block(struct ext4_extent *extent)
{
    return to_le32(extent->first_block);
}

/**@brief Set logical number of the first block covered by extent.
 * @param extent Extent to set number to
 * @param iblock Logical number of the first block covered by extent */
static inline void ext4_extent_set_first_block(struct ext4_extent *extent,
        uint32_t iblock)
{
    extent->first_block = to_le32(iblock);
}

/**@brief Get number of blocks covered by extent.
 * @param extent Extent to load count from
 * @return Number of blocks covered by extent */
static inline uint16_t ext4_extent_get_block_count(struct ext4_extent *extent)
{
    if (EXT4_EXT_IS_UNWRITTEN(extent))
        return EXT4_EXT_GET_LEN_UNWRITTEN(extent);
    else
        return EXT4_EXT_GET_LEN(extent);
}
/**@brief Set number of blocks covered by extent.
 * @param extent Extent to load count from
 * @param count  Number of blocks covered by extent
 * @param unwritten Whether the extent is unwritten or not */
static inline void ext4_extent_set_block_count(struct ext4_extent *extent,
                           uint16_t count, bool unwritten)
{
    EXT4_EXT_SET_LEN(extent, count);
    if (unwritten)
        EXT4_EXT_SET_UNWRITTEN(extent);
}

/**@brief Get physical number of the first block covered by extent.
 * @param extent Extent to load number
 * @return Physical number of the first block covered by extent */
static inline uint64_t ext4_extent_get_start(struct ext4_extent *extent)
{
    return ((uint64_t)to_le16(extent->start_hi)) << 32 |
           ((uint64_t)to_le32(extent->start_lo));
}


/**@brief Set physical number of the first block covered by extent.
 * @param extent Extent to load number
 * @param fblock Physical number of the first block covered by extent */
static inline void ext4_extent_set_start(struct ext4_extent *extent, uint64_t fblock)
{
    extent->start_lo = to_le32((fblock << 32) >> 32);
    extent->start_hi = to_le16((uint16_t)(fblock >> 32));
}


/**@brief Get logical number of the block covered by extent index.
 * @param index Extent index to load number from
 * @return Logical number of the first block covered by extent index */
static inline uint32_t
ext4_extent_index_get_first_block(struct ext4_extent_index *index)
{
    return to_le32(index->first_block);
}

/**@brief Set logical number of the block covered by extent index.
 * @param index  Extent index to set number to
 * @param iblock Logical number of the first block covered by extent index */
static inline void
ext4_extent_index_set_first_block(struct ext4_extent_index *index,
                  uint32_t iblock)
{
    index->first_block = to_le32(iblock);
}

/**@brief Get physical number of block where the child node is located.
 * @param index Extent index to load number from
 * @return Physical number of the block with child node */
static inline uint64_t
ext4_extent_index_get_leaf(struct ext4_extent_index *index)
{
    return ((uint64_t)to_le16(index->leaf_hi)) << 32 |
           ((uint64_t)to_le32(index->leaf_lo));
}

/**@brief Set physical number of block where the child node is located.
 * @param index  Extent index to set number to
 * @param fblock Ohysical number of the block with child node */
static inline void ext4_extent_index_set_leaf(struct ext4_extent_index *index,
                          uint64_t fblock)
{
    index->leaf_lo = to_le32((fblock << 32) >> 32);
    index->leaf_hi = to_le16((uint16_t)(fblock >> 32));
}

/**@brief Get magic value from extent header.
 * @param header Extent header to load value from
 * @return Magic value of extent header */
static inline uint16_t
ext4_extent_header_get_magic(struct ext4_extent_header *header)
{
    return to_le16(header->magic);
}

/**@brief Set magic value to extent header.
 * @param header Extent header to set value to
 * @param magic  Magic value of extent header */
static inline void ext4_extent_header_set_magic(struct ext4_extent_header *header,
                        uint16_t magic)
{
    header->magic = to_le16(magic);
}

/**@brief Get number of entries from extent header
 * @param header Extent header to get value from
 * @return Number of entries covered by extent header */
static inline uint16_t
ext4_extent_header_get_entries_count(struct ext4_extent_header *header)
{
    return to_le16(header->entries_count);
}

/**@brief Set number of entries to extent header
 * @param header Extent header to set value to
 * @param count  Number of entries covered by extent header */
static inline void
ext4_extent_header_set_entries_count(struct ext4_extent_header *header,
                     uint16_t count)
{
    header->entries_count = to_le16(count);
}

/**@brief Get maximum number of entries from extent header
 * @param header Extent header to get value from
 * @return Maximum number of entries covered by extent header */
static inline uint16_t
ext4_extent_header_get_max_entries_count(struct ext4_extent_header *header)
{
    return to_le16(header->max_entries_count);
}

/**@brief Set maximum number of entries to extent header
 * @param header    Extent header to set value to
 * @param max_count Maximum number of entries covered by extent header */
static inline void
ext4_extent_header_set_max_entries_count(struct ext4_extent_header *header,
                          uint16_t max_count)
{
    header->max_entries_count = to_le16(max_count);
}

/**@brief Get depth of extent subtree.
 * @param header Extent header to get value from
 * @return Depth of extent subtree */
static inline uint16_t
ext4_extent_header_get_depth(struct ext4_extent_header *header)
{
    return to_le16(header->depth);
}

/**@brief Set depth of extent subtree.
 * @param header Extent header to set value to
 * @param depth  Depth of extent subtree */
static inline void
ext4_extent_header_set_depth(struct ext4_extent_header *header, uint16_t depth)
{
    header->depth = to_le16(depth);
}

/**@brief Get generation from extent header
 * @param header Extent header to get value from
 * @return Generation */
static inline uint32_t
ext4_extent_header_get_generation(struct ext4_extent_header *header)
{
    return to_le32(header->generation);
}

/**@brief Set generation to extent header
 * @param header     Extent header to set value to
 * @param generation Generation */
static inline void
ext4_extent_header_set_generation(struct ext4_extent_header *header,
                       uint32_t generation)
{
    header->generation = to_le32(generation);
}

void ext4_extent_tree_init(struct ext4_inode_ref *inode_ref)
{
    /* Initialize extent root header */
    struct ext4_extent_header *header =
            ext4_inode_get_extent_header(inode_ref->inode);
    ext4_extent_header_set_depth(header, 0);
    ext4_extent_header_set_entries_count(header, 0);
    ext4_extent_header_set_generation(header, 0);
    ext4_extent_header_set_magic(header, EXT4_EXTENT_MAGIC);

    uint16_t max_entries = (EXT4_INODE_BLOCKS * sizeof(uint32_t) -
            sizeof(struct ext4_extent_header)) /
                    sizeof(struct ext4_extent);

    ext4_extent_header_set_max_entries_count(header, max_entries);
    inode_ref->dirty  = true;
}


static struct ext4_extent_tail *
find_ext4_extent_tail(struct ext4_extent_header *eh)
{
	return (struct ext4_extent_tail *)(((char *)eh) +
					   EXT4_EXTENT_TAIL_OFFSET(eh));
}

static struct ext4_extent_header *ext_inode_hdr(struct ext4_inode *inode)
{
	return (struct ext4_extent_header *)inode->blocks;
}

static struct ext4_extent_header *ext_block_hdr(struct ext4_block *block)
{
	return (struct ext4_extent_header *)block->data;
}

static uint16_t ext_depth(struct ext4_inode *inode)
{
	return to_le16(ext_inode_hdr(inode)->depth);
}

static uint16_t ext4_ext_get_actual_len(struct ext4_extent *ext)
{
	return (to_le16(ext->block_count) <= EXT_INIT_MAX_LEN
		    ? to_le16(ext->block_count)
		    : (to_le16(ext->block_count) - EXT_INIT_MAX_LEN));
}

static void ext4_ext_mark_initialized(struct ext4_extent *ext)
{
	ext->block_count = to_le16(ext4_ext_get_actual_len(ext));
}

static void ext4_ext_mark_unwritten(struct ext4_extent *ext)
{
	ext->block_count |= to_le16(EXT_INIT_MAX_LEN);
}

static int ext4_ext_is_unwritten(struct ext4_extent *ext)
{
	/* Extent with ee_len of 0x8000 is treated as an initialized extent */
	return (to_le16(ext->block_count) > EXT_INIT_MAX_LEN);
}

/*
 * ext4_ext_pblock:
 * combine low and high parts of physical block number into ext4_fsblk_t
 */
static ext4_fsblk_t ext4_ext_pblock(struct ext4_extent *ex)
{
	ext4_fsblk_t block;

	block = to_le32(ex->start_lo);
	block |= ((ext4_fsblk_t)to_le16(ex->start_hi) << 31) << 1;
	return block;
}

/*
 * ext4_idx_pblock:
 * combine low and high parts of a leaf physical block number into ext4_fsblk_t
 */
static ext4_fsblk_t ext4_idx_pblock(struct ext4_extent_index *ix)
{
	ext4_fsblk_t block;

	block = to_le32(ix->leaf_lo);
	block |= ((ext4_fsblk_t)to_le16(ix->leaf_hi) << 31) << 1;
	return block;
}

/*
 * ext4_ext_store_pblock:
 * stores a large physical block number into an extent struct,
 * breaking it into parts
 */
static void ext4_ext_store_pblock(struct ext4_extent *ex, ext4_fsblk_t pb)
{
	ex->start_lo = to_le32((uint32_t)(pb & 0xffffffff));
	ex->start_hi = to_le16((uint16_t)((pb >> 32)) & 0xffff);
}

/*
 * ext4_idx_store_pblock:
 * stores a large physical block number into an index struct,
 * breaking it into parts
 */
static void ext4_idx_store_pblock(struct ext4_extent_index *ix, ext4_fsblk_t pb)
{
	ix->leaf_lo = to_le32((uint32_t)(pb & 0xffffffff));
	ix->leaf_hi = to_le16((uint16_t)((pb >> 32)) & 0xffff);
}

static int ext4_allocate_single_block(struct ext4_inode_ref *inode_ref,
				      ext4_fsblk_t goal, ext4_fsblk_t *blockp)
{
	return ext4_balloc_alloc_block(inode_ref, goal, blockp);
}

static ext4_fsblk_t ext4_new_meta_blocks(struct ext4_inode_ref *inode_ref,
					 ext4_fsblk_t goal,
					 uint32_t flags __unused,
					 uint32_t *count, int *errp)
{
	ext4_fsblk_t block = 0;

	*errp = ext4_allocate_single_block(inode_ref, goal, &block);
	if (count)
		*count = 1;
	return block;
}

static void ext4_ext_free_blocks(struct ext4_inode_ref *inode_ref,
				 ext4_fsblk_t block, uint32_t count,
				 uint32_t flags __unused)
{
	ext4_balloc_free_blocks(inode_ref, block, count);
}

static uint16_t ext4_ext_space_block(struct ext4_inode_ref *inode_ref)
{
	uint16_t size;
	uint32_t block_size = ext4_sb_get_block_size(&inode_ref->fs->sb);

	size = (block_size - sizeof(struct ext4_extent_header)) /
	       sizeof(struct ext4_extent);
#ifdef AGGRESSIVE_TEST
	if (size > 6)
		size = 6;
#endif
	return size;
}

static uint16_t ext4_ext_space_block_idx(struct ext4_inode_ref *inode_ref)
{
	uint16_t size;
	uint32_t block_size = ext4_sb_get_block_size(&inode_ref->fs->sb);

	size = (block_size - sizeof(struct ext4_extent_header)) /
	       sizeof(struct ext4_extent_index);
#ifdef AGGRESSIVE_TEST
	if (size > 5)
		size = 5;
#endif
	return size;
}

static uint16_t ext4_ext_space_root(struct ext4_inode_ref *inode_ref)
{
	uint16_t size;

	size = sizeof(inode_ref->inode->blocks);
	size -= sizeof(struct ext4_extent_header);
	size /= sizeof(struct ext4_extent);
#ifdef AGGRESSIVE_TEST
	if (size > 3)
		size = 3;
#endif
	return size;
}

static uint16_t ext4_ext_space_root_idx(struct ext4_inode_ref *inode_ref)
{
	uint16_t size;

	size = sizeof(inode_ref->inode->blocks);
	size -= sizeof(struct ext4_extent_header);
	size /= sizeof(struct ext4_extent_index);
#ifdef AGGRESSIVE_TEST
	if (size > 4)
		size = 4;
#endif
	return size;
}

/* ext4 cannot build a tree deeper than this: five levels of 4 KiB index
 * blocks address more than the 2^32-block address space. A larger value on
 * disk is corruption, and believing it means walking a path array sized for
 * something else. Linux caps it the same way. */
#define EXT4_MAX_EXTENT_DEPTH 5

static uint16_t ext4_ext_max_entries(struct ext4_inode_ref *inode_ref,
				     uint32_t depth)
{
	uint16_t max;

	if (depth == ext_depth(inode_ref->inode)) {
		if (depth == 0)
			max = ext4_ext_space_root(inode_ref);
		else
			max = ext4_ext_space_root_idx(inode_ref);
	} else {
		if (depth == 0)
			max = ext4_ext_space_block(inode_ref);
		else
			max = ext4_ext_space_block_idx(inode_ref);
	}

	return max;
}

static ext4_fsblk_t ext4_ext_find_goal(struct ext4_inode_ref *inode_ref,
				       struct ext4_extent_path *path,
				       ext4_lblk_t block)
{
	if (path) {
		uint32_t depth = path->depth;
		struct ext4_extent *ex;

		/*
		 * Try to predict block placement assuming that we are
		 * filling in a file which will eventually be
		 * non-sparse --- i.e., in the case of libbfd writing
		 * an ELF object sections out-of-order but in a way
		 * the eventually results in a contiguous object or
		 * executable file, or some database extending a table
		 * space file.  However, this is actually somewhat
		 * non-ideal if we are writing a sparse file such as
		 * qemu or KVM writing a raw image file that is going
		 * to stay fairly sparse, since it will end up
		 * fragmenting the file system's free space.  Maybe we
		 * should have some hueristics or some way to allow
		 * userspace to pass a hint to file system,
		 * especially if the latter case turns out to be
		 * common.
		 */
		ex = path[depth].extent;
		if (ex) {
			ext4_fsblk_t ext_pblk = ext4_ext_pblock(ex);
			ext4_lblk_t ext_block = to_le32(ex->first_block);

			if (block > ext_block)
				return ext_pblk + (block - ext_block);
			else
				return ext_pblk - (ext_block - block);
		}

		/* it looks like index is empty;
		 * try to find starting block from index itself */
		if (path[depth].block.lb_id)
			return path[depth].block.lb_id;
	}

	/* OK. use inode's group */
	return ext4_fs_inode_to_goal_block(inode_ref);
}

/*
 * Allocation for a meta data block
 */
static ext4_fsblk_t ext4_ext_new_meta_block(struct ext4_inode_ref *inode_ref,
					    struct ext4_extent_path *path,
					    struct ext4_extent *ex, int *err,
					    uint32_t flags)
{
	ext4_fsblk_t goal, newblock;

	goal = ext4_ext_find_goal(inode_ref, path, to_le32(ex->first_block));
	newblock = ext4_new_meta_blocks(inode_ref, goal, flags, NULL, err);
	return newblock;
}

#if CONFIG_META_CSUM_ENABLE
static uint32_t ext4_ext_block_csum(struct ext4_inode_ref *inode_ref,
				    struct ext4_extent_header *eh)
{
	uint32_t checksum = 0;
	struct ext4_sblock *sb = &inode_ref->fs->sb;

	if (ext4_sb_feature_ro_com(sb, EXT4_FRO_COM_METADATA_CSUM)) {
		uint32_t ino_index = to_le32(inode_ref->index);
		uint32_t ino_gen =
		    to_le32(ext4_inode_get_generation(inode_ref->inode));
		/* First calculate crc32 checksum against fs uuid */
		checksum = ext4_sb_csum_seed(sb);
		/* Then calculate crc32 checksum against inode number
		 * and inode generation */
		checksum = ext4_crc32c(checksum, &ino_index, sizeof(ino_index));
		checksum = ext4_crc32c(checksum, &ino_gen, sizeof(ino_gen));
		/* Finally calculate crc32 checksum against
		 * the entire extent block up to the checksum field */
		checksum =
		    ext4_crc32c(checksum, eh, EXT4_EXTENT_TAIL_OFFSET(eh));
	}
	return checksum;
}
#else
#define ext4_ext_block_csum(...) 0
#endif

static void
ext4_extent_block_csum_set(struct ext4_inode_ref *inode_ref __unused,
			   struct ext4_extent_header *eh)
{
	struct ext4_extent_tail *tail;

	tail = find_ext4_extent_tail(eh);
	tail->et_checksum = to_le32(ext4_ext_block_csum(inode_ref, eh));
}

static int ext4_ext_dirty(struct ext4_inode_ref *inode_ref,
			  struct ext4_extent_path *path)
{
	if (path->block.lb_id)
		ext4_trans_set_block_dirty(path->block.buf);
	else
		inode_ref->dirty = true;

	return EOK;
}

static void ext4_ext_drop_refs(struct ext4_inode_ref *inode_ref,
			       struct ext4_extent_path *path, bool keep_other)
{
	int32_t depth, i;

	if (!path)
		return;
	if (keep_other)
		depth = 0;
	else
		depth = path->depth;

	for (i = 0; i <= depth; i++, path++) {
		if (path->block.lb_id) {
			if (ext4_bcache_test_flag(path->block.buf, BC_DIRTY))
				ext4_extent_block_csum_set(inode_ref,
							   path->header);

			ext4_block_set(inode_ref->fs->bdev, &path->block);
		}
	}
}

/*
 * Check that whether the basic information inside the extent header
 * is correct or not.
 */
static int ext4_ext_check(struct ext4_inode_ref *inode_ref,
			  struct ext4_extent_header *eh, uint16_t depth,
			  ext4_fsblk_t pblk __unused)
{
	struct ext4_extent_tail *tail;
	struct ext4_sblock *sb = &inode_ref->fs->sb;
	const char *error_msg;
	(void)error_msg;

	if (to_le16(eh->magic) != EXT4_EXTENT_MAGIC) {
		error_msg = "invalid magic";
		goto corrupted;
	}
	if (to_le16(eh->depth) != depth) {
		error_msg = "unexpected eh_depth";
		goto corrupted;
	}
	if (eh->max_entries_count == 0) {
		error_msg = "invalid eh_max";
		goto corrupted;
	}
	/* eh_max has to fit the space that actually holds the entries: 60 bytes
	 * inside the inode for the root, one block for anything deeper. Without
	 * this the count is believed, and every user of it walks off the end --
	 * the binary search below reads entries past the buffer, and the
	 * checksum helpers read (and on a write path, write) at
	 * 12 + 12 * eh_max, which for eh_max = 0xFFFF is 786 KB beyond a 4 KB
	 * block. Reproduced with AddressSanitizer: reading one file on a volume
	 * whose inode carries eh_max = 0xFFFF is a heap-buffer-overflow in
	 * ext4_ext_binsearch, reached from a plain directory listing. */
	if (to_le16(eh->max_entries_count) >
	    ext4_ext_max_entries(inode_ref, depth)) {
		error_msg = "eh_max too large for the space it describes";
		goto corrupted;
	}
	if (to_le16(eh->entries_count) > to_le16(eh->max_entries_count)) {
		error_msg = "invalid eh_entries";
		goto corrupted;
	}

	/* Only a real extent BLOCK carries a tail checksum. pblk 0 is the
	 * header living in the inode's own i_block, where the sixty bytes hold
	 * four extents and nothing else: find_ext4_extent_tail() then points
	 * just past them, at whatever the inode has there, and the comparison
	 * is against noise. The root's integrity comes from the inode
	 * checksum, which covers it already.
	 *
	 * This fired on every extent-mapped file -- twenty-two times in one
	 * suite run -- and was invisible until DBG_WARN was routed to the
	 * logger. A check that cries wolf on healthy volumes is worse than no
	 * check, because the first real one gets read as more of the same. */
	if (pblk != 0 && ext4_sb_feature_ro_com(sb, EXT4_FRO_COM_METADATA_CSUM)) {
		tail = find_ext4_extent_tail(eh);
		if (tail->et_checksum !=
		    to_le32(ext4_ext_block_csum(inode_ref, eh))) {
			ext4_dbg(DEBUG_EXTENT,
				 DBG_WARN "Extent block checksum failed."
					  "Blocknr: %" PRIu64 "\n",
				 pblk);
		}
	}

	return EOK;

corrupted:
	ext4_dbg(DEBUG_EXTENT, "Bad extents B+ tree block: %s. "
			       "Blocknr: %" PRId64 "\n",
		 error_msg, pblk);
	return EIO;
}

static int read_extent_tree_block(struct ext4_inode_ref *inode_ref,
				  ext4_fsblk_t pblk, int32_t depth,
				  struct ext4_block *bh,
				  uint32_t flags __unused)
{
	int err;

	err = ext4_trans_block_get(inode_ref->fs->bdev, bh, pblk);
	if (err != EOK)
		goto errout;

	err = ext4_ext_check(inode_ref, ext_block_hdr(bh), depth, pblk);
	if (err != EOK)
		goto errout;

	return EOK;
errout:
	if (bh->lb_id)
		ext4_block_set(inode_ref->fs->bdev, bh);

	return err;
}

/*
 * ext4_ext_binsearch_idx:
 * binary search for the closest index of the given block
 * the header must be checked before calling this
 */
static void ext4_ext_binsearch_idx(struct ext4_extent_path *path,
				   ext4_lblk_t block)
{
	struct ext4_extent_header *eh = path->header;
	struct ext4_extent_index *r, *l, *m;

	l = EXT_FIRST_INDEX(eh) + 1;
	r = EXT_LAST_INDEX(eh);
	while (l <= r) {
		m = l + (r - l) / 2;
		if (block < to_le32(m->first_block))
			r = m - 1;
		else
			l = m + 1;
	}

	path->index = l - 1;
}

/*
 * ext4_ext_binsearch:
 * binary search for closest extent of the given block
 * the header must be checked before calling this
 */
static void ext4_ext_binsearch(struct ext4_extent_path *path, ext4_lblk_t block)
{
	struct ext4_extent_header *eh = path->header;
	struct ext4_extent *r, *l, *m;

	if (eh->entries_count == 0) {
		/*
		 * this leaf is empty:
		 * we get such a leaf in split/add case
		 */
		return;
	}

	l = EXT_FIRST_EXTENT(eh) + 1;
	r = EXT_LAST_EXTENT(eh);

	while (l <= r) {
		m = l + (r - l) / 2;
		if (block < to_le32(m->first_block))
			r = m - 1;
		else
			l = m + 1;
	}

	path->extent = l - 1;
}

static int ext4_find_extent(struct ext4_inode_ref *inode_ref, ext4_lblk_t block,
			    struct ext4_extent_path **orig_path, uint32_t flags)
{
	struct ext4_extent_header *eh;
	struct ext4_block bh = EXT4_BLOCK_ZERO();
	ext4_fsblk_t buf_block = 0;
	struct ext4_extent_path *path = *orig_path;
	int32_t depth, ppos = 0;
	int32_t i;
	int ret;

	eh = ext_inode_hdr(inode_ref->inode);
	depth = ext_depth(inode_ref->inode);

	/* The root lives in the inode and never passed through
	 * read_extent_tree_block(), so nothing had checked it: every deeper
	 * block was validated and the one the walk starts from was not. A
	 * corrupt root is the cheapest way to reach the overflow, since it
	 * needs no valid checksum anywhere. */
	if (depth > EXT4_MAX_EXTENT_DEPTH) {
		ext4_dbg(DEBUG_EXTENT, DBG_ERROR
			 "extent tree depth %" PRId32 " is impossible\n", depth);
		return EIO;
	}
	ret = ext4_ext_check(inode_ref, eh, (uint16_t)depth, 0);
	if (ret != EOK)
		return ret;

	if (path) {
		ext4_ext_drop_refs(inode_ref, path, 0);
		if (depth > path[0].maxdepth) {
			ext4_free(path);
			*orig_path = path = NULL;
		}
	}
	if (!path) {
		int32_t path_depth = depth + 1;
		/* account possible depth increase */
		path = ext4_calloc(1, sizeof(struct ext4_extent_path) *
				     (path_depth + 1));
		if (!path)
			return ENOMEM;
		path[0].maxdepth = path_depth;
	}
	path[0].header = eh;
	path[0].block = bh;

	i = depth;
	/* walk through the tree */
	while (i) {
		ext4_ext_binsearch_idx(path + ppos, block);
		path[ppos].p_block = ext4_idx_pblock(path[ppos].index);
		path[ppos].depth = i;
		path[ppos].extent = NULL;
		buf_block = path[ppos].p_block;

		i--;
		ppos++;
		if (!path[ppos].block.lb_id ||
		    path[ppos].block.lb_id != buf_block) {
			ret = read_extent_tree_block(inode_ref, buf_block, i,
						     &bh, flags);
			if (ret != EOK) {
				goto err;
			}
			if (ppos > depth) {
				ext4_block_set(inode_ref->fs->bdev, &bh);
				ret = EIO;
				goto err;
			}

			eh = ext_block_hdr(&bh);
			path[ppos].block = bh;
			path[ppos].header = eh;
		}
	}

	path[ppos].depth = i;
	path[ppos].extent = NULL;
	path[ppos].index = NULL;

	/* find extent */
	ext4_ext_binsearch(path + ppos, block);
	/* if not an empty leaf */
	if (path[ppos].extent)
		path[ppos].p_block = ext4_ext_pblock(path[ppos].extent);

	*orig_path = path;

	ret = EOK;
	return ret;

err:
	ext4_ext_drop_refs(inode_ref, path, 0);
	ext4_free(path);
	if (orig_path)
		*orig_path = NULL;
	return ret;
}

static void ext4_ext_init_header(struct ext4_inode_ref *inode_ref,
				 struct ext4_extent_header *eh, int32_t depth)
{
	eh->entries_count = 0;
	eh->max_entries_count = to_le16(ext4_ext_max_entries(inode_ref, depth));
	eh->magic = to_le16(EXT4_EXTENT_MAGIC);
	eh->depth = depth;
}

static int ext4_ext_insert_index(struct ext4_inode_ref *inode_ref,
				 struct ext4_extent_path *path, int at,
				 ext4_lblk_t insert_index,
				 ext4_fsblk_t insert_block, bool set_to_ix)
{
	struct ext4_extent_index *ix;
	struct ext4_extent_path *curp = path + at;
	int len, err;
	struct ext4_extent_header *eh;

	if (curp->index && insert_index == to_le32(curp->index->first_block))
		return EIO;

	if (to_le16(curp->header->entries_count) ==
	    to_le16(curp->header->max_entries_count))
		return EIO;

	eh = curp->header;
	if (curp->index == NULL) {
		ix = EXT_FIRST_INDEX(eh);
		curp->index = ix;
	} else if (insert_index > to_le32(curp->index->first_block)) {
		/* insert after */
		ix = curp->index + 1;
	} else {
		/* insert before */
		ix = curp->index;
	}

	if (ix > EXT_MAX_INDEX(eh))
		return EIO;

	len = EXT_LAST_INDEX(eh) - ix + 1;
	ext4_assert(len >= 0);
	if (len > 0)
		memmove(ix + 1, ix, len * sizeof(struct ext4_extent_index));

	ix->first_block = to_le32(insert_index);
	ext4_idx_store_pblock(ix, insert_block);
	eh->entries_count = to_le16(to_le16(eh->entries_count) + 1);

	if (ix > EXT_LAST_INDEX(eh)) {
		err = EIO;
		goto out;
	}

	err = ext4_ext_dirty(inode_ref, curp);

out:
	if (err == EOK && set_to_ix) {
		curp->index = ix;
		curp->p_block = ext4_idx_pblock(ix);
	}
	return err;
}

static int ext4_ext_split_node(struct ext4_inode_ref *inode_ref,
			       struct ext4_extent_path *path, int at,
			       struct ext4_extent *newext,
			       struct ext4_extent_path *npath,
			       bool *ins_right_leaf)
{
	int i, npath_at, ret;
	ext4_lblk_t insert_index;
	ext4_fsblk_t newblock = 0;
	int depth = ext_depth(inode_ref->inode);
	npath_at = depth - at;

	ext4_assert(at > 0);

	if (path[depth].extent != EXT_MAX_EXTENT(path[depth].header))
		insert_index = path[depth].extent[1].first_block;
	else
		insert_index = newext->first_block;

	for (i = depth; i >= at; i--, npath_at--) {
		struct ext4_block bh = EXT4_BLOCK_ZERO();

		/* FIXME: currently we split at the point after the current
		 * extent. */
		newblock =
		    ext4_ext_new_meta_block(inode_ref, path, newext, &ret, 0);
		if (ret != EOK)
			goto cleanup;

		/*  For write access.*/
		ret = ext4_trans_block_get_noread(inode_ref->fs->bdev, &bh,
						  newblock);
		if (ret != EOK)
			goto cleanup;

		/* Only the header and the entries moved here are written; the
		 * rest of the block would otherwise go to the medium as
		 * whatever the cache slot last held. */
		memset(bh.data, 0, ext4_sb_get_block_size(&inode_ref->fs->sb));

		if (i == depth) {
			/* start copy from next extent */
			int m = EXT_MAX_EXTENT(path[i].header) - path[i].extent;
			struct ext4_extent_header *neh;
			struct ext4_extent *ex;
			neh = ext_block_hdr(&bh);
			ex = EXT_FIRST_EXTENT(neh);
			ext4_ext_init_header(inode_ref, neh, 0);
			if (m) {
				memmove(ex, path[i].extent + 1,
					sizeof(struct ext4_extent) * m);
				neh->entries_count =
				    to_le16(to_le16(neh->entries_count) + m);
				path[i].header->entries_count = to_le16(
				    to_le16(path[i].header->entries_count) - m);
				ret = ext4_ext_dirty(inode_ref, path + i);
				if (ret != EOK)
					goto cleanup;

				npath[npath_at].p_block = ext4_ext_pblock(ex);
				npath[npath_at].extent = ex;
			} else {
				npath[npath_at].p_block = 0;
				npath[npath_at].extent = NULL;
			}

			npath[npath_at].depth = to_le16(neh->depth);
			npath[npath_at].maxdepth = 0;
			npath[npath_at].index = NULL;
			npath[npath_at].header = neh;
			npath[npath_at].block = bh;

			ext4_trans_set_block_dirty(bh.buf);
		} else {
			int m = EXT_MAX_INDEX(path[i].header) - path[i].index;
			struct ext4_extent_header *neh;
			struct ext4_extent_index *ix;
			neh = ext_block_hdr(&bh);
			ix = EXT_FIRST_INDEX(neh);
			ext4_ext_init_header(inode_ref, neh, depth - i);
			ix->first_block = to_le32(insert_index);
			ext4_idx_store_pblock(ix,
					      npath[npath_at + 1].block.lb_id);
			neh->entries_count = to_le16(1);
			if (m) {
				memmove(ix + 1, path[i].index + 1,
					sizeof(struct ext4_extent) * m);
				neh->entries_count =
				    to_le16(to_le16(neh->entries_count) + m);
				path[i].header->entries_count = to_le16(
				    to_le16(path[i].header->entries_count) - m);
				ret = ext4_ext_dirty(inode_ref, path + i);
				if (ret != EOK)
					goto cleanup;
			}

			npath[npath_at].p_block = ext4_idx_pblock(ix);
			npath[npath_at].depth = to_le16(neh->depth);
			npath[npath_at].maxdepth = 0;
			npath[npath_at].extent = NULL;
			npath[npath_at].index = ix;
			npath[npath_at].header = neh;
			npath[npath_at].block = bh;

			ext4_trans_set_block_dirty(bh.buf);
		}
	}
	newblock = 0;

	/*
	 * If newext->first_block can be included into the
	 * right sub-tree.
	 */
	if (to_le32(newext->first_block) < insert_index)
		*ins_right_leaf = false;
	else
		*ins_right_leaf = true;

	ret = ext4_ext_insert_index(inode_ref, path, at - 1, insert_index,
				    npath[0].block.lb_id, *ins_right_leaf);

cleanup:
	if (ret != EOK) {
		if (newblock)
			ext4_ext_free_blocks(inode_ref, newblock, 1, 0);

		npath_at = depth - at;
		while (npath_at >= 0) {
			if (npath[npath_at].block.lb_id) {
				newblock = npath[npath_at].block.lb_id;
				ext4_block_set(inode_ref->fs->bdev,
					       &npath[npath_at].block);
				ext4_ext_free_blocks(inode_ref, newblock, 1, 0);
				memset(&npath[npath_at].block, 0,
				       sizeof(struct ext4_block));
			}
			npath_at--;
		}
	}
	return ret;
}

/*
 * ext4_ext_correct_indexes:
 * if leaf gets modified and modified extent is first in the leaf,
 * then we have to correct all indexes above.
 */
static int ext4_ext_correct_indexes(struct ext4_inode_ref *inode_ref,
				    struct ext4_extent_path *path)
{
	struct ext4_extent_header *eh;
	int32_t depth = ext_depth(inode_ref->inode);
	struct ext4_extent *ex;
	uint32_t border;
	int32_t k;
	int err = EOK;

	eh = path[depth].header;
	ex = path[depth].extent;

	if (ex == NULL || eh == NULL)
		return EIO;

	if (depth == 0) {
		/* there is no tree at all */
		return EOK;
	}

	if (ex != EXT_FIRST_EXTENT(eh)) {
		/* we correct tree if first leaf got modified only */
		return EOK;
	}

	k = depth - 1;
	border = path[depth].extent->first_block;
	path[k].index->first_block = border;
	err = ext4_ext_dirty(inode_ref, path + k);
	if (err != EOK)
		return err;

	while (k--) {
		/* change all left-side indexes */
		if (path[k + 1].index != EXT_FIRST_INDEX(path[k + 1].header))
			break;
		path[k].index->first_block = border;
		err = ext4_ext_dirty(inode_ref, path + k);
		if (err != EOK)
			break;
	}

	return err;
}

static inline bool ext4_ext_can_prepend(struct ext4_extent *ex1,
					struct ext4_extent *ex2)
{
	/* Merging a written extent into an unwritten one (or the reverse)
	 * would hand the merged run whichever state ex1 happens to carry --
	 * data silently reinterpreted as zeros, or preallocated garbage
	 * exposed as data. Adjacency was the only test here until unwritten
	 * extents gained a writer. */
	if (ext4_ext_is_unwritten(ex1) != ext4_ext_is_unwritten(ex2))
		return 0;

	if (ext4_ext_pblock(ex2) + ext4_ext_get_actual_len(ex2) !=
	    ext4_ext_pblock(ex1))
		return 0;

#ifdef AGGRESSIVE_TEST
	if (ext4_ext_get_actual_len(ex1) + ext4_ext_get_actual_len(ex2) > 4)
		return 0;
#else
	if (ext4_ext_is_unwritten(ex1)) {
		if (ext4_ext_get_actual_len(ex1) +
			ext4_ext_get_actual_len(ex2) >
		    EXT_UNWRITTEN_MAX_LEN)
			return 0;
	} else if (ext4_ext_get_actual_len(ex1) + ext4_ext_get_actual_len(ex2) >
		   EXT_INIT_MAX_LEN)
		return 0;
#endif

	if (to_le32(ex2->first_block) + ext4_ext_get_actual_len(ex2) !=
	    to_le32(ex1->first_block))
		return 0;

	return 1;
}

static inline bool ext4_ext_can_append(struct ext4_extent *ex1,
				       struct ext4_extent *ex2)
{
	/* Same state test as can_prepend, same reason. */
	if (ext4_ext_is_unwritten(ex1) != ext4_ext_is_unwritten(ex2))
		return 0;

	if (ext4_ext_pblock(ex1) + ext4_ext_get_actual_len(ex1) !=
	    ext4_ext_pblock(ex2))
		return 0;

#ifdef AGGRESSIVE_TEST
	if (ext4_ext_get_actual_len(ex1) + ext4_ext_get_actual_len(ex2) > 4)
		return 0;
#else
	if (ext4_ext_is_unwritten(ex1)) {
		if (ext4_ext_get_actual_len(ex1) +
			ext4_ext_get_actual_len(ex2) >
		    EXT_UNWRITTEN_MAX_LEN)
			return 0;
	} else if (ext4_ext_get_actual_len(ex1) + ext4_ext_get_actual_len(ex2) >
		   EXT_INIT_MAX_LEN)
		return 0;
#endif

	if (to_le32(ex1->first_block) + ext4_ext_get_actual_len(ex1) !=
	    to_le32(ex2->first_block))
		return 0;

	return 1;
}

static int ext4_ext_insert_leaf(struct ext4_inode_ref *inode_ref,
				struct ext4_extent_path *path, int at,
				struct ext4_extent *newext, int flags,
				bool *need_split)
{
	struct ext4_extent_path *curp = path + at;
	struct ext4_extent *ex = curp->extent;
	int len, err, unwritten;
	struct ext4_extent_header *eh;

	*need_split = false;

	if (curp->extent &&
	    to_le32(newext->first_block) == to_le32(curp->extent->first_block))
		return EIO;

	if (!(flags & EXT4_EXT_NO_COMBINE)) {
		if (curp->extent && ext4_ext_can_append(curp->extent, newext)) {
			unwritten = ext4_ext_is_unwritten(curp->extent);
			curp->extent->block_count =
			    to_le16(ext4_ext_get_actual_len(curp->extent) +
				    ext4_ext_get_actual_len(newext));
			if (unwritten)
				ext4_ext_mark_unwritten(curp->extent);

			err = ext4_ext_dirty(inode_ref, curp);
			goto out;
		}

		if (curp->extent &&
		    ext4_ext_can_prepend(curp->extent, newext)) {
			unwritten = ext4_ext_is_unwritten(curp->extent);
			curp->extent->first_block = newext->first_block;
			curp->extent->block_count =
			    to_le16(ext4_ext_get_actual_len(curp->extent) +
				    ext4_ext_get_actual_len(newext));
			if (unwritten)
				ext4_ext_mark_unwritten(curp->extent);

			err = ext4_ext_dirty(inode_ref, curp);
			goto out;
		}
	}

	if (to_le16(curp->header->entries_count) ==
	    to_le16(curp->header->max_entries_count)) {
		err = EIO;
		*need_split = true;
		goto out;
	} else {
		eh = curp->header;
		if (curp->extent == NULL) {
			ex = EXT_FIRST_EXTENT(eh);
			curp->extent = ex;
		} else if (to_le32(newext->first_block) >
			   to_le32(curp->extent->first_block)) {
			/* insert after */
			ex = curp->extent + 1;
		} else {
			/* insert before */
			ex = curp->extent;
		}
	}

	len = EXT_LAST_EXTENT(eh) - ex + 1;
	ext4_assert(len >= 0);
	if (len > 0)
		memmove(ex + 1, ex, len * sizeof(struct ext4_extent));

	if (ex > EXT_MAX_EXTENT(eh)) {
		err = EIO;
		goto out;
	}

	ex->first_block = newext->first_block;
	ex->block_count = newext->block_count;
	ext4_ext_store_pblock(ex, ext4_ext_pblock(newext));
	eh->entries_count = to_le16(to_le16(eh->entries_count) + 1);

	if (ex > EXT_LAST_EXTENT(eh)) {
		err = EIO;
		goto out;
	}

	err = ext4_ext_correct_indexes(inode_ref, path);
	if (err != EOK)
		goto out;
	err = ext4_ext_dirty(inode_ref, curp);

out:
	if (err == EOK) {
		curp->extent = ex;
		curp->p_block = ext4_ext_pblock(ex);
	}

	return err;
}

/*
 * ext4_ext_grow_indepth:
 * implements tree growing procedure:
 * - allocates new block
 * - moves top-level data (index block or leaf) into the new block
 * - initializes new top-level, creating index that points to the
 *   just created block
 */
static int ext4_ext_grow_indepth(struct ext4_inode_ref *inode_ref,
				 uint32_t flags)
{
	struct ext4_extent_header *neh;
	struct ext4_block bh = EXT4_BLOCK_ZERO();
	ext4_fsblk_t newblock, goal = 0;
	int err = EOK;

	/* Try to prepend new index to old one */
	if (ext_depth(inode_ref->inode))
		goal = ext4_idx_pblock(
		    EXT_FIRST_INDEX(ext_inode_hdr(inode_ref->inode)));
	else
		goal = ext4_fs_inode_to_goal_block(inode_ref);

	newblock = ext4_new_meta_blocks(inode_ref, goal, flags, NULL, &err);
	if (newblock == 0)
		return err;

	/* # */
	err = ext4_trans_block_get_noread(inode_ref->fs->bdev, &bh, newblock);
	if (err == EOK) {
		/* _noread hands back whatever the cache slot held. Only the
		 * first 60 bytes are written below, so without this the rest
		 * of the block reaches the medium as recycled heap -- another
		 * file's data, in the general case -- and the block's checksum
		 * is computed over it. */
		memset(bh.data, 0, ext4_sb_get_block_size(&inode_ref->fs->sb));
	}
	if (err != EOK) {
		ext4_ext_free_blocks(inode_ref, newblock, 1, 0);
		return err;
	}

	/* move top-level index/leaf into new block */
	memmove(bh.data, inode_ref->inode->blocks,
		sizeof(inode_ref->inode->blocks));

	/* set size of new block */
	neh = ext_block_hdr(&bh);
	/* old root could have indexes or leaves
	 * so calculate e_max right way */
	if (ext_depth(inode_ref->inode))
		neh->max_entries_count =
		    to_le16(ext4_ext_space_block_idx(inode_ref));
	else
		neh->max_entries_count =
		    to_le16(ext4_ext_space_block(inode_ref));

	neh->magic = to_le16(EXT4_EXTENT_MAGIC);
	ext4_extent_block_csum_set(inode_ref, neh);

	/* Update top-level index: num,max,pointer */
	neh = ext_inode_hdr(inode_ref->inode);
	neh->entries_count = to_le16(1);
	ext4_idx_store_pblock(EXT_FIRST_INDEX(neh), newblock);
	if (neh->depth == 0) {
		/* Root extent block becomes index block */
		neh->max_entries_count =
		    to_le16(ext4_ext_space_root_idx(inode_ref));
		EXT_FIRST_INDEX(neh)
		    ->first_block = EXT_FIRST_EXTENT(neh)->first_block;
	}
	neh->depth = to_le16(to_le16(neh->depth) + 1);

	ext4_trans_set_block_dirty(bh.buf);
	inode_ref->dirty = true;
	ext4_block_set(inode_ref->fs->bdev, &bh);

	return err;
}

static inline void ext4_ext_replace_path(struct ext4_inode_ref *inode_ref,
					 struct ext4_extent_path *path,
					 struct ext4_extent_path *newpath,
					 int at)
{
	ext4_ext_drop_refs(inode_ref, path + at, 1);
	path[at] = *newpath;
	memset(newpath, 0, sizeof(struct ext4_extent_path));
}

int ext4_ext_insert_extent(struct ext4_inode_ref *inode_ref,
			   struct ext4_extent_path **ppath,
			   struct ext4_extent *newext, int flags)
{
	int depth, level = 0, ret = 0;
	struct ext4_extent_path *path = *ppath;
	struct ext4_extent_path *npath = NULL;
	bool ins_right_leaf = false;
	bool need_split;

again:
	depth = ext_depth(inode_ref->inode);
	ret = ext4_ext_insert_leaf(inode_ref, path, depth, newext, flags,
				   &need_split);
	if (ret == EIO && need_split == true) {
		int i;
		for (i = depth, level = 0; i >= 0; i--, level++)
			if (EXT_HAS_FREE_INDEX(path + i))
				break;

		/* Do we need to grow the tree? */
		if (i < 0) {
			ret = ext4_ext_grow_indepth(inode_ref, 0);
			if (ret != EOK)
				goto out;

			ret = ext4_find_extent(
			    inode_ref, to_le32(newext->first_block), ppath, 0);
			if (ret != EOK)
				goto out;

			path = *ppath;
			/*
			 * After growing the tree, there should be free space in
			 * the only child node of the root.
			 */
			level--;
			depth++;
		}

		i = depth - (level - 1);
		/* We split from leaf to the i-th node */
		if (level > 0) {
			npath = ext4_calloc(1, sizeof(struct ext4_extent_path) *
					      (level));
			if (!npath) {
				ret = ENOMEM;
				goto out;
			}
			ret = ext4_ext_split_node(inode_ref, path, i, newext,
						  npath, &ins_right_leaf);
			if (ret != EOK)
				goto out;

			while (--level >= 0) {
				if (ins_right_leaf)
					ext4_ext_replace_path(inode_ref, path,
							      &npath[level],
							      i + level);
				else if (npath[level].block.lb_id)
					ext4_ext_drop_refs(inode_ref,
							   npath + level, 1);
			}
		}
		goto again;
	}

out:
	if (ret != EOK) {
		if (path)
			ext4_ext_drop_refs(inode_ref, path, 0);

		while (--level >= 0 && npath) {
			if (npath[level].block.lb_id) {
				ext4_fsblk_t block = npath[level].block.lb_id;
				ext4_ext_free_blocks(inode_ref, block, 1, 0);
				ext4_ext_drop_refs(inode_ref, npath + level, 1);
			}
		}
	}
	if (npath)
		ext4_free(npath);

	return ret;
}

static void ext4_ext_remove_blocks(struct ext4_inode_ref *inode_ref,
				   struct ext4_extent *ex, ext4_lblk_t from,
				   ext4_lblk_t to)
{
	ext4_lblk_t len = to - from + 1;
	ext4_lblk_t num;
	ext4_fsblk_t start;
	num = from - to_le32(ex->first_block);
	start = ext4_ext_pblock(ex) + num;
	ext4_dbg(DEBUG_EXTENT,
		 "Freeing %" PRIu32 " at %" PRIu64 ", %" PRIu32 "\n", from,
		 start, len);

	ext4_ext_free_blocks(inode_ref, start, len, 0);
}

static int ext4_ext_remove_idx(struct ext4_inode_ref *inode_ref,
			       struct ext4_extent_path *path, int32_t depth)
{
	int err = EOK;
	int32_t i = depth;
	ext4_fsblk_t leaf;

	/* free index block */
	leaf = ext4_idx_pblock(path[i].index);

	if (path[i].index != EXT_LAST_INDEX(path[i].header)) {
		ptrdiff_t len = EXT_LAST_INDEX(path[i].header) - path[i].index;
		memmove(path[i].index, path[i].index + 1,
			len * sizeof(struct ext4_extent_index));
	}

	path[i].header->entries_count =
	    to_le16(to_le16(path[i].header->entries_count) - 1);
	err = ext4_ext_dirty(inode_ref, path + i);
	if (err != EOK)
		return err;

	ext4_dbg(DEBUG_EXTENT, "IDX: Freeing %" PRIu32 " at %" PRIu64 ", %d\n",
		 to_le32(path[i].index->first_block), leaf, 1);
	ext4_ext_free_blocks(inode_ref, leaf, 1, 0);

	/*
	 * We may need to correct the paths after the first extents/indexes in
	 * a node being modified.
	 *
	 * We do not need to consider whether there's any extents presenting or
	 * not, as garbage will be cleared soon.
	 */
	while (i > 0) {
		if (path[i].index != EXT_FIRST_INDEX(path[i].header))
			break;

		path[i - 1].index->first_block = path[i].index->first_block;
		err = ext4_ext_dirty(inode_ref, path + i - 1);
		if (err != EOK)
			break;

		i--;
	}
	return err;
}

static int ext4_ext_remove_leaf(struct ext4_inode_ref *inode_ref,
				struct ext4_extent_path *path, ext4_lblk_t from,
				ext4_lblk_t to)
{

	int32_t depth = ext_depth(inode_ref->inode);
	struct ext4_extent *ex = path[depth].extent;
	struct ext4_extent *start_ex, *ex2 = NULL;
	struct ext4_extent_header *eh = path[depth].header;
	int32_t len;
	int err = EOK;
	uint16_t new_entries;

	start_ex = ex;
	new_entries = to_le16(eh->entries_count);
	while (ex <= EXT_LAST_EXTENT(path[depth].header) &&
	       to_le32(ex->first_block) <= to) {
		int32_t new_len = 0;
		int unwritten;
		ext4_lblk_t start, new_start;
		ext4_fsblk_t newblock;
		new_start = start = to_le32(ex->first_block);
		len = ext4_ext_get_actual_len(ex);
		newblock = ext4_ext_pblock(ex);
		/*
		 * The 1st case:
		 *   The position that we start truncation is inside the range of an
		 *   extent. Here we should calculate the new length of that extent and
		 *   may start the removal from the next extent.
		 */
		if (start < from) {
			len -= from - start;
			new_len = from - start;
			start = from;
			start_ex++;
		} else {
			/*
			 * The second case:
			 *   The last block to be truncated is inside the range of an
			 *   extent. We need to calculate the new length and the new
			 *   start of the extent.
			 */
			if (start + len - 1 > to) {
				new_len = start + len - 1 - to;
				len -= new_len;
				new_start = to + 1;
				newblock += to + 1 - start;
				ex2 = ex;
			}
		}

		ext4_ext_remove_blocks(inode_ref, ex, start, start + len - 1);
		/*
		 * Set the first block of the extent if it is presented.
		 */
		ex->first_block = to_le32(new_start);

		/*
		 * If the new length of the current extent we are working on is
		 * zero, remove it.
		 */
		if (!new_len)
			new_entries--;
		else {
			unwritten = ext4_ext_is_unwritten(ex);
			ex->block_count = to_le16(new_len);
			ext4_ext_store_pblock(ex, newblock);
			if (unwritten)
				ext4_ext_mark_unwritten(ex);
		}

		ex += 1;
	}

	if (ex2 == NULL)
		ex2 = ex;

	/*
	 * Move any remaining extents to the starting position of the node.
	 */
	if (ex2 <= EXT_LAST_EXTENT(eh))
		memmove(start_ex, ex2, (EXT_LAST_EXTENT(eh) - ex2 + 1) *
					   sizeof(struct ext4_extent));

	eh->entries_count = to_le16(new_entries);
	ext4_ext_dirty(inode_ref, path + depth);

	/*
	 * If the extent pointer is pointed to the first extent of the node, and
	 * there's still extents presenting, we may need to correct the indexes
	 * of the paths.
	 */
	if (path[depth].extent == EXT_FIRST_EXTENT(eh) && eh->entries_count) {
		err = ext4_ext_correct_indexes(inode_ref, path);
		if (err != EOK)
			return err;
	}

	/* if this leaf is free, then we should
	 * remove it from index block above */
	if (eh->entries_count == 0 && path[depth].block.lb_id)
		err = ext4_ext_remove_idx(inode_ref, path, depth - 1);
	else if (depth > 0)
		path[depth - 1].index++;

	return err;
}

/*
 * Check if there's more to remove at a specific level.
 */
static bool ext4_ext_more_to_rm(struct ext4_extent_path *path, ext4_lblk_t to)
{
	if (!to_le16(path->header->entries_count))
		return false;

	if (path->index > EXT_LAST_INDEX(path->header))
		return false;

	if (to_le32(path->index->first_block) > to)
		return false;

	return true;
}

int ext4_extent_remove_space(struct ext4_inode_ref *inode_ref, ext4_lblk_t from,
			     ext4_lblk_t to)
{
	struct ext4_extent_path *path = NULL;
	int ret = EOK;
	int32_t depth = ext_depth(inode_ref->inode);
	int32_t i;

	ret = ext4_find_extent(inode_ref, from, &path, 0);
	if (ret != EOK)
		goto out;

	if (!path[depth].extent) {
		ret = EOK;
		goto out;
	}

	bool in_range = IN_RANGE(from, to_le32(path[depth].extent->first_block),
				 ext4_ext_get_actual_len(path[depth].extent));

	if (!in_range) {
		ret = EOK;
		goto out;
	}

	/* If we do remove_space inside the range of an extent */
	if ((to_le32(path[depth].extent->first_block) < from) &&
	    (to < to_le32(path[depth].extent->first_block) +
		      ext4_ext_get_actual_len(path[depth].extent) - 1)) {

		struct ext4_extent *ex = path[depth].extent, newex;
		int unwritten = ext4_ext_is_unwritten(ex);
		ext4_lblk_t ee_block = to_le32(ex->first_block);
		int32_t len = ext4_ext_get_actual_len(ex);
		ext4_fsblk_t newblock = to + 1 - ee_block + ext4_ext_pblock(ex);

		ex->block_count = to_le16(from - ee_block);
		if (unwritten)
			ext4_ext_mark_unwritten(ex);

		ext4_ext_dirty(inode_ref, path + depth);

		newex.first_block = to_le32(to + 1);
		newex.block_count = to_le16(ee_block + len - 1 - to);
		ext4_ext_store_pblock(&newex, newblock);
		if (unwritten)
			ext4_ext_mark_unwritten(&newex);

		ret = ext4_ext_insert_extent(inode_ref, &path, &newex, 0);
		goto out;
	}

	i = depth;
	while (i >= 0) {
		if (i == depth) {
			struct ext4_extent_header *eh;
			struct ext4_extent *first_ex, *last_ex;
			ext4_lblk_t leaf_from, leaf_to;
			eh = path[i].header;
			ext4_assert(to_le16(eh->entries_count) > 0);
			first_ex = EXT_FIRST_EXTENT(eh);
			last_ex = EXT_LAST_EXTENT(eh);
			leaf_from = to_le32(first_ex->first_block);
			leaf_to = to_le32(last_ex->first_block) +
				  ext4_ext_get_actual_len(last_ex) - 1;
			if (leaf_from < from)
				leaf_from = from;

			if (leaf_to > to)
				leaf_to = to;

			ext4_ext_remove_leaf(inode_ref, path, leaf_from,
					     leaf_to);
			ext4_ext_drop_refs(inode_ref, path + i, 0);
			i--;
			continue;
		}

		struct ext4_extent_header *eh;
		eh = path[i].header;
		if (ext4_ext_more_to_rm(path + i, to)) {
			struct ext4_block bh = EXT4_BLOCK_ZERO();
			if (path[i + 1].block.lb_id)
				ext4_ext_drop_refs(inode_ref, path + i + 1, 0);

			ret = read_extent_tree_block(
			    inode_ref, ext4_idx_pblock(path[i].index),
			    depth - i - 1, &bh, 0);
			if (ret != EOK)
				goto out;

			path[i].p_block = ext4_idx_pblock(path[i].index);
			path[i + 1].block = bh;
			path[i + 1].header = ext_block_hdr(&bh);
			path[i + 1].depth = depth - i - 1;
			if (i + 1 == depth)
				path[i + 1].extent =
				    EXT_FIRST_EXTENT(path[i + 1].header);
			else
				path[i + 1].index =
				    EXT_FIRST_INDEX(path[i + 1].header);

			i++;
		} else {
			if (i > 0) {
				/*
				 * Garbage entries will finally be cleared here.
				 */
				if (!eh->entries_count)
					ret = ext4_ext_remove_idx(inode_ref,
								  path, i - 1);
				else
					path[i - 1].index++;
			}

			if (i)
				ext4_block_set(inode_ref->fs->bdev,
					       &path[i].block);

			i--;
		}
	}

	/* TODO: flexible tree reduction should be here */
	if (path->header->entries_count == 0) {
		/*
		 * truncate to zero freed all the tree,
		 * so we need to correct eh_depth
		 */
		ext_inode_hdr(inode_ref->inode)->depth = 0;
		ext_inode_hdr(inode_ref->inode)->max_entries_count =
		    to_le16(ext4_ext_space_root(inode_ref));
		ret = ext4_ext_dirty(inode_ref, path);
	}

out:
	ext4_ext_drop_refs(inode_ref, path, 0);
	ext4_free(path);
	path = NULL;
	return ret;
}

static int ext4_ext_split_extent_at(struct ext4_inode_ref *inode_ref,
				    struct ext4_extent_path **ppath,
				    ext4_lblk_t split, uint32_t split_flag)
{
	struct ext4_extent *ex, newex;
	ext4_fsblk_t newblock;
	ext4_lblk_t ee_block;
	int32_t ee_len;
	int32_t depth = ext_depth(inode_ref->inode);
	int err = EOK;

	ex = (*ppath)[depth].extent;
	ee_block = to_le32(ex->first_block);
	ee_len = ext4_ext_get_actual_len(ex);
	newblock = split - ee_block + ext4_ext_pblock(ex);

	if (split == ee_block) {
		/*
		 * case b: block @split is the block that the extent begins with
		 * then we just change the state of the extent, and splitting
		 * is not needed.
		 */
		if (split_flag & EXT4_EXT_MARK_UNWRIT2)
			ext4_ext_mark_unwritten(ex);
		else
			ext4_ext_mark_initialized(ex);

		err = ext4_ext_dirty(inode_ref, *ppath + depth);
		goto out;
	}

	ex->block_count = to_le16(split - ee_block);
	if (split_flag & EXT4_EXT_MARK_UNWRIT1)
		ext4_ext_mark_unwritten(ex);

	err = ext4_ext_dirty(inode_ref, *ppath + depth);
	if (err != EOK)
		goto out;

	newex.first_block = to_le32(split);
	newex.block_count = to_le16(ee_len - (split - ee_block));
	ext4_ext_store_pblock(&newex, newblock);
	if (split_flag & EXT4_EXT_MARK_UNWRIT2)
		ext4_ext_mark_unwritten(&newex);
	err = ext4_ext_insert_extent(inode_ref, ppath, &newex,
				     EXT4_EXT_NO_COMBINE);
	if (err != EOK)
		goto restore_extent_len;

out:
	return err;
restore_extent_len:
	ex->block_count = to_le16(ee_len);
	err = ext4_ext_dirty(inode_ref, *ppath + depth);
	return err;
}

/* Fold the extent after `ex` into it, if the two are one run.
 *
 * Returns true when an entry was absorbed, leaving `ex` longer and the leaf
 * one entry shorter. The state test lives in ext4_ext_can_append: a written
 * and an unwritten extent never merge, because the survivor would carry one
 * state for both runs.
 */
static bool ext4_ext_merge_next(struct ext4_extent_header *eh,
				struct ext4_extent *ex)
{
	struct ext4_extent *last = EXT_LAST_EXTENT(eh);

	if (ex >= last || !ext4_ext_can_append(ex, ex + 1))
		return false;

	uint16_t len = ext4_ext_get_actual_len(ex) +
		       ext4_ext_get_actual_len(ex + 1);
	bool unwritten = ext4_ext_is_unwritten(ex);

	ex->block_count = to_le16(len);
	if (unwritten)
		ext4_ext_mark_unwritten(ex);

	if (ex + 1 < last)
		memmove(ex + 1, ex + 2,
			(size_t)(last - (ex + 1)) *
				sizeof(struct ext4_extent));

	eh->entries_count = to_le16(to_le16(eh->entries_count) - 1);
	return true;
}

/* Put back together what converting a range took apart.
 *
 * ext4_ext_convert_to_initialized splits an extent to change the state of a
 * piece of it, and a caller converting a preallocated file a chunk at a time
 * therefore left one extent per chunk: 3 MB in four where a plain write of the
 * same bytes is one, 512 MB in 256 against ten. Since macOS preallocates
 * before every large copy, that was every copied file. Nothing was wrong with
 * the result -- it is a valid tree, and the data reads back correctly -- but it
 * is deeper than it needs to be, e2fsck asks to narrow it, and depth is what
 * exposed the stale-path bug this file carries a fix for.
 *
 * Backwards first, so `ex` ends up pointing at the surviving entry either way.
 * The leaf's first extent is never the one absorbed, so the parent index keeps
 * its key and no correction upward is needed.
 */
static int ext4_ext_try_to_merge(struct ext4_inode_ref *inode_ref,
				 struct ext4_extent_path *path)
{
	int32_t depth = ext_depth(inode_ref->inode);
	struct ext4_extent_header *eh = path[depth].header;
	struct ext4_extent *ex = path[depth].extent;
	bool merged = false;

	if (!eh || !ex)
		return EOK;

	while (ex > EXT_FIRST_EXTENT(eh) &&
	       ext4_ext_merge_next(eh, ex - 1)) {
		ex--;
		merged = true;
	}

	while (ext4_ext_merge_next(eh, ex))
		merged = true;

	if (!merged)
		return EOK;

	path[depth].extent = ex;
	return ext4_ext_dirty(inode_ref, path + depth);
}

static int ext4_ext_convert_to_initialized(struct ext4_inode_ref *inode_ref,
					   struct ext4_extent_path **ppath,
					   ext4_lblk_t split, uint32_t blocks)
{
	int32_t depth = ext_depth(inode_ref->inode), err = EOK;
	struct ext4_extent *ex = (*ppath)[depth].extent;

	ext4_assert(to_le32(ex->first_block) <= split);

	if (split + blocks ==
	    to_le32(ex->first_block) + ext4_ext_get_actual_len(ex)) {
		/* split and initialize right part */
		err = ext4_ext_split_extent_at(inode_ref, ppath, split,
					       EXT4_EXT_MARK_UNWRIT1);
	} else if (to_le32(ex->first_block) == split) {
		/* split and initialize left part */
		err = ext4_ext_split_extent_at(inode_ref, ppath, split + blocks,
					       EXT4_EXT_MARK_UNWRIT2);
	} else {
		/* split 1 extent to 3 and initialize the 2nd */
		err = ext4_ext_split_extent_at(inode_ref, ppath, split + blocks,
					       EXT4_EXT_MARK_UNWRIT1 |
						   EXT4_EXT_MARK_UNWRIT2);
		if (err == EOK) {
			/*
			 * Re-find before the second split. The first one can
			 * grow the tree -- a leaf that is already full is split
			 * to make room -- and ext4_ext_split_extent_at reads
			 * (*ppath)[depth].extent directly, without looking it
			 * up. So the path handed to it here may point into a
			 * leaf that no longer holds `split`, and the second
			 * split then rewrites the wrong extent, leaving a tree
			 * whose index no longer agrees with its leaves.
			 *
			 * Only this three-way case is exposed, because only it
			 * splits twice; and only a caller converting the MIDDLE
			 * of an unwritten extent reaches it, which is what
			 * ext4_extent_mark_written() (patch 0046) does for every
			 * preallocated write. e2fsck calls the result "invalid
			 * extent node", and a 64 MB file copied into
			 * preallocated space then reads back EIO.
			 *
			 * Linux does the same re-find at the same point, for the
			 * same stated reason.
			 */
			err = ext4_find_extent(inode_ref, split, ppath, 0);
		}
		if (err == EOK) {
			err = ext4_ext_split_extent_at(inode_ref, ppath, split,
						       EXT4_EXT_MARK_UNWRIT1);
		}
	}

	return err;
}

static ext4_lblk_t ext4_ext_next_allocated_block(struct ext4_extent_path *path)
{
	int32_t depth;

	depth = path->depth;

	if (depth == 0 && path->extent == NULL)
		return EXT_MAX_BLOCKS;

	while (depth >= 0) {
		if (depth == path->depth) {
			/* leaf */
			if (path[depth].extent &&
			    path[depth].extent !=
				EXT_LAST_EXTENT(path[depth].header))
				return to_le32(
				    path[depth].extent[1].first_block);
		} else {
			/* index */
			if (path[depth].index !=
			    EXT_LAST_INDEX(path[depth].header))
				return to_le32(
				    path[depth].index[1].first_block);
		}
		depth--;
	}

	return EXT_MAX_BLOCKS;
}

static int ext4_ext_zero_unwritten_range(struct ext4_inode_ref *inode_ref,
					 ext4_fsblk_t block,
					 uint32_t blocks_count)
{
	int err = EOK;
	uint32_t block_size = ext4_sb_get_block_size(&inode_ref->fs->sb);

	/* The range is contiguous by construction, so it can be zeroed in runs
	 * rather than a command per block. It matters because this is not a
	 * rare path: macOS preallocates a large file before copying into it,
	 * which is what an unwritten extent is, so every Finder copy of any
	 * size lands here. Measured on a USB stick, 100 MB written into a
	 * preallocated file cost 25,941 device commands where the same write
	 * into a fresh file cost 167, and the copy ran at 6 MB/s. */
	uint32_t chunk_blocks = (1u << 20) / block_size;
	if (chunk_blocks == 0)
		chunk_blocks = 1;
	if (chunk_blocks > blocks_count)
		chunk_blocks = blocks_count;

	void *zeros = ext4_calloc(chunk_blocks, block_size);
	while (!zeros && chunk_blocks > 1) {
		/* Memory pressure is not a reason to fail a write; it is a
		 * reason to do it in smaller pieces. */
		chunk_blocks /= 2;
		zeros = ext4_calloc(chunk_blocks, block_size);
	}
	if (!zeros)
		return ENOMEM;

	/* Straight to the medium, not through the cache -- for coherence, not
	 * speed. The file write this conversion serves also writes its data
	 * directly (ext4_block_writebytes); the old version left the zeroed
	 * blocks dirty in the block cache, where a later cache flush would
	 * have written them out AFTER the caller's data and replaced it with
	 * zeros. Zeroing on the medium first and dropping any cached copy
	 * gives the caller a clean base its direct write can land on. It also
	 * keeps data blocks out of the journal, where the transaction-dirty
	 * path would have put them. */
	for (uint32_t done = 0; done < blocks_count; ) {
		uint32_t n = blocks_count - done;
		if (n > chunk_blocks)
			n = chunk_blocks;

		err = ext4_blocks_set_direct(inode_ref->fs->bdev, zeros,
					     block + done, n);
		if (err != EOK)
			break;
		done += n;
	}
	ext4_bcache_invalidate_lba(inode_ref->fs->bdev->bc, block,
				   blocks_count);
	ext4_free(zeros);
	return err;
}

__unused static void print_path(struct ext4_extent_path *path)
{
	int32_t i = path->depth;
	while (i >= 0) {

		ptrdiff_t a =
		    (path->extent)
			? (path->extent - EXT_FIRST_EXTENT(path->header))
			: 0;
		ptrdiff_t b =
		    (path->index)
			? (path->index - EXT_FIRST_INDEX(path->header))
			: 0;

		(void)a;
		(void)b;
		ext4_dbg(DEBUG_EXTENT,
			 "depth %" PRId32 ", p_block: %" PRIu64 ","
			 "p_ext offset: %td, p_idx offset: %td\n",
			 i, path->p_block, a, b);
		i--;
		path++;
	}
}

/**@brief Locate an already-allocated range without converting it.
 *
 * ext4_extent_get_blocks() answers an unwritten extent one of two ways: with
 * create it zeroes the range and marks it written, and without create it
 * reports no block at all. Neither suits a caller that is about to overwrite
 * every byte: zeroing writes the whole range twice, and refusing to name the
 * blocks means it cannot write them at all.
 *
 * This reports where the range lives and whether it is still unwritten,
 * changing nothing. The caller writes its data and then calls
 * ext4_extent_mark_written(), so the extent stays unwritten until the data is
 * on the medium -- a crash in between leaves it unwritten, which reads back
 * as zeros rather than exposing whatever those blocks held before. That
 * ordering is the whole reason the zeroing exists, and it is what makes
 * skipping it safe.
 *
 * @param inode_ref   the inode
 * @param iblock      first logical block
 * @param max_blocks  how many the caller can use
 * @param result      out: first physical block, or 0 if not allocated
 * @param blocks_count out: contiguous blocks found from @iblock
 * @param unwritten   out: true if the range is an unwritten extent
 * @return standard error code */
int ext4_extent_map_range(struct ext4_inode_ref *inode_ref, ext4_lblk_t iblock,
			  uint32_t max_blocks, ext4_fsblk_t *result,
			  uint32_t *blocks_count, bool *unwritten)
{
	struct ext4_extent_path *path = NULL;
	struct ext4_extent *ex;
	int err = EOK;
	int32_t depth;

	if (result)
		*result = 0;
	if (blocks_count)
		*blocks_count = 0;
	if (unwritten)
		*unwritten = false;

	err = ext4_find_extent(inode_ref, iblock, &path, 0);
	if (err != EOK)
		return err;

	depth = ext_depth(inode_ref->inode);
	ex = path[depth].extent;
	if (ex) {
		ext4_lblk_t ee_block = to_le32(ex->first_block);
		ext4_fsblk_t ee_start = ext4_ext_pblock(ex);
		uint16_t ee_len = ext4_ext_get_actual_len(ex);

		if (IN_RANGE(iblock, ee_block, ee_len)) {
			uint32_t allocated = ee_len - (iblock - ee_block);
			if (allocated > max_blocks)
				allocated = max_blocks;

			if (result)
				*result = iblock - ee_block + ee_start;
			if (blocks_count)
				*blocks_count = allocated;
			if (unwritten)
				*unwritten = ext4_ext_is_unwritten(ex);
		}
	}

	ext4_ext_drop_refs(inode_ref, path, 0);
	ext4_free(path);
	return EOK;
}

/**@brief Mark an unwritten range initialized, without zeroing it.
 *
 * For a caller that has just written every byte of the range through
 * ext4_extent_map_range(). No zeroing: the blocks hold the caller's data, and
 * zeroing them now would erase it.
 *
 * @param inode_ref    the inode
 * @param iblock       first logical block
 * @param blocks_count how many to mark
 * @return standard error code */
int ext4_extent_mark_written(struct ext4_inode_ref *inode_ref,
			     ext4_lblk_t iblock, uint32_t blocks_count)
{
	struct ext4_extent_path *path = NULL;
	struct ext4_extent *ex;
	int err;
	int32_t depth;

	if (blocks_count == 0)
		return EOK;

	err = ext4_find_extent(inode_ref, iblock, &path, 0);
	if (err != EOK)
		return err;

	depth = ext_depth(inode_ref->inode);
	ex = path[depth].extent;
	if (!ex) {
		err = EIO;
		goto out;
	}

	/* Already written -- nothing owed. */
	if (!ext4_ext_is_unwritten(ex))
		goto out;

	err = ext4_ext_convert_to_initialized(inode_ref, &path, iblock,
					      blocks_count);
	if (err == EOK) {
		/* Re-find before merging: the conversion split the extent and
		 * may have split the leaf with it, so the path in hand can
		 * point at the wrong one. */
		err = ext4_find_extent(inode_ref, iblock, &path, 0);
		if (err == EOK)
			err = ext4_ext_try_to_merge(inode_ref, path);
	}
out:
	if (path) {
		ext4_ext_drop_refs(inode_ref, path, 0);
		ext4_free(path);
	}
	return err;
}

int ext4_extent_get_blocks(struct ext4_inode_ref *inode_ref, ext4_lblk_t iblock,
			   uint32_t max_blocks, ext4_fsblk_t *result,
			   bool create, uint32_t *blocks_count)
{
	struct ext4_extent_path *path = NULL;
	struct ext4_extent newex, *ex;
	ext4_fsblk_t goal;
	int err = EOK;
	int32_t depth;
	uint32_t allocated = 0;
	ext4_lblk_t next;
	ext4_fsblk_t newblock;

	if (result)
		*result = 0;

	if (blocks_count)
		*blocks_count = 0;

	/* find extent for this block */
	err = ext4_find_extent(inode_ref, iblock, &path, 0);
	if (err != EOK) {
		path = NULL;
		goto out2;
	}

	depth = ext_depth(inode_ref->inode);

	/*
	 * consistent leaf must not be empty
	 * this situations is possible, though, _during_ tree modification
	 * this is why assert can't be put in ext4_ext_find_extent()
	 */
	ex = path[depth].extent;
	if (ex) {
		ext4_lblk_t ee_block = to_le32(ex->first_block);
		ext4_fsblk_t ee_start = ext4_ext_pblock(ex);
		uint16_t ee_len = ext4_ext_get_actual_len(ex);
		/* if found exent covers block, simple return it */
		if (IN_RANGE(iblock, ee_block, ee_len)) {
			/* number of remain blocks in the extent */
			allocated = ee_len - (iblock - ee_block);

			if (!ext4_ext_is_unwritten(ex)) {
				newblock = iblock - ee_block + ee_start;
				goto out;
			}

			if (!create) {
				newblock = 0;
				goto out;
			}

			uint32_t zero_range;
			zero_range = allocated;
			if (zero_range > max_blocks)
				zero_range = max_blocks;

			newblock = iblock - ee_block + ee_start;
			err = ext4_ext_zero_unwritten_range(inode_ref, newblock,
							    zero_range);
			if (err != EOK)
				goto out2;

			err = ext4_ext_convert_to_initialized(
			    inode_ref, &path, iblock, zero_range);
			if (err != EOK)
				goto out2;

			goto out;
		}
	}

	/*
	 * requested block isn't allocated yet
	 * we couldn't try to create block if create flag is zero
	 */
	if (!create) {
		goto out2;
	}

	/* find next allocated block so that we know how many
	 * blocks we can allocate without ovelapping next extent */
	next = ext4_ext_next_allocated_block(path);
	allocated = next - iblock;
	if (allocated > max_blocks)
		allocated = max_blocks;

	/* allocate new block */
	goal = ext4_ext_find_goal(inode_ref, path, iblock);
	newblock = ext4_new_meta_blocks(inode_ref, goal, 0, &allocated, &err);
	if (!newblock)
		goto out2;

	/* try to insert new extent into found leaf and return */
	newex.first_block = to_le32(iblock);
	ext4_ext_store_pblock(&newex, newblock);
	newex.block_count = to_le16(allocated);
	err = ext4_ext_insert_extent(inode_ref, &path, &newex, 0);
	if (err != EOK) {
		/* free data blocks we just allocated */
		ext4_ext_free_blocks(inode_ref, ext4_ext_pblock(&newex),
				     to_le16(newex.block_count), 0);
		goto out2;
	}

	/* previous routine could use block we allocated */
	newblock = ext4_ext_pblock(&newex);

out:
	if (allocated > max_blocks)
		allocated = max_blocks;

	if (result)
		*result = newblock;

	if (blocks_count)
		*blocks_count = allocated;

out2:
	if (path) {
		ext4_ext_drop_refs(inode_ref, path, 0);
		ext4_free(path);
	}

	return err;
}

/* Preallocate: back [iblock, iblock+count) with UNWRITTEN extents.
 *
 * The one origin of unwritten extents in this tree. Everything downstream
 * already existed, unreachable, before this: reads treat unwritten as a hole,
 * ext4_extent_get_blocks converts in place on write -- zeroing what the write
 * does not cover, splitting when it covers part of an extent -- truncate
 * masks the state bit out of lengths, and the merge predicates now refuse to
 * merge across the written/unwritten boundary.
 *
 * Allocation is block-at-a-time and relies on the merge in insert_leaf to
 * coalesce runs; ranges already backed by an extent (either state) are
 * skipped, so preallocating over existing data is harmless. *allocated
 * reports only blocks newly allocated here.
 */
int ext4_extent_preallocate(struct ext4_inode_ref *inode_ref,
			    ext4_lblk_t iblock, uint32_t count,
			    uint32_t *allocated)
{
	int err = EOK;
	uint32_t done = 0;

	if (allocated)
		*allocated = 0;

	while (done < count) {
		struct ext4_extent_path *path = NULL;
		struct ext4_extent *ex;
		struct ext4_extent newex;
		ext4_lblk_t at = iblock + done;
		int32_t depth;

		err = ext4_find_extent(inode_ref, at, &path, 0);
		if (err != EOK)
			return err;

		depth = ext_depth(inode_ref->inode);
		ex = path[depth].extent;
		if (ex) {
			ext4_lblk_t ee_block = to_le32(ex->first_block);
			uint16_t ee_len = ext4_ext_get_actual_len(ex);
			if (IN_RANGE(at, ee_block, ee_len)) {
				/* Already backed; skip to its end. */
				done += ee_len - (at - ee_block);
				goto next;
			}
		}

		{
			ext4_lblk_t gap_end =
				ext4_ext_next_allocated_block(path);
			ext4_fsblk_t goal =
				ext4_ext_find_goal(inode_ref, path, at);
			uint32_t want = 1;
			ext4_fsblk_t block =
				ext4_new_meta_blocks(inode_ref, goal, 0,
						     &want, &err);
			(void)gap_end;
			if (!block)
				goto fail;

			newex.first_block = to_le32(at);
			ext4_ext_store_pblock(&newex, block);
			newex.block_count = to_le16(want);
			ext4_ext_mark_unwritten(&newex);
			err = ext4_ext_insert_extent(inode_ref, &path,
						     &newex, 0);
			if (err != EOK) {
				ext4_ext_free_blocks(inode_ref, block, want,
						     0);
				goto fail;
			}
			done += want;
			if (allocated)
				*allocated += want;
		}
next:
		ext4_ext_drop_refs(inode_ref, path, 0);
		ext4_free(path);
		continue;
fail:
		ext4_ext_drop_refs(inode_ref, path, 0);
		ext4_free(path);
		return err;
	}
	return EOK;
}

/* What backs one logical block: a physical block, a run length within its
 * extent, and whether that extent is unwritten. fblock 0 with unwritten
 * false is a genuine hole (run = the gap up to the next extent). A read-only
 * question the mapping API cannot answer -- ext4_fs_get_inode_dblk_idx folds
 * holes and unwritten extents into the same 0. */
int ext4_extent_probe(struct ext4_inode_ref *inode_ref, ext4_lblk_t iblock,
		      ext4_fsblk_t *fblock, uint32_t *run_len,
		      bool *unwritten)
{
	struct ext4_extent_path *path = NULL;
	struct ext4_extent *ex;
	int32_t depth;
	int err;

	*fblock = 0;
	*run_len = 0;
	*unwritten = false;

	err = ext4_find_extent(inode_ref, iblock, &path, 0);
	if (err != EOK)
		return err;

	depth = ext_depth(inode_ref->inode);
	ex = path[depth].extent;
	if (ex) {
		ext4_lblk_t ee_block = to_le32(ex->first_block);
		uint16_t ee_len = ext4_ext_get_actual_len(ex);
		if (IN_RANGE(iblock, ee_block, ee_len)) {
			*fblock = ext4_ext_pblock(ex) + (iblock - ee_block);
			*run_len = ee_len - (iblock - ee_block);
			*unwritten = ext4_ext_is_unwritten(ex) != 0;
			goto out;
		}
	}
	{
		ext4_lblk_t next = ext4_ext_next_allocated_block(path);
		*run_len = (next == EXT_MAX_BLOCKS) ? 0 : (next - iblock);
	}
out:
	ext4_ext_drop_refs(inode_ref, path, 0);
	ext4_free(path);
	return EOK;
}

#endif
