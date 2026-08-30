/*
 * Copyright (c) 2015 Grzegorz Kostka (kostka.grzegorz@gmail.com)
 * Copyright (c) 2015 Kaho Ng (ngkaho1234@gmail.com)
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *
 * - Redistributions of source code must retain the above copyright
 *   notice, this list of conditions and the following disclaimer.
 * - Redistributions in binary form must reproduce the above copyright
 *   notice, this list of conditions and the following disclaimer in the
 *   documentation and/or other materials provided with the distribution.
 * - The name of the author may not be used to endorse or promote products
 *   derived from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
 * IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
 * OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
 * IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT,
 * INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
 * NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 * DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
 * THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
 * THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

/** @addtogroup lwext4
 * @{
 */
/**
 * @file  ext4_journal.c
 * @brief Journal handle functions
 */

#include <ext4_config.h>
#include <ext4_types.h>
#include <ext4_misc.h>
#include <ext4_errno.h>
#include <ext4_debug.h>

#include <ext4_fs.h>
#include <ext4_super.h>
#include <ext4_inode.h>
#include <ext4_journal.h>
#include <ext4_blockdev.h>
#include <ext4_crc32.h>
#include <ext4_journal.h>

#include <string.h>
#include <stdlib.h>

/**@brief  Revoke entry during journal replay.*/
struct revoke_entry {
	/**@brief  Block number not to be replayed.*/
	ext4_fsblk_t block;

	/**@brief  For any transaction id smaller
	 *         than trans_id, records of @block
	 *         in those transactions should not
	 *         be replayed.*/
	uint32_t trans_id;

	/**@brief  Revoke tree node.*/
	RB_ENTRY(revoke_entry) revoke_node;
};

/**@brief  Valid journal replay information.*/
struct recover_info {
	/**@brief  Starting transaction id.*/
	uint32_t start_trans_id;

	/**@brief  Ending transaction id.*/
	uint32_t last_trans_id;

	/**@brief  Used as internal argument.*/
	uint32_t this_trans_id;

	/**@brief  No of transactions went through.*/
	uint32_t trans_cnt;

	/**@brief  Revoke blocks the scan pass saw. The scan walks at
	 *         least as far as the revoke pass will; if it saw none,
	 *         the revoke pass would re-read every header block of the
	 *         log to build an empty tree, and is skipped. */
	uint32_t revoke_block_cnt;

	/**@brief  RB-Tree storing revoke entries.*/
	RB_HEAD(jbd_revoke, revoke_entry) revoke_root;

	/**@brief  Read-ahead window over the journal region; NULL outside
	 *         the recovery pass, and when memory was not available. */
	struct jbd_replay_wnd *wnd;

	/**@brief  Write-back batch for replayed blocks; NULL outside the
	 *         recovery pass, and when memory was not available. */
	struct jbd_replay_wb *wb;

	/**@brief  First error the tag-replay callback hit. The iteration
	 *         API returns void, and losing a write error here means
	 *         clearing a journal whose contents never reached the
	 *         medium. */
	int rc;
};

/**@brief  Journal replay internal arguments.*/
struct replay_arg {
	/**@brief  Journal replay information.*/
	struct recover_info *info;

	/**@brief  Current block we are on.*/
	uint32_t *this_block;

	/**@brief  Current trans_id we are on.*/
	uint32_t this_trans_id;
};

/**@brief  Read-ahead window over the journal region.
 *
 * The recovery pass walks the log strictly forward, yet fetched it through
 * the block cache one block at a time: one device command per 4 KiB. On a
 * medium with a fixed per-command cost -- every USB stick -- that priced a
 * large journal at minutes, and DiskArbitration abandons a mount long before
 * that. Replay is the one caller that knows its access pattern is a linear
 * sweep, so it reads the region in physically-contiguous runs into this
 * window and serves blocks from memory.
 *
 * The window bypasses the block cache deliberately: nothing writes journal
 * blocks between jbd_recover()'s first read and its last, so there is no
 * newer copy a cache could hold. */
struct jbd_replay_wnd {
	/**@brief  The window: up to @cap journal blocks, contiguous. */
	uint8_t *data;

	/**@brief  Stable copy of the descriptor block being replayed.
	 *         Tag replay refills the window mid-iteration; the
	 *         descriptor it is iterating must not move under it. */
	uint8_t *desc;

	/**@brief  Journal block index of data[0]. */
	uint32_t first;

	/**@brief  Valid blocks in the window; 0 means empty. */
	uint32_t cnt;

	/**@brief  Window capacity, blocks. */
	uint32_t cap;
};

/**@brief  How much journal one device command may fetch during replay.
 *         Large enough to amortise the per-command cost, small enough
 *         that a mount never holds more than this much read-ahead. */
#define JBD_REPLAY_WND_BYTES (1024 * 1024)

/**@brief  Serve one journal block from the read-ahead window, refilling
 *         it with the longest physically-contiguous run starting at the
 *         requested block when it misses.
 * @param  jbd_fs jbd filesystem
 * @param  w      the window
 * @param  iblock journal block index to read
 * @param  data   out: pointer into the window, valid until the next call
 * @return standard error code*/
static int jbd_replay_wnd_read(struct jbd_fs *jbd_fs,
			       struct jbd_replay_wnd *w,
			       uint32_t iblock,
			       void **data)
{
	uint32_t bs = jbd_fs->bdev->lg_bsize;
	int rc;

	if (!(w->cnt && iblock >= w->first && iblock - w->first < w->cnt)) {
		/* Refill. The sweep never reads past the end of the log
		 * area within one transaction -- wrap() sends the caller
		 * back to `first` and the next request misses here -- so
		 * a fill never wraps either. */
		uint32_t want = jbd_get32(&jbd_fs->sb, maxlen) - iblock;
		ext4_fsblk_t fblock;
		uint32_t run = 1;

		if (want > w->cap)
			want = w->cap;
		if (want == 0)
			return EINVAL;

		rc = jbd_inode_bmap(jbd_fs, iblock, &fblock);
		if (rc != EOK)
			return rc;

		while (run < want) {
			ext4_fsblk_t next;
			rc = jbd_inode_bmap(jbd_fs, iblock + run, &next);
			if (rc != EOK || next != fblock + run)
				break;
			run++;
		}

		rc = ext4_blocks_get_direct(jbd_fs->bdev, w->data,
					    fblock, run);
		if (rc != EOK)
			return rc;

		w->first = iblock;
		w->cnt = run;
	}

	*data = w->data + (size_t)(iblock - w->first) * bs;
	return EOK;
}

/**@brief  Set up the recovery read-ahead window. Best-effort: on memory
 *         pressure recovery falls back to per-block reads, which are
 *         slow and correct.
 * @param  jbd_fs jbd filesystem
 * @param  info   journal replay info*/
static void jbd_replay_wnd_init(struct jbd_fs *jbd_fs,
				struct recover_info *info)
{
	uint32_t bs = jbd_fs->bdev->lg_bsize;
	uint32_t cap = JBD_REPLAY_WND_BYTES / bs;
	struct jbd_replay_wnd *w;

	info->wnd = NULL;
	if (cap == 0)
		return;

	w = ext4_calloc(1, sizeof(*w));
	if (!w)
		return;

	w->data = ext4_malloc((size_t)cap * bs);
	w->desc = ext4_malloc(bs);
	if (!w->data || !w->desc) {
		ext4_free(w->data);
		ext4_free(w->desc);
		ext4_free(w);
		return;
	}

	w->cap = cap;
	info->wnd = w;
}

static void jbd_replay_wnd_fini(struct recover_info *info)
{
	if (!info->wnd)
		return;
	ext4_free(info->wnd->data);
	ext4_free(info->wnd->desc);
	ext4_free(info->wnd);
	info->wnd = NULL;
}

/**@brief  Write-back batch for replayed blocks.
 *
 * Replay used to push every replayed block through the block cache and
 * flush it on release: one device command per block, in log order, which
 * is target-random -- and a hot block logged in two hundred transactions
 * was written two hundred times. This batch collects replayed copies and
 * writes them out sorted, deduplicated (last logged copy wins, which is
 * what sequential replay also ends with), and coalesced into one command
 * per physically-contiguous run.
 *
 * It bypasses the block cache for the same reason the read window does:
 * during recovery nothing else is writing. The one wrinkle is a block
 * that is *already resident* -- the journal inode's own metadata, group
 * descriptors read while opening the journal -- where a stale cached
 * copy would outlive our direct write and could later be flushed over
 * it. jbd_replay_wb_sync_bcache() rewrites those residents in place. */
struct jbd_replay_wb {
	/**@brief  Replayed payload, arrival order, @cap blocks. */
	uint8_t *data;

	/**@brief  Target block of data[i]. */
	uint64_t *lba;

	/**@brief  Scratch for assembling one contiguous run. */
	uint8_t *gather;

	/**@brief  Blocks collected so far. */
	uint32_t cnt;

	/**@brief  Batch capacity, blocks. */
	uint32_t cap;
};

/**@brief  How much replayed data may wait for write-back. The batch is
 *         also the dedup horizon: a block re-logged within this much
 *         journal is written once, not once per transaction. */
#define JBD_REPLAY_WB_BYTES (4 * 1024 * 1024)

/**@brief  Sort key for the flush: by target block, ties broken by
 *         arrival so the newest copy of a block sorts last. */
struct jbd_wb_sort {
	uint64_t lba;
	uint32_t idx;
};

static int jbd_wb_cmp(const void *__a, const void *__b)
{
	const struct jbd_wb_sort *a = __a;
	const struct jbd_wb_sort *b = __b;
	if (a->lba != b->lba)
		return a->lba < b->lba ? -1 : 1;
	return a->idx < b->idx ? -1 : 1;
}

/**@brief  Bring a cache-resident copy of @lba in line with the bytes
 *         replay is about to put on the medium. Rare -- only blocks the
 *         journal machinery itself had reason to read are resident
 *         during recovery -- but a stale resident copy is worse than
 *         slow: released dirty, it would be flushed over the replayed
 *         data afterwards. */
static void jbd_replay_wb_sync_bcache(struct ext4_blockdev *bdev,
				      uint64_t lba, const void *data)
{
	struct ext4_block b;
	struct ext4_buf *buf = ext4_bcache_find_get(bdev->bc, &b, lba);
	if (!buf)
		return;

	memcpy(buf->data, data, bdev->lg_bsize);
	ext4_bcache_set_flag(buf, BC_UPTODATE);
	/* The medium is about to match: whatever dirt the buffer carried
	 * is superseded by the replayed copy being written directly. */
	ext4_bcache_clear_flag(buf, BC_DIRTY);
	ext4_block_set(bdev, &b);
}

/**@brief  Write the batch out: newest copy per block, ascending block
 *         order, one device command per contiguous run.
 * @param  jbd_fs jbd filesystem
 * @param  wb     the batch
 * @return standard error code*/
static int jbd_replay_wb_flush(struct jbd_fs *jbd_fs,
			       struct jbd_replay_wb *wb)
{
	struct ext4_blockdev *bdev = jbd_fs->bdev;
	uint32_t bs = bdev->lg_bsize;
	struct jbd_wb_sort *order;
	uint32_t i, n = 0;
	int rc = EOK;

	if (!wb->cnt)
		return EOK;

	order = ext4_malloc((size_t)wb->cnt * sizeof(*order));
	if (!order)
		return ENOMEM;

	for (i = 0; i < wb->cnt; i++) {
		order[i].lba = wb->lba[i];
		order[i].idx = i;
	}
	qsort(order, wb->cnt, sizeof(*order), jbd_wb_cmp);

	/* Equal blocks now sit together, newest last. Keep only that
	 * one: it is the state sequential replay would have ended with. */
	for (i = 0; i < wb->cnt; i++) {
		if (i + 1 < wb->cnt && order[i + 1].lba == order[i].lba)
			continue;
		order[n++] = order[i];
	}

	for (i = 0; i < n;) {
		uint32_t j = i + 1, k;

		while (j < n && order[j].lba == order[i].lba + (j - i))
			j++;

		for (k = i; k < j; k++) {
			const void *src =
				wb->data + (size_t)order[k].idx * bs;
			memcpy(wb->gather + (size_t)(k - i) * bs, src, bs);
			jbd_replay_wb_sync_bcache(bdev, order[k].lba, src);
		}

		rc = ext4_blocks_set_direct(bdev, wb->gather,
					    order[i].lba, j - i);
		if (rc != EOK)
			break;

		i = j;
	}

	ext4_free(order);
	wb->cnt = 0;
	return rc;
}

/**@brief  Add one replayed block to the batch, flushing first if it is
 *         full.
 * @param  jbd_fs jbd filesystem
 * @param  wb     the batch
 * @param  lba    target block
 * @param  data   the logged copy
 * @param  is_escape restore the escaped magic number
 * @return standard error code*/
static int jbd_replay_wb_record(struct jbd_fs *jbd_fs,
				struct jbd_replay_wb *wb,
				uint64_t lba, const void *data,
				bool is_escape)
{
	uint32_t bs = jbd_fs->bdev->lg_bsize;
	uint8_t *slot;
	int rc;

	if (wb->cnt == wb->cap) {
		rc = jbd_replay_wb_flush(jbd_fs, wb);
		if (rc != EOK)
			return rc;
	}

	slot = wb->data + (size_t)wb->cnt * bs;
	memcpy(slot, data, bs);
	if (is_escape)
		((struct jbd_bhdr *)slot)->magic = to_be32(JBD_MAGIC_NUMBER);

	wb->lba[wb->cnt] = lba;
	wb->cnt++;
	return EOK;
}

/**@brief  Set up the write-back batch. Best-effort, like the window: no
 *         memory means the slow per-block path, not a failed mount.
 * @param  jbd_fs jbd filesystem
 * @param  info   journal replay info*/
static void jbd_replay_wb_init(struct jbd_fs *jbd_fs,
			       struct recover_info *info)
{
	uint32_t bs = jbd_fs->bdev->lg_bsize;
	uint32_t cap = JBD_REPLAY_WB_BYTES / bs;
	struct jbd_replay_wb *wb;

	info->wb = NULL;
	if (cap == 0)
		return;

	wb = ext4_calloc(1, sizeof(*wb));
	if (!wb)
		return;

	wb->data = ext4_malloc((size_t)cap * bs);
	wb->lba = ext4_malloc((size_t)cap * sizeof(*wb->lba));
	wb->gather = ext4_malloc((size_t)cap * bs);
	if (!wb->data || !wb->lba || !wb->gather) {
		ext4_free(wb->data);
		ext4_free(wb->lba);
		ext4_free(wb->gather);
		ext4_free(wb);
		return;
	}

	wb->cap = cap;
	info->wb = wb;
}

static void jbd_replay_wb_fini(struct recover_info *info)
{
	if (!info->wb)
		return;
	ext4_free(info->wb->data);
	ext4_free(info->wb->lba);
	ext4_free(info->wb->gather);
	ext4_free(info->wb);
	info->wb = NULL;
}

/* Make sure we wrap around the log correctly! */
#define wrap(sb, var)						\
do {									\
	if (var >= jbd_get32((sb), maxlen))					\
		var -= (jbd_get32((sb), maxlen) - jbd_get32((sb), first));	\
} while (0)

static inline int32_t
trans_id_diff(uint32_t x, uint32_t y)
{
	int32_t diff = x - y;
	return diff;
}

static int
jbd_revoke_entry_cmp(struct revoke_entry *a, struct revoke_entry *b)
{
	if (a->block > b->block)
		return 1;
	else if (a->block < b->block)
		return -1;
	return 0;
}

static int
jbd_block_rec_cmp(struct jbd_block_rec *a, struct jbd_block_rec *b)
{
	if (a->lba > b->lba)
		return 1;
	else if (a->lba < b->lba)
		return -1;
	return 0;
}

static int
jbd_revoke_rec_cmp(struct jbd_revoke_rec *a, struct jbd_revoke_rec *b)
{
	if (a->lba > b->lba)
		return 1;
	else if (a->lba < b->lba)
		return -1;
	return 0;
}

RB_GENERATE_INTERNAL(jbd_revoke, revoke_entry, revoke_node,
		     jbd_revoke_entry_cmp, static inline)
RB_GENERATE_INTERNAL(jbd_block, jbd_block_rec, block_rec_node,
		     jbd_block_rec_cmp, static inline)
RB_GENERATE_INTERNAL(jbd_revoke_tree, jbd_revoke_rec, revoke_node,
		     jbd_revoke_rec_cmp, static inline)

#define jbd_alloc_revoke_entry() ext4_calloc(1, sizeof(struct revoke_entry))
#define jbd_free_revoke_entry(addr) ext4_free(addr)

static int jbd_has_csum(struct jbd_sb *jbd_sb)
{
	if (JBD_HAS_INCOMPAT_FEATURE(jbd_sb, JBD_FEATURE_INCOMPAT_CSUM_V2))
		return 2;

	if (JBD_HAS_INCOMPAT_FEATURE(jbd_sb, JBD_FEATURE_INCOMPAT_CSUM_V3))
		return 3;

	return 0;
}

#if CONFIG_META_CSUM_ENABLE
static uint32_t jbd_sb_csum(struct jbd_sb *jbd_sb)
{
	uint32_t checksum = 0;

	if (jbd_has_csum(jbd_sb)) {
		uint32_t orig_checksum = jbd_sb->checksum;
		jbd_set32(jbd_sb, checksum, 0);
		/* Calculate crc32c checksum against tho whole superblock */
		checksum = ext4_crc32c(EXT4_CRC32_INIT, jbd_sb,
				JBD_SUPERBLOCK_SIZE);
		jbd_sb->checksum = orig_checksum;
	}
	return checksum;
}
#else
#define jbd_sb_csum(...) 0
#endif

static void jbd_sb_csum_set(struct jbd_sb *jbd_sb)
{
	if (!jbd_has_csum(jbd_sb))
		return;

	jbd_set32(jbd_sb, checksum, jbd_sb_csum(jbd_sb));
}

#if CONFIG_META_CSUM_ENABLE
static bool
jbd_verify_sb_csum(struct jbd_sb *jbd_sb)
{
	if (!jbd_has_csum(jbd_sb))
		return true;

	return jbd_sb_csum(jbd_sb) == jbd_get32(jbd_sb, checksum);
}
#else
#define jbd_verify_sb_csum(...) true
#endif

#if CONFIG_META_CSUM_ENABLE
static uint32_t jbd_meta_csum(struct jbd_fs *jbd_fs,
			      struct jbd_bhdr *bhdr)
{
	uint32_t checksum = 0;

	if (jbd_has_csum(&jbd_fs->sb)) {
		uint32_t block_size = jbd_get32(&jbd_fs->sb, blocksize);
		struct jbd_block_tail *tail =
			(struct jbd_block_tail *)((char *)bhdr + block_size -
				sizeof(struct jbd_block_tail));
		uint32_t orig_checksum = tail->checksum;
		tail->checksum = 0;

		/* First calculate crc32c checksum against fs uuid */
		checksum = ext4_crc32c(EXT4_CRC32_INIT, jbd_fs->sb.uuid,
				       sizeof(jbd_fs->sb.uuid));
		/* Calculate crc32c checksum against tho whole block */
		checksum = ext4_crc32c(checksum, bhdr,
				block_size);
		tail->checksum = orig_checksum;
	}
	return checksum;
}
#else
#define jbd_meta_csum(...) 0
#endif

static void jbd_meta_csum_set(struct jbd_fs *jbd_fs,
			      struct jbd_bhdr *bhdr)
{
	uint32_t block_size = jbd_get32(&jbd_fs->sb, blocksize);
	struct jbd_block_tail *tail = (struct jbd_block_tail *)
				((char *)bhdr + block_size -
				sizeof(struct jbd_block_tail));
	if (!jbd_has_csum(&jbd_fs->sb))
		return;

	tail->checksum = to_be32(jbd_meta_csum(jbd_fs, bhdr));
}

#if CONFIG_META_CSUM_ENABLE
static bool
jbd_verify_meta_csum(struct jbd_fs *jbd_fs,
		     struct jbd_bhdr *bhdr)
{
	uint32_t block_size = jbd_get32(&jbd_fs->sb, blocksize);
	struct jbd_block_tail *tail = (struct jbd_block_tail *)
				((char *)bhdr + block_size -
				sizeof(struct jbd_block_tail));
	if (!jbd_has_csum(&jbd_fs->sb))
		return true;

	return jbd_meta_csum(jbd_fs, bhdr) == to_be32(tail->checksum);
}
#else
#define jbd_verify_meta_csum(...) true
#endif

#if CONFIG_META_CSUM_ENABLE
static uint32_t jbd_commit_csum(struct jbd_fs *jbd_fs,
			      struct jbd_commit_header *header)
{
	uint32_t checksum = 0;

	if (jbd_has_csum(&jbd_fs->sb)) {
		uint8_t orig_checksum_type = header->chksum_type,
			 orig_checksum_size = header->chksum_size;
		uint32_t orig_checksum = header->chksum[0];
		uint32_t block_size = jbd_get32(&jbd_fs->sb, blocksize);
		header->chksum_type = 0;
		header->chksum_size = 0;
		header->chksum[0] = 0;

		/* First calculate crc32c checksum against fs uuid */
		checksum = ext4_crc32c(EXT4_CRC32_INIT, jbd_fs->sb.uuid,
				       sizeof(jbd_fs->sb.uuid));
		/* Calculate crc32c checksum against tho whole block */
		checksum = ext4_crc32c(checksum, header,
				block_size);

		header->chksum_type = orig_checksum_type;
		header->chksum_size = orig_checksum_size;
		header->chksum[0] = orig_checksum;
	}
	return checksum;
}
#else
#define jbd_commit_csum(...) 0
#endif

static void jbd_commit_csum_set(struct jbd_fs *jbd_fs,
			      struct jbd_commit_header *header)
{
	if (!jbd_has_csum(&jbd_fs->sb))
		return;

	header->chksum_type = 0;
	header->chksum_size = 0;
	/* Big-endian, like every other field in the journal. Storing it in host
	 * order made this checksum unverifiable by anyone, including the code
	 * immediately below: jbd_verify_commit_csum compares against to_be32()
	 * of the same computation, so on a little-endian machine lwext4
	 * rejected its own commit blocks -- and so did Linux, which is why the
	 * feature could not be turned on. */
	header->chksum[0] = to_be32(jbd_commit_csum(jbd_fs, header));
}

#if CONFIG_META_CSUM_ENABLE
static bool jbd_verify_commit_csum(struct jbd_fs *jbd_fs,
				   struct jbd_commit_header *header)
{
	if (!jbd_has_csum(&jbd_fs->sb))
		return true;

	return header->chksum[0] == to_be32(jbd_commit_csum(jbd_fs,
					    header));
}
#else
#define jbd_verify_commit_csum(...) true
#endif

#if CONFIG_META_CSUM_ENABLE
/*
 * NOTE: We only make use of @csum parameter when
 *       JBD_FEATURE_COMPAT_CHECKSUM is enabled.
 */
static uint32_t jbd_block_csum(struct jbd_fs *jbd_fs, const void *buf,
			       uint32_t csum,
			       uint32_t sequence)
{
	uint32_t checksum = 0;

	if (jbd_has_csum(&jbd_fs->sb)) {
		uint32_t block_size = jbd_get32(&jbd_fs->sb, blocksize);
		/* First calculate crc32c checksum against fs uuid */
		checksum = ext4_crc32c(EXT4_CRC32_INIT, jbd_fs->sb.uuid,
				       sizeof(jbd_fs->sb.uuid));
		/* Then calculate crc32c checksum against sequence no.
		 *
		 * Big-endian, like every field in the journal: jbd2 checksums
		 * cpu_to_be32(sequence). Checksumming the host-order value made
		 * every tag verify against lwext4's own recovery and fail
		 * against Linux's -- "JBD2: Invalid checksum recovering data
		 * block N", on every block of every transaction, so a journal
		 * this driver left dirty could not be recovered by the kernel
		 * at all. */
		uint32_t seq_be = to_be32(sequence);
		checksum = ext4_crc32c(checksum, &seq_be,
				sizeof(uint32_t));
		/* Calculate crc32c checksum against tho whole block */
		checksum = ext4_crc32c(checksum, buf,
				block_size);
	} else if (JBD_HAS_INCOMPAT_FEATURE(&jbd_fs->sb,
				     JBD_FEATURE_COMPAT_CHECKSUM)) {
		uint32_t block_size = jbd_get32(&jbd_fs->sb, blocksize);
		/* Calculate crc32c checksum against tho whole block */
		checksum = ext4_crc32(csum, buf,
				block_size);
	}
	return checksum;
}
#else
#define jbd_block_csum(...) 0
#endif

static void jbd_block_tag_csum_set(struct jbd_fs *jbd_fs, void *__tag,
				   uint32_t checksum)
{
	int ver = jbd_has_csum(&jbd_fs->sb);
	if (!ver)
		return;

	if (ver == 2) {
		struct jbd_block_tag *tag = __tag;
		tag->checksum = (uint16_t)to_be32(checksum);
	} else {
		struct jbd_block_tag3 *tag = __tag;
		tag->checksum = to_be32(checksum);
	}
}

/**@brief  Write jbd superblock to disk.
 * @param  jbd_fs jbd filesystem
 * @param  s jbd superblock
 * @return standard error code*/
static int jbd_sb_write(struct jbd_fs *jbd_fs, struct jbd_sb *s)
{
	int rc;
	struct ext4_fs *fs = jbd_fs->inode_ref.fs;
	uint64_t offset;
	ext4_fsblk_t fblock;
	rc = jbd_inode_bmap(jbd_fs, 0, &fblock);
	if (rc != EOK)
		return rc;

	jbd_sb_csum_set(s);
	offset = fblock * ext4_sb_get_block_size(&fs->sb);
	return ext4_block_writebytes(fs->bdev, offset, s,
				     EXT4_SUPERBLOCK_SIZE);
}

/**@brief  Read jbd superblock from disk.
 * @param  jbd_fs jbd filesystem
 * @param  s jbd superblock
 * @return standard error code*/
static int jbd_sb_read(struct jbd_fs *jbd_fs, struct jbd_sb *s)
{
	int rc;
	struct ext4_fs *fs = jbd_fs->inode_ref.fs;
	uint64_t offset;
	ext4_fsblk_t fblock;
	rc = jbd_inode_bmap(jbd_fs, 0, &fblock);
	if (rc != EOK)
		return rc;

	offset = fblock * ext4_sb_get_block_size(&fs->sb);
	return ext4_block_readbytes(fs->bdev, offset, s,
				    EXT4_SUPERBLOCK_SIZE);
}

/**@brief  Verify jbd superblock.
 * @param  sb jbd superblock
 * @return true if jbd superblock is valid */
static bool jbd_verify_sb(struct jbd_sb *sb)
{
	struct jbd_bhdr *header = &sb->header;
	if (jbd_get32(header, magic) != JBD_MAGIC_NUMBER)
		return false;

	if (jbd_get32(header, blocktype) != JBD_SUPERBLOCK &&
	    jbd_get32(header, blocktype) != JBD_SUPERBLOCK_V2)
		return false;

	return jbd_verify_sb_csum(sb);
}

/**@brief  Write back dirty jbd superblock to disk.
 * @param  jbd_fs jbd filesystem
 * @return standard error code*/
static int jbd_write_sb(struct jbd_fs *jbd_fs)
{
	int rc = EOK;
	if (jbd_fs->dirty) {
		rc = jbd_sb_write(jbd_fs, &jbd_fs->sb);
		if (rc != EOK)
			return rc;

		jbd_fs->dirty = false;
	}
	return rc;
}

/**@brief  Get reference to jbd filesystem.
 * @param  fs Filesystem to load journal of
 * @param  jbd_fs jbd filesystem
 * @return standard error code*/
int jbd_get_fs(struct ext4_fs *fs,
	       struct jbd_fs *jbd_fs)
{
	int rc;
	uint32_t journal_ino;

	memset(jbd_fs, 0, sizeof(struct jbd_fs));
	/* See if there is journal inode on this filesystem.*/
	/* FIXME: detection on existance ofbkejournal bdev is
	 *        missing.*/
	journal_ino = ext4_get32(&fs->sb, journal_inode_number);

	rc = ext4_fs_get_inode_ref(fs,
				   journal_ino,
				   &jbd_fs->inode_ref);
	if (rc != EOK)
		return rc;

	rc = jbd_sb_read(jbd_fs, &jbd_fs->sb);
	if (rc != EOK)
		goto Error;

	if (!jbd_verify_sb(&jbd_fs->sb)) {
		rc = EIO;
		goto Error;
	}

	/* The geometry every user of this superblock assumes, checked once
	 * where the superblock enters. Everything downstream treats journal
	 * blocks and filesystem blocks as the same size -- checksums run
	 * `blocksize` bytes over a filesystem-block buffer, replay memcpys
	 * `blocksize` bytes into one, tag tables are walked to `blocksize`.
	 * A corrupt field larger than the real block size turned each of
	 * those into an out-of-bounds read, and the checksum helper into an
	 * out-of-bounds WRITE (it zeroes the tail checksum in place) -- on
	 * every descriptor block of every recovery mount. The self-seeded
	 * CRC in jbd_verify_sb cannot catch it: a corrupt superblock
	 * checksums itself consistently. `maxlen` is bounded by the journal
	 * file's own size for the same reason: `wrap` subtracts it from
	 * block indexes, and replay trusts the difference. */
	if (jbd_get32(&jbd_fs->sb, blocksize) !=
	    ext4_sb_get_block_size(&fs->sb)) {
		rc = EIO;
		goto Error;
	}
	{
		uint64_t inode_size = ext4_inode_get_size(&fs->sb,
					jbd_fs->inode_ref.inode);
		uint64_t maxlen = jbd_get32(&jbd_fs->sb, maxlen);
		if (maxlen == 0 ||
		    maxlen > inode_size / ext4_sb_get_block_size(&fs->sb) ||
		    jbd_get32(&jbd_fs->sb, first) >= maxlen ||
		    jbd_get32(&jbd_fs->sb, start) >= maxlen) {
			rc = EIO;
			goto Error;
		}
	}

	if (rc == EOK)
		jbd_fs->bdev = fs->bdev;

	return rc;
Error:
	ext4_fs_put_inode_ref(&jbd_fs->inode_ref);
	memset(jbd_fs, 0, sizeof(struct jbd_fs));

	return rc;
}

/**@brief  Put reference of jbd filesystem.
 * @param  jbd_fs jbd filesystem
 * @return standard error code*/
int jbd_put_fs(struct jbd_fs *jbd_fs)
{
	int rc = EOK;
	rc = jbd_write_sb(jbd_fs);

	ext4_fs_put_inode_ref(&jbd_fs->inode_ref);
	return rc;
}

/**@brief  Data block lookup helper.
 * @param  jbd_fs jbd filesystem
 * @param  iblock block index
 * @param  fblock logical block address
 * @return standard error code*/
int jbd_inode_bmap(struct jbd_fs *jbd_fs,
		   ext4_lblk_t iblock,
		   ext4_fsblk_t *fblock)
{
	int rc = ext4_fs_get_inode_dblk_idx(
			&jbd_fs->inode_ref,
			iblock,
			fblock,
			false);
	return rc;
}

/**@brief   jbd block get function (through cache).
 * @param   jbd_fs jbd filesystem
 * @param   block block descriptor
 * @param   fblock jbd logical block address
 * @return  standard error code*/
static int jbd_block_get(struct jbd_fs *jbd_fs,
		  struct ext4_block *block,
		  ext4_fsblk_t fblock)
{
	/* TODO: journal device. */
	int rc;
	struct ext4_blockdev *bdev = jbd_fs->bdev;
	ext4_lblk_t iblock = (ext4_lblk_t)fblock;

	/* Lookup the logical block address of
	 * fblock.*/
	rc = jbd_inode_bmap(jbd_fs, iblock,
			    &fblock);
	if (rc != EOK)
		return rc;

	rc = ext4_block_get(bdev, block, fblock);

	/* If succeeded, mark buffer as BC_FLUSH to indicate
	 * that data should be written to disk immediately.*/
	if (rc == EOK) {
		ext4_bcache_set_flag(block->buf, BC_FLUSH);
		/* As we don't want to occupy too much space
		 * in block cache, we set this buffer BC_TMP.*/
		ext4_bcache_set_flag(block->buf, BC_TMP);
	}

	return rc;
}

/**@brief   jbd block get function (through cache, don't read).
 * @param   jbd_fs jbd filesystem
 * @param   block block descriptor
 * @param   fblock jbd logical block address
 * @return  standard error code*/
static int jbd_block_get_noread(struct jbd_fs *jbd_fs,
			 struct ext4_block *block,
			 ext4_fsblk_t fblock)
{
	/* TODO: journal device. */
	int rc;
	struct ext4_blockdev *bdev = jbd_fs->bdev;
	ext4_lblk_t iblock = (ext4_lblk_t)fblock;
	rc = jbd_inode_bmap(jbd_fs, iblock,
			    &fblock);
	if (rc != EOK)
		return rc;

	rc = ext4_block_get_noread(bdev, block, fblock);
	if (rc == EOK)
		ext4_bcache_set_flag(block->buf, BC_FLUSH);

	return rc;
}

/**@brief   jbd block set procedure (through cache).
 * @param   jbd_fs jbd filesystem
 * @param   block block descriptor
 * @return  standard error code*/
static int jbd_block_set(struct jbd_fs *jbd_fs,
		  struct ext4_block *block)
{
	struct ext4_blockdev *bdev = jbd_fs->bdev;
	return ext4_block_set(bdev, block);
}

/**@brief  helper functions to calculate
 *         block tag size, not including UUID part.
 * @param  jbd_fs jbd filesystem
 * @return tag size in bytes*/
static int jbd_tag_bytes(struct jbd_fs *jbd_fs)
{
	int size;

	/* It is very easy to deal with the case which
	 * JBD_FEATURE_INCOMPAT_CSUM_V3 is enabled.*/
	if (JBD_HAS_INCOMPAT_FEATURE(&jbd_fs->sb,
				     JBD_FEATURE_INCOMPAT_CSUM_V3))
		return sizeof(struct jbd_block_tag3);

	size = sizeof(struct jbd_block_tag);

	/* If JBD_FEATURE_INCOMPAT_CSUM_V2 is enabled,
	 * add 2 bytes to size.*/
	if (JBD_HAS_INCOMPAT_FEATURE(&jbd_fs->sb,
				     JBD_FEATURE_INCOMPAT_CSUM_V2))
		size += sizeof(uint16_t);

	if (JBD_HAS_INCOMPAT_FEATURE(&jbd_fs->sb,
				     JBD_FEATURE_INCOMPAT_64BIT))
		return size;

	/* If block number is 4 bytes in size,
	 * minus 4 bytes from size */
	return size - sizeof(uint32_t);
}

/**@brief  Tag information. */
struct tag_info {
	/**@brief  Tag size in bytes, including UUID part.*/
	int tag_bytes;

	/**@brief  block number stored in this tag.*/
	ext4_fsblk_t block;

	/**@brief  Is the first 4 bytes of block equals to
	 *	   JBD_MAGIC_NUMBER? */
	bool is_escape;

	/**@brief  whether UUID part exists or not.*/
	bool uuid_exist;

	/**@brief  UUID content if UUID part exists.*/
	uint8_t uuid[UUID_SIZE];

	/**@brief  Is this the last tag? */
	bool last_tag;

	/**@brief  crc32c checksum. */
	uint32_t checksum;
};

/**@brief  Extract information from a block tag.
 * @param  __tag pointer to the block tag
 * @param  tag_bytes block tag size of this jbd filesystem
 * @param  remain_buf_size size in buffer containing the block tag
 * @param  tag_info information of this tag.
 * @return  EOK when succeed, otherwise return EINVAL.*/
static int
jbd_extract_block_tag(struct jbd_fs *jbd_fs,
		      void *__tag,
		      int tag_bytes,
		      int32_t remain_buf_size,
		      struct tag_info *tag_info)
{
	char *uuid_start;
	tag_info->tag_bytes = tag_bytes;
	tag_info->uuid_exist = false;
	tag_info->last_tag = false;
	tag_info->is_escape = false;

	/* See whether it is possible to hold a valid block tag.*/
	if (remain_buf_size - tag_bytes < 0)
		return EINVAL;

	if (JBD_HAS_INCOMPAT_FEATURE(&jbd_fs->sb,
				     JBD_FEATURE_INCOMPAT_CSUM_V3)) {
		struct jbd_block_tag3 *tag = __tag;
		tag_info->block = jbd_get32(tag, blocknr);
		if (JBD_HAS_INCOMPAT_FEATURE(&jbd_fs->sb,
					     JBD_FEATURE_INCOMPAT_64BIT))
			 tag_info->block |=
				 (uint64_t)jbd_get32(tag, blocknr_high) << 32;

		if (jbd_get32(tag, flags) & JBD_FLAG_ESCAPE)
			tag_info->is_escape = true;

		if (!(jbd_get32(tag, flags) & JBD_FLAG_SAME_UUID)) {
			/* See whether it is possible to hold UUID part.*/
			if (remain_buf_size - tag_bytes < UUID_SIZE)
				return EINVAL;

			uuid_start = (char *)tag + tag_bytes;
			tag_info->uuid_exist = true;
			tag_info->tag_bytes += UUID_SIZE;
			memcpy(tag_info->uuid, uuid_start, UUID_SIZE);
		}

		if (jbd_get32(tag, flags) & JBD_FLAG_LAST_TAG)
			tag_info->last_tag = true;

	} else {
		struct jbd_block_tag *tag = __tag;
		tag_info->block = jbd_get32(tag, blocknr);
		if (JBD_HAS_INCOMPAT_FEATURE(&jbd_fs->sb,
					     JBD_FEATURE_INCOMPAT_64BIT))
			 tag_info->block |=
				 (uint64_t)jbd_get32(tag, blocknr_high) << 32;

		if (jbd_get16(tag, flags) & JBD_FLAG_ESCAPE)
			tag_info->is_escape = true;

		if (!(jbd_get16(tag, flags) & JBD_FLAG_SAME_UUID)) {
			/* See whether it is possible to hold UUID part.*/
			if (remain_buf_size - tag_bytes < UUID_SIZE)
				return EINVAL;

			uuid_start = (char *)tag + tag_bytes;
			tag_info->uuid_exist = true;
			tag_info->tag_bytes += UUID_SIZE;
			memcpy(tag_info->uuid, uuid_start, UUID_SIZE);
		}

		if (jbd_get16(tag, flags) & JBD_FLAG_LAST_TAG)
			tag_info->last_tag = true;

	}
	return EOK;
}

/**@brief  Write information to a block tag.
 * @param  __tag pointer to the block tag
 * @param  remain_buf_size size in buffer containing the block tag
 * @param  tag_info information of this tag.
 * @return  EOK when succeed, otherwise return EINVAL.*/
static int
jbd_write_block_tag(struct jbd_fs *jbd_fs,
		    void *__tag,
		    int32_t remain_buf_size,
		    struct tag_info *tag_info)
{
	char *uuid_start;
	int tag_bytes = jbd_tag_bytes(jbd_fs);

	tag_info->tag_bytes = tag_bytes;

	/* See whether it is possible to hold a valid block tag.*/
	if (remain_buf_size - tag_bytes < 0)
		return EINVAL;

	if (JBD_HAS_INCOMPAT_FEATURE(&jbd_fs->sb,
				     JBD_FEATURE_INCOMPAT_CSUM_V3)) {
		struct jbd_block_tag3 *tag = __tag;
		memset(tag, 0, sizeof(struct jbd_block_tag3));
		jbd_set32(tag, blocknr, (uint32_t)tag_info->block);
		if (JBD_HAS_INCOMPAT_FEATURE(&jbd_fs->sb,
					     JBD_FEATURE_INCOMPAT_64BIT))
			jbd_set32(tag, blocknr_high, tag_info->block >> 32);

		if (tag_info->uuid_exist) {
			/* See whether it is possible to hold UUID part.*/
			if (remain_buf_size - tag_bytes < UUID_SIZE)
				return EINVAL;

			uuid_start = (char *)tag + tag_bytes;
			tag_info->tag_bytes += UUID_SIZE;
			memcpy(uuid_start, tag_info->uuid, UUID_SIZE);
		} else
			jbd_set32(tag, flags,
				  jbd_get32(tag, flags) | JBD_FLAG_SAME_UUID);

		jbd_block_tag_csum_set(jbd_fs, __tag, tag_info->checksum);

		if (tag_info->last_tag)
			jbd_set32(tag, flags,
				  jbd_get32(tag, flags) | JBD_FLAG_LAST_TAG);

		if (tag_info->is_escape)
			jbd_set32(tag, flags,
				  jbd_get32(tag, flags) | JBD_FLAG_ESCAPE);

	} else {
		struct jbd_block_tag *tag = __tag;
		memset(tag, 0, sizeof(struct jbd_block_tag));
		jbd_set32(tag, blocknr, (uint32_t)tag_info->block);
		if (JBD_HAS_INCOMPAT_FEATURE(&jbd_fs->sb,
					     JBD_FEATURE_INCOMPAT_64BIT))
			jbd_set32(tag, blocknr_high, tag_info->block >> 32);

		if (tag_info->uuid_exist) {
			/* See whether it is possible to hold UUID part.*/
			if (remain_buf_size - tag_bytes < UUID_SIZE)
				return EINVAL;

			uuid_start = (char *)tag + tag_bytes;
			tag_info->tag_bytes += UUID_SIZE;
			memcpy(uuid_start, tag_info->uuid, UUID_SIZE);
		} else
			jbd_set16(tag, flags,
				  jbd_get16(tag, flags) | JBD_FLAG_SAME_UUID);

		jbd_block_tag_csum_set(jbd_fs, __tag, tag_info->checksum);

		if (tag_info->last_tag)
			jbd_set16(tag, flags,
				  jbd_get16(tag, flags) | JBD_FLAG_LAST_TAG);


		if (tag_info->is_escape)
			jbd_set16(tag, flags,
				  jbd_get16(tag, flags) | JBD_FLAG_ESCAPE);

	}
	return EOK;
}

/**@brief  Iterate all block tags in a block.
 * @param  jbd_fs jbd filesystem
 * @param  __tag_start pointer to the block
 * @param  tag_tbl_size size of the block
 * @param  func callback routine to indicate that
 *         a block tag is found
 * @param  arg additional argument to be passed to func */
static void
jbd_iterate_block_table(struct jbd_fs *jbd_fs,
			void *__tag_start,
			int32_t tag_tbl_size,
			void (*func)(struct jbd_fs * jbd_fs,
				     struct tag_info *tag_info,
				     void *arg),
			void *arg)
{
	char *tag_start, *tag_ptr;
	int tag_bytes = jbd_tag_bytes(jbd_fs);
	tag_start = __tag_start;
	tag_ptr = tag_start;

	/* Cut off the size of block tail storing checksum. */
	if (JBD_HAS_INCOMPAT_FEATURE(&jbd_fs->sb,
				     JBD_FEATURE_INCOMPAT_CSUM_V2) ||
	    JBD_HAS_INCOMPAT_FEATURE(&jbd_fs->sb,
				     JBD_FEATURE_INCOMPAT_CSUM_V3))
		tag_tbl_size -= sizeof(struct jbd_block_tail);

	while (tag_tbl_size) {
		struct tag_info tag_info;
		int rc = jbd_extract_block_tag(jbd_fs,
				      tag_ptr,
				      tag_bytes,
				      tag_tbl_size,
				      &tag_info);
		if (rc != EOK)
			break;

		if (func)
			func(jbd_fs, &tag_info, arg);

		/* Stop the iteration when we reach the last tag. */
		if (tag_info.last_tag)
			break;

		tag_ptr += tag_info.tag_bytes;
		tag_tbl_size -= tag_info.tag_bytes;
	}
}

static void jbd_display_block_tags(struct jbd_fs *jbd_fs,
				   struct tag_info *tag_info,
				   void *arg)
{
	uint32_t *iblock = arg;
	ext4_dbg(DEBUG_JBD, "Block in block_tag: %" PRIu64 "\n", tag_info->block);
	(*iblock)++;
	wrap(&jbd_fs->sb, *iblock);
	(void)jbd_fs;
	return;
}

static struct revoke_entry *
jbd_revoke_entry_lookup(struct recover_info *info, ext4_fsblk_t block)
{
	struct revoke_entry tmp = {
		.block = block
	};

	return RB_FIND(jbd_revoke, &info->revoke_root, &tmp);
}

/**@brief  Replay a block in a transaction.
 * @param  jbd_fs jbd filesystem
 * @param  tag_info tag_info of the logged block.*/
static void jbd_replay_block_tags(struct jbd_fs *jbd_fs,
				  struct tag_info *tag_info,
				  void *__arg)
{
	int r;
	struct replay_arg *arg = __arg;
	struct recover_info *info = arg->info;
	uint32_t *this_block = arg->this_block;
	struct revoke_entry *revoke_entry;
	struct ext4_block journal_block, ext4_block;
	struct ext4_fs *fs = jbd_fs->inode_ref.fs;
	void *jdata;
	bool have_block = false;

	(*this_block)++;
	wrap(&jbd_fs->sb, *this_block);

	/* We replay this block only if the current transaction id
	 * is equal or greater than that in revoke entry.*/
	revoke_entry = jbd_revoke_entry_lookup(info, tag_info->block);
	if (revoke_entry &&
	    trans_id_diff(arg->this_trans_id, revoke_entry->trans_id) <= 0)
		return;

	ext4_dbg(DEBUG_JBD,
		 "Replaying block in block_tag: %" PRIu64 "\n",
		 tag_info->block);

	/* The logged copy, from the read-ahead window when there is one:
	 * replay sweeps the log linearly, and fetching that sweep one
	 * cached block at a time is what made large recoveries take
	 * minutes on media with a per-command cost. */
	if (info->wnd) {
		r = jbd_replay_wnd_read(jbd_fs, info->wnd, *this_block,
					&jdata);
		if (r != EOK) {
			info->rc = r;
			return;
		}
	} else {
		/* The fallback path when the window could not be allocated.
		 * Skipping an unreadable logged block silently -- the old
		 * behavior -- means finishing recovery without it and then
		 * clearing the journal that still held it. */
		r = jbd_block_get(jbd_fs, &journal_block, *this_block);
		if (r != EOK) {
			info->rc = r;
			return;
		}
		jdata = journal_block.data;
		have_block = true;
	}

	/* We need special treatment for ext4 superblock. */
	if (tag_info->block) {
		if (info->wb) {
			r = jbd_replay_wb_record(jbd_fs, info->wb,
						 tag_info->block, jdata,
						 tag_info->is_escape);
			if (r != EOK)
				info->rc = r;
			goto out;
		}

		r = ext4_block_get_noread(fs->bdev, &ext4_block, tag_info->block);
		if (r != EOK) {
			info->rc = r;
			goto out;
		}

		memcpy(ext4_block.data,
			jdata,
			jbd_get32(&jbd_fs->sb, blocksize));

		if (tag_info->is_escape)
			((struct jbd_bhdr *)ext4_block.data)->magic =
					to_be32(JBD_MAGIC_NUMBER);

		ext4_bcache_set_dirty(ext4_block.buf);
		ext4_block_set(fs->bdev, &ext4_block);
	} else {
		uint16_t mount_count, state;
		mount_count = ext4_get16(&fs->sb, mount_count);
		state = ext4_get16(&fs->sb, state);

		memcpy(&fs->sb,
			(uint8_t *)jdata + EXT4_SUPERBLOCK_OFFSET,
			EXT4_SUPERBLOCK_SIZE);

		/* Mark system as mounted */
		ext4_set16(&fs->sb, state, state);
		r = ext4_sb_write(fs->bdev, &fs->sb);
		if (r != EOK) {
			/* The live gap: superblock updates are journaled
			 * (patch 0023), so this branch runs on every replay
			 * of one. Losing this write and then clearing the
			 * journal undid exactly what 0023 preserved. */
			info->rc = r;
			goto out;
		}

		/*Update mount count*/
		ext4_set16(&fs->sb, mount_count, mount_count);
	}

out:
	/* Always through here: the early sb_write return used to leak the
	 * journal block's cache reference. */
	if (have_block)
		jbd_block_set(jbd_fs, &journal_block);

	return;
}

/**@brief  Add block address to revoke tree, along with
 *         its transaction id.
 * @param  info  journal replay info
 * @param  block  block address to be replayed.*/
static void jbd_add_revoke_block_tags(struct recover_info *info,
				      ext4_fsblk_t block)
{
	struct revoke_entry *revoke_entry;

	ext4_dbg(DEBUG_JBD, "Add block %" PRIu64 " to revoke tree\n", block);
	/* If the revoke entry with respect to the block address
	 * exists already, update its transaction id.*/
	revoke_entry = jbd_revoke_entry_lookup(info, block);
	if (revoke_entry) {
		revoke_entry->trans_id = info->this_trans_id;
		return;
	}

	revoke_entry = jbd_alloc_revoke_entry();
	ext4_assert(revoke_entry);
	revoke_entry->block = block;
	revoke_entry->trans_id = info->this_trans_id;
	RB_INSERT(jbd_revoke, &info->revoke_root, revoke_entry);

	return;
}

static void jbd_destroy_revoke_tree(struct recover_info *info)
{
	while (!RB_EMPTY(&info->revoke_root)) {
		struct revoke_entry *revoke_entry =
			RB_MIN(jbd_revoke, &info->revoke_root);
		ext4_assert(revoke_entry);
		RB_REMOVE(jbd_revoke, &info->revoke_root, revoke_entry);
		jbd_free_revoke_entry(revoke_entry);
	}
}


#define ACTION_SCAN 0
#define ACTION_REVOKE 1
#define ACTION_RECOVER 2

/**@brief  Add entries in a revoke block to revoke tree.
 * @param  jbd_fs jbd filesystem
 * @param  header revoke block header
 * @param  info  journal replay info*/
static void jbd_build_revoke_tree(struct jbd_fs *jbd_fs,
				  struct jbd_bhdr *header,
				  struct recover_info *info)
{
	char *blocks_entry;
	struct jbd_revoke_header *revoke_hdr =
		(struct jbd_revoke_header *)header;
	uint32_t i, nr_entries, record_len = 4;

	/* If we are working on a 64bit jbd filesystem, */
	if (JBD_HAS_INCOMPAT_FEATURE(&jbd_fs->sb,
				     JBD_FEATURE_INCOMPAT_64BIT))
		record_len = 8;

	nr_entries = (jbd_get32(revoke_hdr, count) -
			sizeof(struct jbd_revoke_header)) /
			record_len;

	blocks_entry = (char *)(revoke_hdr + 1);

	for (i = 0;i < nr_entries;i++) {
		if (record_len == 8) {
			uint64_t *blocks =
				(uint64_t *)blocks_entry;
			jbd_add_revoke_block_tags(info, to_be64(*blocks));
		} else {
			uint32_t *blocks =
				(uint32_t *)blocks_entry;
			jbd_add_revoke_block_tags(info, to_be32(*blocks));
		}
		blocks_entry += record_len;
	}
}

static void jbd_debug_descriptor_block(struct jbd_fs *jbd_fs,
				       struct jbd_bhdr *header,
				       uint32_t *iblock)
{
	jbd_iterate_block_table(jbd_fs,
				header + 1,
				jbd_get32(&jbd_fs->sb, blocksize) -
					sizeof(struct jbd_bhdr),
				jbd_display_block_tags,
				iblock);
}

static void jbd_replay_descriptor_block(struct jbd_fs *jbd_fs,
					struct jbd_bhdr *header,
					struct replay_arg *arg)
{
	jbd_iterate_block_table(jbd_fs,
				header + 1,
				jbd_get32(&jbd_fs->sb, blocksize) -
					sizeof(struct jbd_bhdr),
				jbd_replay_block_tags,
				arg);
}

/**@brief  The core routine of journal replay.
 * @param  jbd_fs jbd filesystem
 * @param  info  journal replay info
 * @param  action action needed to be taken
 * @return standard error code*/
static int jbd_iterate_log(struct jbd_fs *jbd_fs,
			   struct recover_info *info,
			   int action)
{
	int r = EOK;
	bool log_end = false;
	struct jbd_sb *sb = &jbd_fs->sb;
	uint32_t start_trans_id, this_trans_id;
	uint32_t start_block, this_block;

	/* We start iterating valid blocks in the whole journal.*/
	start_trans_id = this_trans_id = jbd_get32(sb, sequence);
	start_block = this_block = jbd_get32(sb, start);
	if (action == ACTION_SCAN) {
		info->trans_cnt = 0;
		info->revoke_block_cnt = 0;
	} else if (!info->trans_cnt)
		log_end = true;

	ext4_dbg(DEBUG_JBD, "Start of journal at trans id: %" PRIu32 "\n",
			    start_trans_id);

	while (!log_end) {
		struct ext4_block block;
		struct jbd_bhdr *header;
		bool from_wnd = false;
		/* If we are not scanning for the last
		 * valid transaction in the journal,
		 * we will stop when we reach the end of
		 * the journal.*/
		if (action != ACTION_SCAN)
			if (trans_id_diff(this_trans_id, info->last_trans_id) > 0) {
				log_end = true;
				continue;
			}

		/* The recovery pass reads every block of the log; the scan
		 * and revoke passes hop between the few header blocks and
		 * skip the data between them. Sequential read-ahead pays
		 * for itself only in the first case, so only that pass
		 * reads through the window. */
		if (action == ACTION_RECOVER && info->wnd) {
			void *jdata;
			r = jbd_replay_wnd_read(jbd_fs, info->wnd,
						this_block, &jdata);
			if (r != EOK)
				break;
			header = (struct jbd_bhdr *)jdata;
			from_wnd = true;
		} else {
			r = jbd_block_get(jbd_fs, &block, this_block);
			if (r != EOK)
				break;
			header = (struct jbd_bhdr *)block.data;
		}

		/* This block does not have a valid magic number,
		 * so we have reached the end of the journal.*/
		if (jbd_get32(header, magic) != JBD_MAGIC_NUMBER) {
			if (!from_wnd)
				jbd_block_set(jbd_fs, &block);
			log_end = true;
			continue;
		}

		/* If the transaction id we found is not expected,
		 * we may have reached the end of the journal.
		 *
		 * If we are not scanning the journal, something
		 * bad might have taken place. :-( */
		if (jbd_get32(header, sequence) != this_trans_id) {
			if (action != ACTION_SCAN)
				r = EIO;

			if (!from_wnd)
				jbd_block_set(jbd_fs, &block);
			log_end = true;
			continue;
		}

		switch (jbd_get32(header, blocktype)) {
		case JBD_DESCRIPTOR_BLOCK:
			if (!jbd_verify_meta_csum(jbd_fs, header)) {
				ext4_dbg(DEBUG_JBD,
					DBG_WARN "Descriptor block checksum failed."
						"Journal block: %" PRIu32"\n",
						this_block);
				log_end = true;
				break;
			}
			ext4_dbg(DEBUG_JBD, "Descriptor block: %" PRIu32", "
					    "trans_id: %" PRIu32"\n",
					    this_block, this_trans_id);
			if (action == ACTION_RECOVER) {
				struct replay_arg replay_arg;
				replay_arg.info = info;
				replay_arg.this_block = &this_block;
				replay_arg.this_trans_id = this_trans_id;

				/* Replaying the tags refills the window;
				 * iterate a copy that cannot move. */
				if (from_wnd) {
					memcpy(info->wnd->desc, header,
					       jbd_fs->bdev->lg_bsize);
					header = (struct jbd_bhdr *)
							info->wnd->desc;
				}

				jbd_replay_descriptor_block(jbd_fs,
						header, &replay_arg);

				/* The tag callback cannot return errors;
				 * it parks them here. Replay that lost a
				 * write must not finish as if it had not:
				 * finishing clears the journal, and the
				 * lost write was the journal's to keep. */
				if (info->rc != EOK) {
					r = info->rc;
					log_end = true;
				}
			} else
				jbd_debug_descriptor_block(jbd_fs,
						header, &this_block);

			break;
		case JBD_COMMIT_BLOCK:
			if (!jbd_verify_commit_csum(jbd_fs,
					(struct jbd_commit_header *)header)) {
				ext4_dbg(DEBUG_JBD,
					DBG_WARN "Commit block checksum failed."
						"Journal block: %" PRIu32"\n",
						this_block);
				log_end = true;
				break;
			}
			ext4_dbg(DEBUG_JBD, "Commit block: %" PRIu32", "
					    "trans_id: %" PRIu32"\n",
					    this_block, this_trans_id);
			/*
			 * This is the end of a transaction,
			 * we may now proceed to the next transaction.
			 */
			this_trans_id++;
			if (action == ACTION_SCAN)
				info->trans_cnt++;
			break;
		case JBD_REVOKE_BLOCK:
			if (!jbd_verify_meta_csum(jbd_fs, header)) {
				ext4_dbg(DEBUG_JBD,
					DBG_WARN "Revoke block checksum failed."
						"Journal block: %" PRIu32"\n",
						this_block);
				log_end = true;
				break;
			}
			ext4_dbg(DEBUG_JBD, "Revoke block: %" PRIu32", "
					    "trans_id: %" PRIu32"\n",
					    this_block, this_trans_id);
			if (action == ACTION_SCAN)
				info->revoke_block_cnt++;
			if (action == ACTION_REVOKE) {
				info->this_trans_id = this_trans_id;
				jbd_build_revoke_tree(jbd_fs,
						header, info);
			}
			break;
		default:
			log_end = true;
			break;
		}
		if (!from_wnd)
			jbd_block_set(jbd_fs, &block);
		this_block++;
		wrap(sb, this_block);
		if (this_block == start_block)
			log_end = true;

	}
	ext4_dbg(DEBUG_JBD, "End of journal.\n");
	if (r == EOK && action == ACTION_SCAN) {
		/* We have finished scanning the journal. */
		info->start_trans_id = start_trans_id;
		if (trans_id_diff(this_trans_id, start_trans_id) > 0)
			info->last_trans_id = this_trans_id - 1;
		else
			info->last_trans_id = this_trans_id;
	}

	return r;
}

/**@brief  Replay journal.
 * @param  jbd_fs jbd filesystem
 * @return standard error code*/
int jbd_recover(struct jbd_fs *jbd_fs)
{
	int r;
	struct recover_info info;
	struct jbd_sb *sb = &jbd_fs->sb;
	if (!sb->start)
		return EOK;

	RB_INIT(&info.revoke_root);
	info.wnd = NULL;
	info.wb = NULL;
	info.rc = EOK;

	r = jbd_iterate_log(jbd_fs, &info, ACTION_SCAN);
	if (r != EOK)
		return r;

	/* Walking the whole log again to build an empty tree is pure
	 * per-command cost on the media where recovery is already slow. */
	if (info.revoke_block_cnt) {
		r = jbd_iterate_log(jbd_fs, &info, ACTION_REVOKE);
		if (r != EOK)
			return r;
	}

	jbd_replay_wnd_init(jbd_fs, &info);
	jbd_replay_wb_init(jbd_fs, &info);
	r = jbd_iterate_log(jbd_fs, &info, ACTION_RECOVER);
	/* Whatever the batch still holds has to land before the barrier
	 * below claims the replay writes are on the medium. */
	if (r == EOK && info.wb)
		r = jbd_replay_wb_flush(jbd_fs, info.wb);
	jbd_replay_wnd_fini(&info);
	jbd_replay_wb_fini(&info);
	if (r == EOK) {
		/* The replay writes were issued; the superblock below says
		 * they are not needed again. Make the first true before
		 * stating the second. */
		(void)ext4_block_barrier(jbd_fs->bdev);
		/* Replay may have rewritten the superblock's own home --
		 * journaled superblock updates land as tag 0 on volumes with
		 * blocks larger than 1 KiB, handled by the dedicated branch
		 * above, but as an ordinary tagged block on 1 KiB volumes,
		 * where the superblock is block 1. The dedicated branch
		 * refreshes the in-memory copy; the ordinary path only writes
		 * the medium. Reload, or everything after this point -- the
		 * flag edits below, orphan cleanup, the eventual unmount
		 * write-back -- runs on a stale superblock and quietly undoes
		 * what replay restored. Measured: a replayed orphan-list head
		 * vanished at exactly this seam and stranded its inode. */
		(void)ext4_sb_read(jbd_fs->inode_ref.fs->bdev,
				   &jbd_fs->inode_ref.fs->sb);
		/* If we successfully replay the journal,
		 * clear EXT4_FINCOM_RECOVER flag on the
		 * ext4 superblock, and set the start of
		 * journal to 0.*/
		uint32_t features_incompatible =
			ext4_get32(&jbd_fs->inode_ref.fs->sb,
				   features_incompatible);
		jbd_set32(&jbd_fs->sb, start, 0);
		jbd_set32(&jbd_fs->sb, sequence, info.last_trans_id);
		features_incompatible &= ~EXT4_FINCOM_RECOVER;
		ext4_set32(&jbd_fs->inode_ref.fs->sb,
			   features_incompatible,
			   features_incompatible);
		jbd_fs->dirty = true;
		r = ext4_sb_write(jbd_fs->bdev,
				  &jbd_fs->inode_ref.fs->sb);
	}
	jbd_destroy_revoke_tree(&info);
	return r;
}

static void jbd_journal_write_sb(struct jbd_journal *journal)
{
	struct jbd_fs *jbd_fs = journal->jbd_fs;
	jbd_set32(&jbd_fs->sb, start, journal->start);
	jbd_set32(&jbd_fs->sb, sequence, journal->trans_id);
	jbd_fs->dirty = true;
}

/**@brief  Start accessing the journal.
 * @param  jbd_fs jbd filesystem
 * @param  journal current journal session
 * @return standard error code*/
int jbd_journal_start(struct jbd_fs *jbd_fs,
		      struct jbd_journal *journal)
{
	int r;
	uint32_t features_incompatible =
			ext4_get32(&jbd_fs->inode_ref.fs->sb,
				   features_incompatible);
	features_incompatible |= EXT4_FINCOM_RECOVER;
	ext4_set32(&jbd_fs->inode_ref.fs->sb,
			features_incompatible,
			features_incompatible);
	r = ext4_sb_write(jbd_fs->bdev,
			&jbd_fs->inode_ref.fs->sb);
	if (r != EOK)
		return r;

	journal->first = jbd_get32(&jbd_fs->sb, first);
	journal->start = journal->first;
	journal->last = journal->first;
	/*
	 * To invalidate any stale records we need to start from
	 * the checkpoint transaction ID of the previous journalling session
	 * plus 1.
	 */
	journal->trans_id = jbd_get32(&jbd_fs->sb, sequence) + 1;
	journal->alloc_trans_id = journal->trans_id;

	journal->block_size = jbd_get32(&jbd_fs->sb, blocksize);

	TAILQ_INIT(&journal->cp_queue);
	RB_INIT(&journal->block_rec_root);
	journal->jbd_fs = jbd_fs;
	jbd_journal_write_sb(journal);
	journal->published_start = journal->start;
	r = jbd_write_sb(jbd_fs);
	if (r != EOK)
		return r;

	jbd_fs->bdev->journal = journal;
	return EOK;
}

static void jbd_trans_end_write(struct ext4_bcache *bc __unused,
			  struct ext4_buf *buf __unused,
			  int res,
			  void *arg);

/*
 * This routine is only suitable to committed transactions. */
static int jbd_journal_flush_trans(struct jbd_trans *trans)
{
	struct jbd_buf *jbd_buf, *tmp;
	struct jbd_journal *journal = trans->journal;
	struct ext4_fs *fs = journal->jbd_fs->inode_ref.fs;
	int rc = EOK;
	void *tmp_data = ext4_malloc(journal->block_size);
	if (!tmp_data)
		return ENOMEM;

	TAILQ_FOREACH_SAFE(jbd_buf, &trans->buf_queue, buf_node,
			tmp) {
		struct ext4_buf *buf;
		struct ext4_block block;
		/* The buffer is not yet flushed. */
		buf = ext4_bcache_find_get(fs->bdev->bc, &block,
					   jbd_buf->block_rec->lba);
		if (!(buf && ext4_bcache_test_flag(buf, BC_UPTODATE) &&
		      jbd_buf->block_rec->trans == trans)) {
			int r;
			struct ext4_block jbd_block = EXT4_BLOCK_ZERO();
			r = jbd_block_get(journal->jbd_fs,
						&jbd_block,
						jbd_buf->jbd_lba);
			/* Asserting here aborted the whole driver when the
			 * medium disappeared under a live mount -- unmount
			 * flushes checkpoints, the reads hit a device that is
			 * gone, and SIGABRT took the process down mid-
			 * teardown (measured: a USB stick pulled during a
			 * write flood). Failure is an answer, not an
			 * invariant violation: stop flushing and leave the
			 * transaction on the checkpoint queue. The staged
			 * tail has not moved past it, so the superblock still
			 * says the log covers it, and the next mount replays
			 * it -- which is exactly what recovery is for, and
			 * what happened when the pulled stick came back
			 * clean. */
			if (r != EOK) {
				rc = r;
				break;
			}
			memcpy(tmp_data, jbd_block.data,
					journal->block_size);
			ext4_block_set(fs->bdev, &jbd_block);
			r = ext4_blocks_set_direct(fs->bdev, tmp_data,
					jbd_buf->block_rec->lba, 1);
			jbd_trans_end_write(fs->bdev->bc, buf, r, jbd_buf);
			if (r != EOK)
				rc = r;
		} else {
			/* The flush reports through end_write either way;
			 * this return value is the caller's copy of it. It
			 * was discarded, so a failed home write flushed
			 * "successfully" as far as the purge could see. */
			int r = ext4_block_flush_buf(fs->bdev, buf);
			if (r != EOK)
				rc = r;
		}

		if (buf)
			ext4_block_set(fs->bdev, &block);
	}

	ext4_free(tmp_data);
	return rc;
}

static void
jbd_journal_skip_pure_revoke(struct jbd_journal *journal,
			     struct jbd_trans *trans)
{
	journal->start = trans->start_iblock +
		trans->alloc_blocks;
	wrap(&journal->jbd_fs->sb, journal->start);
	journal->trans_id = trans->trans_id + 1;
	jbd_journal_free_trans(journal,
			trans, false);
	jbd_journal_write_sb(journal);
}

void
jbd_journal_purge_cp_trans(struct jbd_journal *journal,
			   bool flush,
			   bool once)
{
	struct jbd_trans *trans;
	bool flushed = false;
	while ((trans = TAILQ_FIRST(&journal->cp_queue))) {
		if (!trans->data_cnt) {
			TAILQ_REMOVE(&journal->cp_queue,
					trans,
					trans_node);
			jbd_journal_skip_pure_revoke(journal, trans);
		} else {
			if (trans->data_cnt ==
					trans->written_cnt) {
				/* Every buffer was attempted; not every one
				 * landed. The log is the only copy of the
				 * ones that failed, so the tail must not
				 * move past this transaction -- nor past
				 * anything behind it. Recovery redoes the
				 * whole thing on the next mount. */
				if (trans->error != EOK)
					break;
				journal->start =
					trans->start_iblock +
					trans->alloc_blocks;
				wrap(&journal->jbd_fs->sb,
						journal->start);
				journal->trans_id =
					trans->trans_id + 1;
				TAILQ_REMOVE(&journal->cp_queue,
						trans,
						trans_node);
				jbd_journal_free_trans(journal,
						trans,
						false);
				jbd_journal_write_sb(journal);
			} else if (!flush) {
				journal->start =
					trans->start_iblock;
				wrap(&journal->jbd_fs->sb,
						journal->start);
				journal->trans_id =
					trans->trans_id;
				jbd_journal_write_sb(journal);
				break;
			} else {
				/* A flush that cannot read its own log --
				 * the medium is gone or failing -- must not
				 * be retried forever: the transaction never
				 * completes, so this loop would spin on it.
				 * Stop purging. The staged tail still covers
				 * everything unflushed, so the next mount
				 * replays it. */
				if (jbd_journal_flush_trans(trans) != EOK)
					break;
				flushed = true;
			}
		}
		if (once)
			break;
	}
	/* The flush above *issued* home-location writes; make them durable
	 * before any caller acts on the tail they moved. The wrap path is
	 * about to reuse the freed log range, and jbd_journal_stop is about
	 * to write a superblock that says no replay is needed -- both are
	 * lies until these writes are on the medium. Best-effort by
	 * necessity: this path is void, and a device that fails its barrier
	 * will fail the very next write loudly enough. */
	if (flushed)
		(void)ext4_block_barrier(journal->jbd_fs->bdev);
}

/**@brief  Stop accessing the journal.
 * @param  journal current journal session
 * @return standard error code*/
int jbd_journal_stop(struct jbd_journal *journal)
{
	int r;
	struct jbd_fs *jbd_fs = journal->jbd_fs;
	uint32_t features_incompatible;

	/* Make sure that journalled content have reached
	 * the disk.*/
	jbd_journal_purge_cp_trans(journal, true, false);

	/* The purge stops when a checkpoint cannot be completed -- a read of
	 * the log failed, or a home write did (trans->error). Whatever it
	 * left on the queue exists on the medium only as log records, and
	 * the superblock writes below would declare that log replayed: the
	 * change would be in neither the log nor its home. Keep the on-disk
	 * state exactly as it is -- EXT4_FINCOM_RECOVER set, the published
	 * tail still covering the unflushed transactions -- and report the
	 * failure. The next mount replays them, which is what recovery is
	 * for. The in-memory structures are still torn down: this journal
	 * session is over either way. */
	if (!TAILQ_EMPTY(&journal->cp_queue)) {
		struct jbd_trans *trans;
		int err = EIO;
		while ((trans = TAILQ_FIRST(&journal->cp_queue))) {
			struct jbd_buf *jbd_buf;
			if (trans->error != EOK)
				err = trans->error;
			/* Unhook the completion callbacks before the
			 * structures they point into are freed: the block
			 * cache outlives this journal session, and its
			 * unmount flush would call end_write on a freed
			 * jbd_buf (measured: use-after-free under ASan).
			 * The buffers stay dirty -- writing them home is
			 * still correct and the log still covers them. */
			TAILQ_FOREACH(jbd_buf, &trans->buf_queue, buf_node) {
				struct ext4_block block;
				struct ext4_buf *buf = ext4_bcache_find_get(
						jbd_fs->bdev->bc, &block,
						jbd_buf->block_rec->lba);
				if (!buf)
					continue;
				if (buf->end_write_arg == jbd_buf) {
					buf->end_write = NULL;
					buf->end_write_arg = NULL;
				}
				ext4_block_set(jbd_fs->bdev, &block);
			}
			TAILQ_REMOVE(&journal->cp_queue, trans, trans_node);
			jbd_journal_free_trans(journal, trans, false);
		}
		return err;
	}

	/* There should be no block record in this journal
	 * session. */
	if (!RB_EMPTY(&journal->block_rec_root))
		ext4_dbg(DEBUG_JBD,
			 DBG_WARN "There are still block records "
			 	  "in this journal session!\n");

	features_incompatible =
		ext4_get32(&jbd_fs->inode_ref.fs->sb,
			   features_incompatible);
	features_incompatible &= ~EXT4_FINCOM_RECOVER;
	ext4_set32(&jbd_fs->inode_ref.fs->sb,
			features_incompatible,
			features_incompatible);
	r = ext4_sb_write(jbd_fs->bdev,
			&jbd_fs->inode_ref.fs->sb);
	if (r != EOK)
		return r;

	journal->start = 0;
	/*
	 * Deliberately keep trans_id rather than resetting it to 0.
	 *
	 * jbd_journal_start() computes the next session's first transaction id
	 * as on-disk sequence + 1, specifically so that records still
	 * physically present in the log from an earlier session cannot be
	 * mistaken for current ones. Writing 0 here defeats that: every session
	 * then starts at 1, stale records also carry 1, and a crash that
	 * advertises a log start before the new transaction commits lets
	 * recovery replay the previous session's records over live metadata.
	 *
	 * Persisting the last id used keeps sequence numbers monotonic across
	 * mounts, which is what makes the +1 meaningful.
	 */
	jbd_journal_write_sb(journal);
	return jbd_write_sb(journal->jbd_fs);
}

/**@brief  Allocate a block in the journal.
 * @param  journal current journal session
 * @param  trans transaction
 * @return allocated block address*/
static uint32_t jbd_journal_alloc_block(struct jbd_journal *journal,
					struct jbd_trans *trans)
{
	uint32_t start_block;

	start_block = journal->last++;
	trans->alloc_blocks++;
	wrap(&journal->jbd_fs->sb, journal->last);
	
	/* If there is no space left, flush just one journalled
	 * transaction.*/
	if (journal->last == journal->start) {
		jbd_journal_purge_cp_trans(journal, true, true);
		ext4_assert(journal->last != journal->start);
		/* The purge checkpointed a transaction, barriered the
		 * checkpoint, and moved the tail past it -- in memory. The
		 * blocks it freed are what this allocator hands out next, so
		 * the new tail must be on the medium before one byte of that
		 * range is rewritten: a crash that keeps the reused log
		 * blocks but loses the tail advance leaves recovery starting
		 * from a stale tail into records that no longer exist, and
		 * it stops there having replayed nothing. That was measured,
		 * not imagined -- the trace of the failing cut shows exactly
		 * the journal superblock dropped while reused log space
		 * landed. */
		jbd_write_sb(journal->jbd_fs);
		(void)ext4_block_barrier(journal->jbd_fs->bdev);
		journal->published_start = journal->start;
	}

	/* The other way the head reaches the tail: `start` kept pace in
	 * memory -- checkpoints complete promptly, so the branch above never
	 * fires -- while the superblock on the medium still names a position
	 * this allocation is about to overwrite. Publish before that happens.
	 * Once per lap of the ring, so the cost disappears into the workload;
	 * skipping it disables recovery outright, and was measured doing so:
	 * a torn image whose superblock said "start at 361, sequence 607"
	 * while block 361 held sequence 936 replays nothing at all. */
	if (journal->last == journal->published_start &&
	    journal->last != journal->start) {
		(void)ext4_block_barrier(journal->jbd_fs->bdev);
		jbd_write_sb(journal->jbd_fs);
		(void)ext4_block_barrier(journal->jbd_fs->bdev);
		journal->published_start = journal->start;
	}

	return start_block;
}

static struct jbd_block_rec *
jbd_trans_block_rec_lookup(struct jbd_journal *journal,
			   ext4_fsblk_t lba)
{
	struct jbd_block_rec tmp = {
		.lba = lba
	};

	return RB_FIND(jbd_block,
		       &journal->block_rec_root,
		       &tmp);
}

static void
jbd_trans_change_ownership(struct jbd_block_rec *block_rec,
			   struct jbd_trans *new_trans)
{
	LIST_REMOVE(block_rec, tbrec_node);
	if (new_trans) {
		/* Now this block record belongs to this transaction. */
		LIST_INSERT_HEAD(&new_trans->tbrec_list, block_rec, tbrec_node);
	}
	block_rec->trans = new_trans;
}

static inline struct jbd_block_rec *
jbd_trans_insert_block_rec(struct jbd_trans *trans,
			   ext4_fsblk_t lba)
{
	struct jbd_block_rec *block_rec;
	block_rec = jbd_trans_block_rec_lookup(trans->journal, lba);
	if (block_rec) {
		jbd_trans_change_ownership(block_rec, trans);
		return block_rec;
	}
	block_rec = ext4_calloc(1, sizeof(struct jbd_block_rec));
	if (!block_rec)
		return NULL;

	block_rec->lba = lba;
	block_rec->trans = trans;
	TAILQ_INIT(&block_rec->dirty_buf_queue);
	LIST_INSERT_HEAD(&trans->tbrec_list, block_rec, tbrec_node);
	RB_INSERT(jbd_block, &trans->journal->block_rec_root, block_rec);
	return block_rec;
}

/*
 * This routine will do the dirty works.
 */
static void
jbd_trans_finish_callback(struct jbd_journal *journal,
			  const struct jbd_trans *trans,
			  struct jbd_block_rec *block_rec,
			  bool abort,
			  bool revoke)
{
	struct ext4_fs *fs = journal->jbd_fs->inode_ref.fs;
	if (block_rec->trans != trans)
		return;

	if (!abort) {
		struct jbd_buf *jbd_buf, *tmp;
		TAILQ_FOREACH_SAFE(jbd_buf,
				&block_rec->dirty_buf_queue,
				dirty_buf_node,
				tmp) {
			jbd_trans_end_write(fs->bdev->bc,
					NULL,
					EOK,
					jbd_buf);
		}
	} else {
		/*
		 * We have to roll back data if the block is going to be
		 * aborted.
		 */
		struct jbd_buf *jbd_buf;
		struct ext4_block jbd_block = EXT4_BLOCK_ZERO(),
				  block = EXT4_BLOCK_ZERO();
		jbd_buf = TAILQ_LAST(&block_rec->dirty_buf_queue,
				jbd_buf_dirty);
		if (jbd_buf) {
			if (!revoke) {
				int r;
				r = ext4_block_get_noread(fs->bdev,
							&block,
							block_rec->lba);
				ext4_assert(r == EOK);
				r = jbd_block_get(journal->jbd_fs,
							&jbd_block,
							jbd_buf->jbd_lba);
				ext4_assert(r == EOK);
				memcpy(block.data, jbd_block.data,
						journal->block_size);

				jbd_trans_change_ownership(block_rec,
						jbd_buf->trans);

				block.buf->end_write = jbd_trans_end_write;
				block.buf->end_write_arg = jbd_buf;

				ext4_bcache_set_flag(jbd_block.buf, BC_TMP);
				ext4_bcache_set_dirty(block.buf);

				ext4_block_set(fs->bdev, &jbd_block);
				ext4_block_set(fs->bdev, &block);
				return;
			} else {
				/* The revoked buffer is yet written. */
				jbd_trans_change_ownership(block_rec,
						jbd_buf->trans);
			}
		}
	}
}

static inline void
jbd_trans_remove_block_rec(struct jbd_journal *journal,
			   struct jbd_block_rec *block_rec,
			   struct jbd_trans *trans)
{
	/* If this block record doesn't belong to this transaction,
	 * give up.*/
	if (block_rec->trans == trans) {
		LIST_REMOVE(block_rec, tbrec_node);
		RB_REMOVE(jbd_block,
				&journal->block_rec_root,
				block_rec);
		ext4_free(block_rec);
	}
}

/**@brief  Add block to a transaction and mark it dirty.
 * @param  trans transaction
 * @param  block block descriptor
 * @return standard error code*/
int jbd_trans_set_block_dirty(struct jbd_trans *trans,
			      struct ext4_block *block)
{
	struct jbd_buf *jbd_buf;
	struct jbd_revoke_rec *rec, tmp_rec = {
		.lba = block->lb_id
	};
	struct jbd_block_rec *block_rec;

	if (block->buf->end_write == jbd_trans_end_write) {
		jbd_buf = block->buf->end_write_arg;
		if (jbd_buf && jbd_buf->trans == trans)
			return EOK;
	}
	jbd_buf = ext4_calloc(1, sizeof(struct jbd_buf));
	if (!jbd_buf)
		return ENOMEM;

	if ((block_rec = jbd_trans_insert_block_rec(trans,
					block->lb_id)) == NULL) {
		ext4_free(jbd_buf);
		return ENOMEM;
	}

	TAILQ_INSERT_TAIL(&block_rec->dirty_buf_queue,
			jbd_buf,
			dirty_buf_node);

	jbd_buf->block_rec = block_rec;
	jbd_buf->trans = trans;
	jbd_buf->block = *block;
	ext4_bcache_inc_ref(block->buf);

	/* If the content reach the disk, notify us
	 * so that we may do a checkpoint. */
	block->buf->end_write = jbd_trans_end_write;
	block->buf->end_write_arg = jbd_buf;

	trans->data_cnt++;
	TAILQ_INSERT_HEAD(&trans->buf_queue, jbd_buf, buf_node);

	ext4_bcache_set_dirty(block->buf);
	rec = RB_FIND(jbd_revoke_tree,
			&trans->revoke_root,
			&tmp_rec);
	if (rec) {
		RB_REMOVE(jbd_revoke_tree, &trans->revoke_root,
			  rec);
		ext4_free(rec);
	}

	return EOK;
}

/**@brief  Add block to be revoked to a transaction
 * @param  trans transaction
 * @param  lba logical block address
 * @return standard error code*/
int jbd_trans_revoke_block(struct jbd_trans *trans,
			   ext4_fsblk_t lba)
{
	struct jbd_revoke_rec tmp_rec = {
		.lba = lba
	}, *rec;
	rec = RB_FIND(jbd_revoke_tree,
		      &trans->revoke_root,
		      &tmp_rec);
	if (rec)
		return EOK;

	rec = ext4_calloc(1, sizeof(struct jbd_revoke_rec));
	if (!rec)
		return ENOMEM;

	rec->lba = lba;
	RB_INSERT(jbd_revoke_tree, &trans->revoke_root, rec);
	return EOK;
}

/**@brief  Add a freed block to a transaction's revoke set.
 *
 * Unconditionally, which is what Linux does, and the condition this replaces
 * was a hole. The old code revoked only blocks with a live block_rec -- one
 * still tracked by an uncheckpointed transaction. But the log holds records
 * back to wherever the on-disk tail points, which is further back than the
 * checkpoint queue reaches: a block journaled three transactions ago,
 * checkpointed, freed, and reused as file data is exactly the block a replay
 * will clobber -- and it had no block_rec, so it got no revoke.
 *
 * A revoke for a block the log never mentions costs four bytes in a revoke
 * block and suppresses nothing. A missing revoke for a block the log does
 * mention rewrites history over live data. The asymmetry decides.
 *
 * Re-journaling a revoked block in the same transaction cancels the revoke
 * (jbd_trans_set_block_dirty removes it from revoke_root), so free-then-
 * reallocate-as-metadata within one transaction stays correct.
 * @param  trans transaction
 * @param  lba logical block address
 * @return standard error code*/
int jbd_trans_try_revoke_block(struct jbd_trans *trans,
			       ext4_fsblk_t lba)
{
	return jbd_trans_revoke_block(trans, lba);
}

/**@brief  Free a transaction
 * @param  journal current journal session
 * @param  trans transaction
 * @param  abort discard all the modifications on the block?*/
void jbd_journal_free_trans(struct jbd_journal *journal,
			    struct jbd_trans *trans,
			    bool abort)
{
	struct jbd_buf *jbd_buf, *tmp;
	struct jbd_revoke_rec *rec, *tmp2;
	struct jbd_block_rec *block_rec, *tmp3;
	struct ext4_fs *fs = journal->jbd_fs->inode_ref.fs;
	TAILQ_FOREACH_SAFE(jbd_buf, &trans->buf_queue, buf_node,
			  tmp) {
		block_rec = jbd_buf->block_rec;
		if (abort) {
			jbd_buf->block.buf->end_write = NULL;
			jbd_buf->block.buf->end_write_arg = NULL;
			ext4_bcache_clear_dirty(jbd_buf->block.buf);
			ext4_block_set(fs->bdev, &jbd_buf->block);
		}

		TAILQ_REMOVE(&jbd_buf->block_rec->dirty_buf_queue,
			jbd_buf,
			dirty_buf_node);
		jbd_trans_finish_callback(journal,
				trans,
				block_rec,
				abort,
				false);
		TAILQ_REMOVE(&trans->buf_queue, jbd_buf, buf_node);
		ext4_free(jbd_buf);
	}
	RB_FOREACH_SAFE(rec, jbd_revoke_tree, &trans->revoke_root,
			  tmp2) {
		RB_REMOVE(jbd_revoke_tree, &trans->revoke_root, rec);
		ext4_free(rec);
	}
	LIST_FOREACH_SAFE(block_rec, &trans->tbrec_list, tbrec_node,
			  tmp3) {
		jbd_trans_remove_block_rec(journal, block_rec, trans);
	}

	ext4_free(trans);
}

/**@brief  Write commit block for a transaction
 * @param  trans transaction
 * @return standard error code*/
static int jbd_trans_write_commit_block(struct jbd_trans *trans)
{
	int rc;
	struct ext4_block block;
	struct jbd_commit_header *header;
	uint32_t commit_iblock;
	struct jbd_journal *journal = trans->journal;

	commit_iblock = jbd_journal_alloc_block(journal, trans);

	rc = jbd_block_get_noread(journal->jbd_fs, &block, commit_iblock);
	if (rc != EOK)
		return rc;

	header = (struct jbd_commit_header *)block.data;
	jbd_set32(&header->header, magic, JBD_MAGIC_NUMBER);
	jbd_set32(&header->header, blocktype, JBD_COMMIT_BLOCK);
	jbd_set32(&header->header, sequence, trans->trans_id);

	if (JBD_HAS_INCOMPAT_FEATURE(&journal->jbd_fs->sb,
				JBD_FEATURE_COMPAT_CHECKSUM)) {
		header->chksum_type = JBD_CRC32_CHKSUM;
		header->chksum_size = JBD_CRC32_CHKSUM_SIZE;
		jbd_set32(header, chksum[0], trans->data_csum);
	}
	jbd_commit_csum_set(journal->jbd_fs, header);
	ext4_bcache_set_dirty(block.buf);
	ext4_bcache_set_flag(block.buf, BC_TMP);
	rc = jbd_block_set(journal->jbd_fs, &block);
	return rc;
}

/**@brief  Write descriptor block for a transaction
 * @param  journal current journal session
 * @param  trans transaction
 * @return standard error code*/
static int jbd_journal_prepare(struct jbd_journal *journal,
			       struct jbd_trans *trans)
{
	int rc = EOK, i = 0;
	struct ext4_block desc_block = EXT4_BLOCK_ZERO(),
			  data_block = EXT4_BLOCK_ZERO();
	int32_t tag_tbl_size = 0;
	uint32_t desc_iblock = 0;
	uint32_t data_iblock = 0;
	char *tag_start = NULL, *tag_ptr = NULL;
	struct jbd_buf *jbd_buf, *tmp;
	struct ext4_fs *fs = journal->jbd_fs->inode_ref.fs;
	uint32_t checksum = EXT4_CRC32_INIT;
	struct jbd_bhdr *bhdr = NULL;
	void *data;

	/* Try to remove any non-dirty buffers from the tail of
	 * buf_queue. */
	TAILQ_FOREACH_REVERSE_SAFE(jbd_buf, &trans->buf_queue,
			jbd_trans_buf, buf_node, tmp) {
		struct jbd_revoke_rec tmp_rec = {
			.lba = jbd_buf->block_rec->lba
		};
		/* We stop the iteration when we find a dirty buffer. */
		if (ext4_bcache_test_flag(jbd_buf->block.buf,
					BC_DIRTY))
			break;
	
		TAILQ_REMOVE(&jbd_buf->block_rec->dirty_buf_queue,
			jbd_buf,
			dirty_buf_node);

		jbd_buf->block.buf->end_write = NULL;
		jbd_buf->block.buf->end_write_arg = NULL;
		jbd_trans_finish_callback(journal,
				trans,
				jbd_buf->block_rec,
				true,
				RB_FIND(jbd_revoke_tree,
					&trans->revoke_root,
					&tmp_rec));
		jbd_trans_remove_block_rec(journal,
					jbd_buf->block_rec, trans);
		trans->data_cnt--;

		ext4_block_set(fs->bdev, &jbd_buf->block);
		TAILQ_REMOVE(&trans->buf_queue, jbd_buf, buf_node);
		ext4_free(jbd_buf);
	}

	TAILQ_FOREACH_SAFE(jbd_buf, &trans->buf_queue, buf_node, tmp) {
		struct tag_info tag_info;
		bool uuid_exist = false;
		bool is_escape = false;
		struct jbd_revoke_rec tmp_rec = {
			.lba = jbd_buf->block_rec->lba
		};
		if (!ext4_bcache_test_flag(jbd_buf->block.buf,
					   BC_DIRTY)) {
			TAILQ_REMOVE(&jbd_buf->block_rec->dirty_buf_queue,
					jbd_buf,
					dirty_buf_node);

			jbd_buf->block.buf->end_write = NULL;
			jbd_buf->block.buf->end_write_arg = NULL;

			/* The buffer has not been modified, just release
			 * that jbd_buf. */
			jbd_trans_finish_callback(journal,
					trans,
					jbd_buf->block_rec,
					true,
					RB_FIND(jbd_revoke_tree,
						&trans->revoke_root,
						&tmp_rec));
			jbd_trans_remove_block_rec(journal,
					jbd_buf->block_rec, trans);
			trans->data_cnt--;

			ext4_block_set(fs->bdev, &jbd_buf->block);
			TAILQ_REMOVE(&trans->buf_queue, jbd_buf, buf_node);
			ext4_free(jbd_buf);
			continue;
		}
		checksum = jbd_block_csum(journal->jbd_fs,
					  jbd_buf->block.data,
					  checksum,
					  trans->trans_id);
		if (((struct jbd_bhdr *)jbd_buf->block.data)->magic ==
				to_be32(JBD_MAGIC_NUMBER))
			is_escape = true;

again:
		if (!desc_iblock) {
			desc_iblock = jbd_journal_alloc_block(journal, trans);
			rc = jbd_block_get_noread(journal->jbd_fs, &desc_block, desc_iblock);
			if (rc != EOK)
				break;

			bhdr = (struct jbd_bhdr *)desc_block.data;
			jbd_set32(bhdr, magic, JBD_MAGIC_NUMBER);
			jbd_set32(bhdr, blocktype, JBD_DESCRIPTOR_BLOCK);
			jbd_set32(bhdr, sequence, trans->trans_id);

			tag_start = (char *)(bhdr + 1);
			tag_ptr = tag_start;
			uuid_exist = true;
			tag_tbl_size = journal->block_size -
				sizeof(struct jbd_bhdr);

			if (jbd_has_csum(&journal->jbd_fs->sb))
				tag_tbl_size -= sizeof(struct jbd_block_tail);

			if (!trans->start_iblock)
				trans->start_iblock = desc_iblock;

			ext4_bcache_set_dirty(desc_block.buf);
			ext4_bcache_set_flag(desc_block.buf, BC_TMP);
		}
		tag_info.block = jbd_buf->block.lb_id;
		tag_info.uuid_exist = uuid_exist;
		tag_info.is_escape = is_escape;
		if (i == trans->data_cnt - 1)
			tag_info.last_tag = true;
		else
			tag_info.last_tag = false;

		tag_info.checksum = checksum;

		if (uuid_exist)
			memcpy(tag_info.uuid, journal->jbd_fs->sb.uuid,
					UUID_SIZE);

		rc = jbd_write_block_tag(journal->jbd_fs,
				tag_ptr,
				tag_tbl_size,
				&tag_info);
		if (rc != EOK) {
			jbd_meta_csum_set(journal->jbd_fs, bhdr);
			desc_iblock = 0;
			rc = jbd_block_set(journal->jbd_fs, &desc_block);
			if (rc != EOK)
				break;

			goto again;
		}

		data_iblock = jbd_journal_alloc_block(journal, trans);
		rc = jbd_block_get_noread(journal->jbd_fs, &data_block, data_iblock);
		if (rc != EOK) {
			desc_iblock = 0;
			ext4_bcache_clear_dirty(desc_block.buf);
			jbd_block_set(journal->jbd_fs, &desc_block);
			break;
		}

		data = data_block.data;
		memcpy(data, jbd_buf->block.data,
			journal->block_size);
		if (is_escape)
			((struct jbd_bhdr *)data)->magic = 0;

		ext4_bcache_set_dirty(data_block.buf);
		ext4_bcache_set_flag(data_block.buf, BC_TMP);
		rc = jbd_block_set(journal->jbd_fs, &data_block);
		if (rc != EOK) {
			desc_iblock = 0;
			ext4_bcache_clear_dirty(desc_block.buf);
			jbd_block_set(journal->jbd_fs, &desc_block);
			break;
		}
		jbd_buf->jbd_lba = data_iblock;

		tag_ptr += tag_info.tag_bytes;
		tag_tbl_size -= tag_info.tag_bytes;

		i++;
	}
	if (rc == EOK && desc_iblock) {
		jbd_meta_csum_set(journal->jbd_fs,
				(struct jbd_bhdr *)bhdr);
		trans->data_csum = checksum;
		rc = jbd_block_set(journal->jbd_fs, &desc_block);
	}

	return rc;
}

/**@brief  Write revoke block for a transaction
 * @param  journal current journal session
 * @param  trans transaction
 * @return standard error code*/
static int
jbd_journal_prepare_revoke(struct jbd_journal *journal,
			   struct jbd_trans *trans)
{
	int rc = EOK, i = 0;
	struct ext4_block desc_block = EXT4_BLOCK_ZERO();
	int32_t tag_tbl_size = 0;
	int32_t tail_sz = 0;
	uint32_t desc_iblock = 0;
	char *blocks_entry = NULL;
	struct jbd_revoke_rec *rec, *tmp;
	struct jbd_revoke_header *header = NULL;
	int32_t record_len = 4;
	struct jbd_bhdr *bhdr = NULL;

	/* The checksum tail is reserved space, not revoke records. Folding it
	 * into `count` made every reader -- this file's recovery, e2fsck, and
	 * the Linux kernel, all of which compute
	 * (count - sizeof(header)) / record_len -- parse one entry past the
	 * last real one, into bytes the writer never set: a fabricated revoke
	 * of an arbitrary block, installed silently on every recovery. */
	if (jbd_has_csum(&journal->jbd_fs->sb))
		tail_sz = sizeof(struct jbd_block_tail);

	if (JBD_HAS_INCOMPAT_FEATURE(&journal->jbd_fs->sb,
				     JBD_FEATURE_INCOMPAT_64BIT))
		record_len = 8;

	RB_FOREACH_SAFE(rec, jbd_revoke_tree, &trans->revoke_root,
			  tmp) {
again:
		if (!desc_iblock) {
			desc_iblock = jbd_journal_alloc_block(journal, trans);
			rc = jbd_block_get_noread(journal->jbd_fs, &desc_block,
						  desc_iblock);
			if (rc != EOK)
				break;

			bhdr = (struct jbd_bhdr *)desc_block.data;
			jbd_set32(bhdr, magic, JBD_MAGIC_NUMBER);
			jbd_set32(bhdr, blocktype, JBD_REVOKE_BLOCK);
			jbd_set32(bhdr, sequence, trans->trans_id);
			
			header = (struct jbd_revoke_header *)bhdr;
			blocks_entry = (char *)(header + 1);
			tag_tbl_size = journal->block_size -
				sizeof(struct jbd_revoke_header);

			tag_tbl_size -= tail_sz;

			if (!trans->start_iblock)
				trans->start_iblock = desc_iblock;

			ext4_bcache_set_dirty(desc_block.buf);
			ext4_bcache_set_flag(desc_block.buf, BC_TMP);
		}

		if (tag_tbl_size < record_len) {
			jbd_set32(header, count,
				  journal->block_size - tag_tbl_size - tail_sz);
			jbd_meta_csum_set(journal->jbd_fs, bhdr);
			bhdr = NULL;
			desc_iblock = 0;
			header = NULL;
			rc = jbd_block_set(journal->jbd_fs, &desc_block);
			if (rc != EOK)
				break;

			goto again;
		}
		if (record_len == 8) {
			uint64_t *blocks =
				(uint64_t *)blocks_entry;
			*blocks = to_be64(rec->lba);
		} else {
			uint32_t *blocks =
				(uint32_t *)blocks_entry;
			*blocks = to_be32((uint32_t)rec->lba);
		}
		blocks_entry += record_len;
		tag_tbl_size -= record_len;

		i++;
	}
	if (rc == EOK && desc_iblock) {
		if (header != NULL)
			jbd_set32(header, count,
				  journal->block_size - tag_tbl_size - tail_sz);

		jbd_meta_csum_set(journal->jbd_fs, bhdr);
		rc = jbd_block_set(journal->jbd_fs, &desc_block);
	}

	return rc;
}

/**@brief  Put references of block descriptors in a transaction.
 * @param  journal current journal session
 * @param  trans transaction*/
void jbd_journal_cp_trans(struct jbd_journal *journal, struct jbd_trans *trans)
{
	struct jbd_buf *jbd_buf, *tmp;
	struct ext4_fs *fs = journal->jbd_fs->inode_ref.fs;
	TAILQ_FOREACH_SAFE(jbd_buf, &trans->buf_queue, buf_node,
			tmp) {
		struct ext4_block block = jbd_buf->block;
		ext4_block_set(fs->bdev, &block);
	}
}

/**@brief  Update the start block of the journal when
 *         all the contents in a transaction reach the disk.*/
static void jbd_trans_end_write(struct ext4_bcache *bc __unused,
			  struct ext4_buf *buf,
			  int res,
			  void *arg)
{
	struct jbd_buf *jbd_buf = arg;
	struct jbd_trans *trans = jbd_buf->trans;
	struct jbd_block_rec *block_rec = jbd_buf->block_rec;
	struct jbd_journal *journal = trans->journal;
	bool first_in_queue =
		trans == TAILQ_FIRST(&journal->cp_queue);
	if (res != EOK)
		trans->error = res;

	TAILQ_REMOVE(&trans->buf_queue, jbd_buf, buf_node);
	TAILQ_REMOVE(&block_rec->dirty_buf_queue,
			jbd_buf,
			dirty_buf_node);

	jbd_trans_finish_callback(journal,
			trans,
			jbd_buf->block_rec,
			false,
			false);
	if (block_rec->trans == trans && buf) {
		/* Clear the end_write and end_write_arg fields. */
		buf->end_write = NULL;
		buf->end_write_arg = NULL;
	}

	ext4_free(jbd_buf);

	trans->written_cnt++;
	if (trans->written_cnt == trans->data_cnt) {
		/* If it is the first transaction on checkpoint queue,
		 * we will shift the start of the journal to the next
		 * transaction, and remove subsequent written
		 * transactions from checkpoint queue until we find
		 * an unwritten one.
		 *
		 * Unless a write failed. trans->error was recorded above and
		 * then never read anywhere: the count completed, the tail
		 * advanced, and the journal stopped covering a block that
		 * never reached its home. The errored transaction stays on
		 * the queue and the tail stays put; the purge loop knows to
		 * stop at it. */
		if (first_in_queue && trans->error == EOK) {
			journal->start = trans->start_iblock +
				trans->alloc_blocks;
			wrap(&journal->jbd_fs->sb, journal->start);
			journal->trans_id = trans->trans_id + 1;
			TAILQ_REMOVE(&journal->cp_queue, trans, trans_node);
			jbd_journal_free_trans(journal, trans, false);

			jbd_journal_purge_cp_trans(journal, false, false);
			/* Stage the tail move; do not write it. The home
			 * writes this completion is reporting were merely
			 * issued -- on a device with a volatile cache that is
			 * not durable, and a tail advance that reaches the
			 * medium while the checkpoint it vouches for does not
			 * leaves the change in neither the log nor its home.
			 * A tail that lags is only replayed further back,
			 * which is idempotent redo; a tail that leads is
			 * corruption. The disk write happens where reuse
			 * makes it necessary: the wrap path, and stop. */
			jbd_journal_write_sb(journal);
		}
	}
}

/**@brief  Commit a transaction to the journal immediately.
 * @param  journal current journal session
 * @param  trans transaction
 * @return standard error code*/
static int __jbd_journal_commit_trans(struct jbd_journal *journal,
				      struct jbd_trans *trans)
{
	int rc = EOK;
	uint32_t last = journal->last;
	struct jbd_revoke_rec *rec, *tmp;

	trans->trans_id = journal->alloc_trans_id;
	rc = jbd_journal_prepare(journal, trans);
	if (rc != EOK)
		goto Finish;

	rc = jbd_journal_prepare_revoke(journal, trans);
	if (rc != EOK)
		goto Finish;

	if (TAILQ_EMPTY(&trans->buf_queue) &&
	    RB_EMPTY(&trans->revoke_root)) {
		/* Since there are no entries in both buffer list
		 * and revoke entry list, we do not consider trans as
		 * complete transaction and just return EOK.*/
		jbd_journal_free_trans(journal, trans, false);
		goto Finish;
	}

	/*
	 * The transaction is on its way to the medium; the commit block that
	 * vouches for it must not overtake it.
	 *
	 * Journal blocks carry BC_TMP and are written through as they are
	 * released, so everything this transaction describes has been issued by
	 * now. Issued is not committed: without this the drive is free to write
	 * the commit block first and lose the body, and recovery then replays a
	 * transaction whose contents never arrived.
	 */
	rc = ext4_block_barrier(journal->jbd_fs->bdev);
	if (rc != EOK)
		goto Finish;

	rc = jbd_trans_write_commit_block(trans);
	if (rc != EOK)
		goto Finish;

	/*
	 * And the commit block must reach the medium before the filesystem is
	 * changed to match it. Everything below this point may checkpoint --
	 * write metadata to its home location -- and a checkpoint that lands
	 * while the commit block has not is unrecoverable: the journal has no
	 * record of a change the filesystem has already made.
	 */
	rc = ext4_block_barrier(journal->jbd_fs->bdev);
	if (rc != EOK)
		goto Finish;

	journal->alloc_trans_id++;

	/* Complete the checkpoint of buffers which are revoked. */
	RB_FOREACH_SAFE(rec, jbd_revoke_tree, &trans->revoke_root,
			tmp) {
		struct jbd_block_rec *block_rec =
			jbd_trans_block_rec_lookup(journal, rec->lba);
		struct jbd_buf *jbd_buf = NULL;
		if (block_rec)
			jbd_buf = TAILQ_LAST(&block_rec->dirty_buf_queue,
					jbd_buf_dirty);
		if (jbd_buf) {
			struct ext4_buf *buf;
			struct ext4_block block = EXT4_BLOCK_ZERO();
			/*
			 * We do this to reset the ext4_buf::end_write and
			 * ext4_buf::end_write_arg fields so that the checkpoint
			 * callback won't be triggered again.
			 */
			buf = ext4_bcache_find_get(journal->jbd_fs->bdev->bc,
					&block,
					jbd_buf->block_rec->lba);
			jbd_trans_end_write(journal->jbd_fs->bdev->bc,
					buf,
					EOK,
					jbd_buf);
			if (buf)
				ext4_block_set(journal->jbd_fs->bdev, &block);
		}
	}

	if (TAILQ_EMPTY(&journal->cp_queue)) {
		/*
		 * This transaction is going to be the first object in the
		 * checkpoint queue.
		 * When the first transaction in checkpoint queue is completely
		 * written to disk, we shift the tail of the log to right.
		 */
		if (trans->data_cnt) {
			journal->start = trans->start_iblock;
			wrap(&journal->jbd_fs->sb, journal->start);
			journal->trans_id = trans->trans_id;
			/* Staged, not written -- see jbd_trans_end_write. */
			jbd_journal_write_sb(journal);
			TAILQ_INSERT_TAIL(&journal->cp_queue, trans,
					trans_node);
			jbd_journal_cp_trans(journal, trans);
		} else {
			journal->start = trans->start_iblock +
				trans->alloc_blocks;
			wrap(&journal->jbd_fs->sb, journal->start);
			journal->trans_id = trans->trans_id + 1;
			jbd_journal_write_sb(journal);
			jbd_journal_free_trans(journal, trans, false);
		}
	} else {
		/* No need to do anything to the JBD superblock. */
		TAILQ_INSERT_TAIL(&journal->cp_queue, trans,
				trans_node);
		if (trans->data_cnt)
			jbd_journal_cp_trans(journal, trans);
	}
Finish:
	if (rc != EOK && rc != ENOSPC) {
		journal->last = last;
		jbd_journal_free_trans(journal, trans, true);
	}
	return rc;
}

/**@brief  Allocate a new transaction
 * @param  journal current journal session
 * @return transaction allocated*/
struct jbd_trans *
jbd_journal_new_trans(struct jbd_journal *journal)
{
	struct jbd_trans *trans = NULL;
	trans = ext4_calloc(1, sizeof(struct jbd_trans));
	if (!trans)
		return NULL;

	/* We will assign a trans_id to this transaction,
	 * once it has been committed.*/
	trans->journal = journal;
	trans->data_csum = EXT4_CRC32_INIT;
	trans->error = EOK;
	TAILQ_INIT(&trans->buf_queue);
	return trans;
}

/**@brief  Commit a transaction to the journal immediately.
 * @param  journal current journal session
 * @param  trans transaction
 * @return standard error code*/
int jbd_journal_commit_trans(struct jbd_journal *journal,
			     struct jbd_trans *trans)
{
	int r = EOK;
	r = __jbd_journal_commit_trans(journal, trans);
	return r;
}

/**
 * @}
 */
