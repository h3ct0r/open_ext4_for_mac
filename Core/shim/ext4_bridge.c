/*
 * ext4_bridge.c — lwext4 ⇄ FSKit bridge implementation.
 *
 * Copyright (C) 2026 open_ext4_for_mac contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include <sys/xattr.h>   /* ENOATTR */
#include "ext4_bridge.h"

#include <ext4.h>
#include <ext4_fs.h>
#include <ext4_dir.h>
#include <ext4_inode.h>
#include <ext4_super.h>
#include <ext4_block_group.h>
#include <ext4_extent.h>
#include <ext4_blockdev.h>
#include <ext4_bcache.h>
#include <ext4_trans.h>
#include <ext4_xattr.h>
#include <ext4_crc32.h>
#include <ext4_types.h>
#include <ext4_misc.h>
#include <ext4_errno.h>
#include <ext4_mkfs.h>

#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <stdio.h>
#include <stdarg.h>
#include <time.h>
#include <pthread.h>

/*
 * Build switch for bisecting the unwritten-extent fast path (patches
 * 0045-0046). With it set, a write into preallocated space takes the ordinary
 * route -- convert the extent, which zeroes it, then write -- instead of
 * writing into the still-unwritten extent and marking it written afterwards.
 * Slower by roughly a factor of two on the medium, and the thing to compare
 * against when a corruption suite reports a rate rather than a reproduction.
 */
#ifndef EXT4B_NO_UNWRITTEN_FASTPATH
#define EXT4B_NO_UNWRITTEN_FASTPATH 0
#endif
#include <stdatomic.h>

/* One volume per extension instance (FSUnaryFileSystem), so fixed names are
 * sufficient for lwext4's global device/mount-point tables. */
#define BRIDGE_DEV_NAME "ext4dev"
#define BRIDGE_MOUNT_POINT "/vol/"

/* Block cache entries. lwext4's default of 8 is sized for microcontrollers;
 * a desktop volume needs far more to avoid thrashing metadata reads. */
#define BRIDGE_BCACHE_BLOCKS 1024

/*
 * Allocating ahead.
 *
 * A bulk write asks the extent layer for exactly the blocks it is about to
 * write, and macOS never hands us more than a megabyte at a time. When one
 * file is being written that is fine -- the next request continues where the
 * last one ended. When several are in flight, which is what a slow medium
 * produces, each file's next request finds its goal taken by whichever file
 * allocated in between, and every write call becomes its own extent. Measured
 * with `ext4dump interleave`: eight 32 MiB files written a megabyte at a time
 * are 2 extents each in sequence and 34 each interleaved.
 *
 * So ask for more than the write needs and leave the rest mapped past
 * end-of-file, where the next write to that inode will find it already
 * mapped. This is, in miniature, what ext4's mballoc inode preallocation
 * does, and it comes with mballoc's obligation: the surplus has to go back.
 *
 * Three things bound it, because an allocator that reserves and forgets is a
 * worse bug than the fragmentation it cures:
 *
 *   - only bulk writes reserve (EXT4B_RESERVE_TRIGGER), so a volume full of
 *     small files never sees it at all;
 *   - at most EXT4B_RESERVE_SLOTS inodes hold a reservation at once, and
 *     taking the ninth slot returns the oldest -- so the space in flight is
 *     capped at slots x ahead, not at the number of files being copied;
 *   - unmount returns whatever is left.
 *
 * The ceiling is deliberately modest for the same reason: a reservation that
 * is too large turns fragmentation of files into fragmentation of free space,
 * which is worse on a volume that fills up.
 */
#define EXT4B_RESERVE_SLOTS    8       /* inodes that may hold one at once */
#define EXT4B_RESERVE_TRIGGER  64      /* blocks in one write before reserving */
#define EXT4B_RESERVE_AHEAD    2048    /* blocks to take beyond the write */

/* How many mutations may share one journal transaction. See txn_finish.
 *
 * Sixteen, and the history matters, because this was sixteen once before and
 * got turned off the same afternoon for corrupting volumes under write
 * reordering. The suspicion recorded here at the time -- writes outside the
 * transaction reordering against the log -- was close but not the mechanism.
 * The journal's own tail pointer was written on every checkpoint completion
 * with no barrier anywhere near it, so it could land before its checkpoint or
 * be lost while the log space it freed was reused. Batching did not cause
 * that; it made the log wrap inside a test run, which is what let anyone see
 * it.
 *
 * lwext4 patches 0017-0020 close it: recoverable-by-Linux tag checksums,
 * parseable revoke counts, revoke-on-free, and a lazily advanced tail that is
 * written with barriers exactly where reuse makes it matter. The claim is not
 * argued from the design; it is measured, by Tests/run_reorder_tests.sh --
 * 236 torn images across geometries x workloads x batch {1,16,64}, every one
 * recovered by the real Linux kernel, with the barriers-ignored negative
 * controls still failing so the suite is known capable of saying no.
 *
 * What batching trades is bounded and stated: an operation is durable when
 * something asks -- sync(2), the batch filling, the journal running low, or
 * unmount -- not when the call returns. That is the contract Linux ext4,
 * HFS+ and APFS give. An undrained batch dies cleanly, which the mount-crash
 * suite's stage 1b asserts. EXT4B_TXN_BATCH overrides for anyone measuring.
 *
 * The value is 64 because 16 was measured and found expensive. Metadata is
 * written home once per transaction, and a small-file workload rewrites the
 * same few blocks every time: 2,000 files touched 138 distinct metadata
 * blocks about seventy times each. Transactions, not bytes, were the cost.
 *
 *   batch   writes   bytes   flushes   unmount
 *      16   20,518   96 MB     7,739   53 writes
 *      64    2,932    7 MB       128   26 writes
 *     256    2,342    3 MB        34   --
 *
 * Seven times fewer commands and thirteen times fewer bytes for the same
 * 2,000 files, all e2fsck-clean, and the eject gets cheaper rather than
 * dearer -- the objection a wider batch invites, measured and answered.
 *
 * 64 rather than 256 because it is the largest value the crash evidence
 * already covers: run_reorder_tests.sh tears 236 images across batch
 * {1,16,64} and the real Linux kernel recovers every one. Going further
 * would mean widening the durability window past what has been tested. */
#define BRIDGE_TXN_BATCH 64

/* ============================================================== logging == */

static ext4b_log_fn g_log_fn;
static void *g_log_ctx;

void ext4b_set_logger(ext4b_log_fn fn, void *ctx)
{
    g_log_fn = fn;
    g_log_ctx = ctx;
}

static void bridge_log(int level, const char *msg)
{
    if (g_log_fn)
        g_log_fn(g_log_ctx, level, msg);
}

/* The formatted variant. The mount path's log lines used to carry no numbers
 * at all -- "replaying journal", "recovery failed" -- and a hardware-only
 * failure then cost an iteration per missing fact. Every failure line gets
 * its errno; every phase that can be slow gets its duration. */
static void bridge_logf(int level, const char *fmt, ...)
{
    char msg[256];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(msg, sizeof(msg), fmt, ap);
    va_end(ap);
    bridge_log(level, msg);
}

static uint64_t mono_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000u + (uint64_t)ts.tv_nsec / 1000000u;
}

/* Defined with the item helpers below; the mount path wants it early. */
static struct ext4_fs *bridge_fs(ext4b_device *dev);

/*
 * Where a failed lwext4 assertion goes. Patch 0026 points ext4_assert at this
 * instead of a printf to stdout: in a sandboxed appex stdout reaches no one,
 * so the reason the driver just aborted was invisible. Routed through the
 * bridge logger, it lands in os_log (appex) or on stderr (the tool). Still
 * fail-stop -- a filesystem that runs past a broken invariant writes garbage
 * with authority; aborting tears the mount down and leaves a record instead.
 */
void ext4b_assert_fail(const char *file, int line)
{
    char msg[256];
    snprintf(msg, sizeof msg, "lwext4 assertion failed at %s:%d", file, line);
    bridge_log(3, msg);
    fflush(NULL);
    abort();
}

#ifdef EXT4B_TEST_HOOKS
/* Deliberately trip an lwext4 assertion, to prove the failure path reports
 * through the logger and not to stdout. Test builds only. */
void ext4b_trip_assert(void)
{
    ext4_assert(0);
}
#endif

/* Commit any batched-but-uncommitted mutations. Defined with the transaction
 * machinery below; declared here because sync and unmount both need it and
 * both sit above it. */
static int txn_drain(ext4b_device *dev);

/* Return every block held past end-of-file by the allocate-ahead table.
 * Declared here for the same reason: unmount sits above the write path that
 * defines it, and unmount is where the last reservations have to go back. */
static int resv_drain(ext4b_device *dev, struct ext4_fs *fs);

/* Drop an inode from that table without returning anything, for the paths
 * that have already settled its blocks -- a truncate, a delete, an explicit
 * preallocation. Declared here because several of them also sit above the
 * write path. */
static void resv_forget(ext4b_device *dev, uint32_t inode);

/* =============================================== concurrent core entry == */
/*
 * lwext4 has no internal locking. Its mount-point table, block cache and
 * journal are global mutable state, and the transaction in flight lives in a
 * single field -- fs->curr_trans -- shared by every caller. Two threads inside
 * it at once is not a performance problem, it is corruption: the second one's
 * txn_begin finds the first one's transaction already open and silently joins
 * it, and whichever finishes first commits a half-built transaction on the
 * other's behalf.
 *
 * The Swift side serialises everything through Ext4Executor, so none of this
 * should ever happen. "Should" is the problem. That discipline is a convention
 * spread across a dozen files, held up by comments, and nothing enforces it;
 * it has already been broken once, from the attribute path, and was found by
 * a hang rather than by a check.
 *
 * So this measures it instead. Two places are watched, because they fail at
 * different scales:
 *
 *   - block I/O, where two threads overlap inside a single read or write;
 *   - transactions, where two threads need not overlap in time at all for the
 *     second to walk into the first one's open transaction.
 *
 * It reports and does not block. A lock at either point would be the wrong
 * granularity -- fine enough to serialise block accesses, too coarse to know
 * where a transaction begins and ends -- and a detector that changes the
 * timing it is trying to observe is worth less than one that does not.
 */

static _Atomic(uintptr_t) g_io_owner;        /* thread inside a block op */
static _Atomic(uintptr_t) g_txn_owner;       /* thread holding fs->curr_trans */
static _Atomic(unsigned)  g_collisions;

static void report_collision(const char *what, uintptr_t me, uintptr_t owner)
{
    unsigned n = atomic_fetch_add(&g_collisions, 1) + 1;

    /* Loud for the first few, then thinned out: once this is firing it can
     * fire thousands of times a second, and a log that costs more than the
     * work it describes changes the thing being measured. */
    if (n <= 8 || n % 500 == 0) {
        char msg[192];
        snprintf(msg, sizeof msg,
                 "CONCURRENT CORE ENTRY (%s): thread %p entered while %p was "
                 "already inside lwext4 -- collision %u",
                 what, (void *)me, (void *)owner, n);
        bridge_log(3, msg);
    }
}

unsigned ext4b_core_collisions(void)
{
    return atomic_load(&g_collisions);
}

static void io_enter(const char *what)
{
    uintptr_t me = (uintptr_t)pthread_self();
    uintptr_t prev = 0;

    if (!atomic_compare_exchange_strong(&g_io_owner, &prev, me) && prev != me)
        report_collision(what, me, prev);
}

static void io_leave(void)
{
    atomic_store(&g_io_owner, 0);
}

const char *ext4b_strerror(int err)
{
    switch (err) {
    case 0:        return "success";
    case ENOENT:   return "no such file or directory";
    case ENOTDIR:  return "not a directory";
    case EISDIR:   return "is a directory";
    case ENOSPC:   return "no space left on device";
    case EROFS:    return "read-only file system";
    case ENOTSUP:  return "unsupported filesystem feature";
    case EIO:      return "I/O error";
    case EINVAL:   return "invalid argument";
    case ENOMEM:   return "out of memory";
    default:       return strerror(err);
    }
}

/* =============================================================== device == */

struct ext4b_device {
    struct ext4_blockdev       bdev;
    struct ext4_blockdev_iface iface;
    struct ext4_bcache         bcache;

    void          *ctx;
    ext4b_read_fn  read_fn;
    ext4b_write_fn write_fn;
    ext4b_flush_fn flush_fn;

    uint8_t *block_buf;      /* iface.ph_bbuf backing store */
    bool     read_only;
    bool     mounted;
    bool     journal_running;
    /* Said once per mount, not once per statfs: Finder asks continually. */
    bool     warned_free_blocks;
    uint64_t warned_free_at;    /* last impossible count reported */

    /* Journal batching. `txn_ops` counts mutations accumulated in the
     * currently open transaction; `txn_batch` is how many are allowed to
     * accumulate before it commits. See txn_finish. */
    uint32_t txn_ops;
    uint32_t txn_batch;
    bool     bcache_ready;
    bool     skip_orphan_cleanup;   /* tests only; see ext4b_set_orphan_cleanup */

    /* Inodes currently holding blocks allocated ahead of what they have
     * written, and the logical block each reservation reaches. See
     * "Allocating ahead" above. An inode of 0 means the slot is free; the
     * table is walked linearly because it is eight entries long. */
    struct {
        uint32_t inode;
        uint32_t end_lblk;      /* first logical block NOT reserved */
    } resv[EXT4B_RESERVE_SLOTS];
    uint32_t resv_next;             /* round-robin eviction cursor */
};

/*
 * lwext4 speaks in whole physical blocks; our callbacks speak in byte ranges.
 * The multiply is done in 64-bit to avoid overflow on large volumes.
 */
static int bd_bread(struct ext4_blockdev *bdev, void *buf,
                    uint64_t blk_id, uint32_t blk_cnt)
{
    ext4b_device *dev = bdev->bdif->p_user;
    if (!dev || !dev->read_fn)
        return EIO;
    if (blk_cnt == 0)
        return EOK;

    uint64_t off = blk_id * (uint64_t)dev->iface.ph_bsize;
    size_t   len = (size_t)blk_cnt * dev->iface.ph_bsize;

    io_enter("read");
    int r = dev->read_fn(dev->ctx, buf, off, len) == 0 ? EOK : EIO;
    io_leave();
    return r;
}

static int bd_bwrite(struct ext4_blockdev *bdev, const void *buf,
                     uint64_t blk_id, uint32_t blk_cnt)
{
    ext4b_device *dev = bdev->bdif->p_user;
    if (!dev || !dev->write_fn)
        return EIO;
    if (dev->read_only)
        return EROFS;
    if (blk_cnt == 0)
        return EOK;

    uint64_t off = blk_id * (uint64_t)dev->iface.ph_bsize;
    size_t   len = (size_t)blk_cnt * dev->iface.ph_bsize;

    io_enter("write");
    int r = dev->write_fn(dev->ctx, buf, off, len) == 0 ? EOK : EIO;
    io_leave();
    return r;
}

static int bd_open(struct ext4_blockdev *bdev)   { (void)bdev; return EOK; }
static int bd_close(struct ext4_blockdev *bdev)  { (void)bdev; return EOK; }
/*
 * The journal's write barrier.
 *
 * lwext4 calls this on both sides of the commit block (patch 0014). Everything
 * above it in this file calls flush_fn at its own boundaries -- after an
 * operation, at sync, at unmount -- which separates one transaction from the
 * next but does nothing to order a transaction against its own commit block.
 * That is the ordering that matters, and this is the only path that reaches
 * it.
 */
static int bd_flush(struct ext4_blockdev *bdev)
{
    ext4b_device *dev = bdev->bdif->p_user;
    if (!dev || !dev->flush_fn || dev->read_only)
        return EOK;

    return dev->flush_fn(dev->ctx) == 0 ? EOK : EIO;
}

static int bd_lock(struct ext4_blockdev *bdev)   { (void)bdev; return EOK; }
static int bd_unlock(struct ext4_blockdev *bdev) { (void)bdev; return EOK; }

ext4b_device *ext4b_device_create(void *ctx,
                                  uint32_t block_size,
                                  uint64_t block_count,
                                  bool read_only,
                                  ext4b_read_fn read_fn,
                                  ext4b_write_fn write_fn,
                                  ext4b_flush_fn flush_fn)
{
    if (block_size == 0 || (block_size & (block_size - 1)) != 0)
        return NULL;   /* must be a power of two */
    if (block_count == 0 || read_fn == NULL)
        return NULL;

    ext4b_device *dev = calloc(1, sizeof(*dev));
    if (!dev)
        return NULL;

    dev->block_buf = calloc(1, block_size);
    if (!dev->block_buf) {
        free(dev);
        return NULL;
    }

    dev->ctx       = ctx;
    dev->read_fn   = read_fn;
    dev->write_fn  = write_fn;
    dev->flush_fn  = flush_fn;
    dev->txn_batch = BRIDGE_TXN_BATCH;
    dev->read_only = read_only;

    dev->iface.open     = bd_open;
    dev->iface.bread    = bd_bread;
    dev->iface.bwrite   = bd_bwrite;
    dev->iface.close    = bd_close;
    dev->iface.lock     = bd_lock;
    dev->iface.unlock   = bd_unlock;
    dev->iface.flush    = bd_flush;
    dev->iface.ph_bsize = block_size;
    dev->iface.ph_bcnt  = block_count;
    dev->iface.ph_bbuf  = dev->block_buf;
    dev->iface.p_user   = dev;

    dev->bdev.bdif        = &dev->iface;
    dev->bdev.part_offset = 0;
    dev->bdev.part_size   = block_count * (uint64_t)block_size;

    return dev;
}

void ext4b_device_destroy(ext4b_device *dev)
{
    if (!dev)
        return;
    if (dev->mounted)
        ext4b_unmount(dev);
    free(dev->block_buf);
    free(dev);
}

/*
 * How many mutations may share one journal transaction. A real tunable, not a
 * test hook: batching is 11x on small-file work and the default (16) is the
 * shipping value. The old code read EXT4B_TXN_BATCH from the environment
 * inside this library -- a getenv the appex carried but never used; the tool
 * calls this setter instead, so the shipping core reads no environment at all.
 * Clamped to [1, 1024]; 1 is transaction-per-operation, the pre-batching
 * behaviour the crash suites compare against.
 */
void ext4b_set_txn_batch(ext4b_device *dev, uint32_t batch)
{
    if (!dev)
        return;
    if (batch < 1)
        batch = 1;
    if (batch > 1024)
        batch = 1024;
    dev->txn_batch = batch;
}

/* ================================================================ probe == */

/* Superblock field offsets, from the ext4 on-disk specification. Parsed by
 * hand rather than via lwext4 so that probing never mounts and never trusts
 * structure sizes on untrusted media. */
#define SB_OFFSET              1024
#ifndef EXT4B_BUILD_ID
#define EXT4B_BUILD_ID "unknown"
#endif

#define SB_SIZE                1024
#define SBF_INODES_COUNT       0x000
#define SBF_BLOCKS_COUNT_LO    0x004
#define SBF_FREE_BLOCKS_LO     0x00C
#define SBF_FREE_INODES        0x010
#define SBF_LOG_BLOCK_SIZE     0x018
#define SBF_MAGIC              0x038
#define SBF_STATE              0x03A
#define SBF_FEATURE_COMPAT     0x05C
#define SBF_FEATURE_INCOMPAT   0x060
#define SBF_FEATURE_RO_COMPAT  0x064
#define SBF_UUID               0x068
#define SBF_VOLUME_NAME        0x078
#define SBF_BLOCKS_COUNT_HI    0x150
#define SBF_FREE_BLOCKS_HI     0x158
#define SBF_CHECKSUM_SEED      0x270
#define SBF_CHECKSUM           0x3FC
/* The geometry fields. Everything the driver later computes an ADDRESS from,
 * which is the class that turns a bad value into an out-of-bounds access
 * rather than a wrong answer. See the gate in ext4b_probe. */
#define SBF_FIRST_DATA_BLOCK   0x014
#define SBF_BLOCKS_PER_GROUP   0x020
#define SBF_INODES_PER_GROUP   0x028
#define SBF_FIRST_INO          0x054
#define SBF_INODE_SIZE         0x058
#define SBF_JOURNAL_INUM       0x0E0
#define SBF_RESERVED_GDT       0x0CE
#define SBF_DESC_SIZE          0x0FE
#define SBF_LOG_GROUPS_PER_FLEX 0x174

#define EXT_MAGIC 0xEF53

/*
 * Feature gate. Deliberately expressed as an allow-list: any bit we have not
 * explicitly vetted causes a refusal or a read-only downgrade. An unknown
 * INCOMPAT bit means the on-disk layout may differ in ways we cannot see, so
 * writing would risk corruption.
 */
#define INCOMPAT_SUPPORTED  (0x0002 /* FILETYPE  */ | \
                             0x0004 /* RECOVER   */ | \
                             0x0040 /* EXTENTS   */ | \
                             0x0080 /* 64BIT     */ | \
                             0x0100 /* MMP       */ | \
                             0x0200 /* FLEX_BG   */ | \
                             0x2000 /* CSUM_SEED — conditional, see below */)

#define RO_COMPAT_SUPPORTED (0x0001 /* SPARSE_SUPER */ | \
                             0x0002 /* LARGE_FILE   */ | \
                             0x0008 /* HUGE_FILE    */ | \
                             0x0010 /* GDT_CSUM     */ | \
                             0x0020 /* DIR_NLINK    */ | \
                             0x0040 /* EXTRA_ISIZE  */ | \
                             0x0400 /* METADATA_CSUM*/)

#define INCOMPAT_RECOVER 0x0004
#define COMPAT_HAS_JOURNAL 0x0004

static uint16_t rd16(const uint8_t *p, size_t off)
{
    return (uint16_t)(p[off] | ((uint16_t)p[off + 1] << 8));
}

static uint32_t rd32(const uint8_t *p, size_t off)
{
    return (uint32_t)p[off]
         | ((uint32_t)p[off + 1] << 8)
         | ((uint32_t)p[off + 2] << 16)
         | ((uint32_t)p[off + 3] << 24);
}

int ext4b_probe(ext4b_device *dev, ext4b_probe_info *out)
{
    if (!dev || !out)
        return EINVAL;

    memset(out, 0, sizeof(*out));
    out->verdict = EXT4B_PROBE_NOT_EXT;

    uint8_t sb[SB_SIZE];
    if (dev->read_fn(dev->ctx, sb, SB_OFFSET, SB_SIZE) != 0)
        return EIO;

    if (rd16(sb, SBF_MAGIC) != EXT_MAGIC)
        return EOK;     /* not ext — a valid answer, not an error */

    uint32_t log_bs = rd32(sb, SBF_LOG_BLOCK_SIZE);
    if (log_bs > 6) {   /* 1 KiB << 6 == 64 KiB, the ext4 maximum */
        out->verdict = EXT4B_PROBE_UNSUPPORTED;
        snprintf(out->unsupported, sizeof(out->unsupported),
                 "implausible block size shift (%u)", log_bs);
        return EOK;
    }

    out->block_size        = 1024u << log_bs;
    out->feature_compat    = rd32(sb, SBF_FEATURE_COMPAT);
    out->feature_incompat  = rd32(sb, SBF_FEATURE_INCOMPAT);
    out->feature_ro_compat = rd32(sb, SBF_FEATURE_RO_COMPAT);

    out->block_count  = rd32(sb, SBF_BLOCKS_COUNT_LO);
    out->free_blocks  = rd32(sb, SBF_FREE_BLOCKS_LO);
    if (out->feature_incompat & 0x0080) {   /* 64BIT */
        out->block_count |= (uint64_t)rd32(sb, SBF_BLOCKS_COUNT_HI) << 32;
        out->free_blocks |= (uint64_t)rd32(sb, SBF_FREE_BLOCKS_HI) << 32;
    }
    out->inode_count = rd32(sb, SBF_INODES_COUNT);
    out->free_inodes = rd32(sb, SBF_FREE_INODES);

    memcpy(out->uuid, sb + SBF_UUID, 16);
    memcpy(out->label, sb + SBF_VOLUME_NAME, 16);
    out->label[16] = '\0';

    out->has_journal    = (out->feature_compat & COMPAT_HAS_JOURNAL) != 0;
    out->needs_recovery = (out->feature_incompat & INCOMPAT_RECOVER) != 0;

    /* Which ext generation are we looking at? */
    if (out->feature_incompat & 0x0040)        /* EXTENTS */
        out->generation = 4;
    else if (out->has_journal)
        out->generation = 3;
    else
        out->generation = 2;

    /*
     * Sanity: the volume must not claim to be larger than the device. Done by
     * division, not multiplication: block_count is 64-bit and read from
     * untrusted media, and block_size can be 65536, so block_count *
     * block_size can wrap past 2^64 and a wildly oversized volume would sail
     * through a `product > dev_bytes` test. dev_bytes cannot overflow (real
     * device geometry), so comparing block_count against dev_bytes/block_size
     * is exact and wrap-free.
     */
    uint64_t dev_bytes = dev->iface.ph_bcnt * (uint64_t)dev->iface.ph_bsize;
    uint64_t max_blocks = out->block_size ? dev_bytes / out->block_size : 0;
    if (out->block_count == 0 || out->block_count > max_blocks) {
        out->verdict = EXT4B_PROBE_UNSUPPORTED;
        snprintf(out->unsupported, sizeof(out->unsupported),
                 "superblock claims %llu blocks, larger than the device",
                 (unsigned long long)out->block_count);
        return EOK;
    }

    /*
     * The geometry gate.
     *
     * Everything above this point checks that the volume is ext and that it
     * fits on the device. This checks that the numbers the driver will
     * compute ADDRESSES from are possible -- which is a different question,
     * and the one that decides whether a corrupt superblock produces a wrong
     * answer or an out-of-bounds access.
     *
     * Found by fuzzing, and this is what it looked like: s_inode_size changed
     * from 256 to 54915, the superblock checksum re-stamped so the volume
     * still passed every check above, and then ext4_fs_inode_checksum read
     * 54915 bytes out of a block-sized buffer on the first readdir. Six bytes
     * on the medium, a heap-buffer-overflow from an `ls`.
     *
     * Each of these is a value ext4 itself cannot produce. Refusing them is
     * not a policy choice about what to support; it is declining to do
     * arithmetic on numbers that cannot be right. The reasons are named
     * individually because "unsupported filesystem" sends a user looking for
     * a different driver, and "e2fsck is the fix" sends them somewhere
     * useful.
     */
    {
        uint32_t bs                = out->block_size;
        uint32_t inode_size        = rd16(sb, SBF_INODE_SIZE);
        uint32_t first_data_block  = rd32(sb, SBF_FIRST_DATA_BLOCK);
        uint32_t blocks_per_group  = rd32(sb, SBF_BLOCKS_PER_GROUP);
        uint32_t inodes_per_group  = rd32(sb, SBF_INODES_PER_GROUP);
        uint32_t first_ino         = rd32(sb, SBF_FIRST_INO);
        uint32_t journal_inum      = rd32(sb, SBF_JOURNAL_INUM);
        uint32_t reserved_gdt      = rd16(sb, SBF_RESERVED_GDT);
        uint32_t flex_shift        = sb[SBF_LOG_GROUPS_PER_FLEX];
        uint32_t rev_level         = rd32(sb, 0x04C);
        const char *why = NULL;
        char detail[96];

        /* rev 0 has no s_inode_size field at all: the value is fixed at 128
         * and the field holds something else entirely. */
        if (rev_level == 0)
            inode_size = 128;

        if (inode_size < 128 || inode_size > bs)
            why = "inode size is outside [128, block size]";
        else if (inode_size & (inode_size - 1))
            why = "inode size is not a power of two";
        else if (blocks_per_group < 8 || blocks_per_group > 8u * bs)
            why = "blocks per group is outside [8, 8 x block size]";
        else if (blocks_per_group % 8)
            why = "blocks per group is not a multiple of 8";
        else if (inodes_per_group == 0 || inodes_per_group > 8u * bs)
            why = "inodes per group is outside [1, 8 x block size]";
        else if (inodes_per_group % 8)
            why = "inodes per group is not a multiple of 8";
        else if (inodes_per_group > out->inode_count)
            why = "inodes per group exceeds the total inode count";
        else if (first_data_block != (bs == 1024 ? 1u : 0u))
            why = "first data block does not match the block size";
        else if (out->block_count <= first_data_block)
            why = "the volume has no blocks past its first";
        /* Below 11, the reserved inodes overlap the ones the driver hands
         * out; ext4 has never used a value other than 11 on a rev-1 volume. */
        else if (rev_level != 0 && first_ino < 11)
            why = "first non-reserved inode is below 11";
        else if (journal_inum > out->inode_count)
            why = "journal inode is past the end of the inode table";
        else if (flex_shift > 31)
            why = "flex_bg group shift is impossible";
        else if (reserved_gdt > bs / 4)
            why = "reserved GDT blocks exceed what one block can address";

        /*
         * s_desc_size, whether or not 64BIT is set.
         *
         * ext4 itself ignores the field without 64BIT, and the first version
         * of this gate did too. lwext4 does not: ext4_sb_get_desc_size()
         * returns the stored value clamped only at the bottom, and every
         * descriptor address in the tree is computed from it. An odd value
         * makes (i % dsc_cnt) * dsc_size an odd offset, and the struct
         * pointer built on it is misaligned:
         *
         *   ext4_block_group.h:158: runtime error: member access within
         *   misaligned address ... which requires 4 byte alignment
         *
         * reached from our own free-space audit during ext4b_mount. A value
         * larger than the block makes bsize / dsc_size zero, and the next
         * line divides by it. So: if it is set at all, it has to be a size a
         * descriptor table could have.
         */
        if (!why) {
            uint32_t desc_size = rd16(sb, SBF_DESC_SIZE);
            if (desc_size != 0) {
                if (desc_size < 32 || desc_size > bs)
                    why = "group descriptor size is outside [32, block size]";
                else if (desc_size & (desc_size - 1))
                    why = "group descriptor size is not a power of two";
            } else if (out->feature_incompat & 0x0080) {   /* 64BIT */
                why = "64-bit volume with no group descriptor size";
            }
        }

        /* And the group count has to fit in the 32 bits every caller uses. */
        if (!why) {
            uint64_t groups = (out->block_count - first_data_block +
                               blocks_per_group - 1) / blocks_per_group;
            if (groups == 0 || groups > 0xFFFFFFFFull)
                why = "the volume needs more block groups than ext4 can address";
        }

        if (why) {
            out->verdict = EXT4B_PROBE_UNSUPPORTED;
            snprintf(detail, sizeof(detail), "%s", why);
            snprintf(out->unsupported, sizeof(out->unsupported),
                     "superblock geometry is impossible: %s "
                     "(the superblock is damaged; e2fsck is the fix)", detail);
            return EOK;
        }
    }

    /*
     * A damaged superblock reads as an unsupported one. lwext4 folds its
     * checksum test into ext4_sb_check, the same boolean that reports feature
     * problems, so a volume whose superblock checksum does not match is
     * refused as "unsupported filesystem feature" -- sending the user to look
     * for a driver that supports it, when the superblock is simply damaged and
     * e2fsck is the fix. Checked here, before the feature gate, because a
     * corrupt superblock is also the reason feature bits cannot be believed.
     */
    if ((out->feature_ro_compat & 0x0400) &&      /* METADATA_CSUM */
        rd32(sb, SBF_CHECKSUM) != ext4_crc32c(EXT4_CRC32_INIT, sb, SBF_CHECKSUM)) {
        out->verdict = EXT4B_PROBE_UNSUPPORTED;
        snprintf(out->unsupported, sizeof(out->unsupported),
                 "superblock checksum mismatch: the superblock is damaged, "
                 "not unsupported (e2fsck is the fix)");
        return EOK;
    }

    uint32_t bad_incompat = out->feature_incompat & ~(uint32_t)INCOMPAT_SUPPORTED;
    if (bad_incompat) {
        out->verdict = EXT4B_PROBE_UNSUPPORTED;
        /* Name the common ones so the user gets an actionable message. */
        const char *why = "unsupported incompatible features";
        if (bad_incompat & 0x10000) why = "filesystem uses encryption (fscrypt)";
        else if (bad_incompat & 0x20000) why = "filesystem uses case-folding";
        else if (bad_incompat & 0x8000) why = "filesystem uses inline data";
        else if (bad_incompat & 0x0400) why = "filesystem uses EA inodes";
        else if (bad_incompat & 0x4000) why = "filesystem uses large directories";
        else if (bad_incompat & 0x0001) why = "filesystem uses compression";
        else if (bad_incompat & 0x0008) why = "this is an external journal device";
        /*
         * META_BG was on the supported list until it was measured.
         *
         * On a meta_bg volume e2fsck calls clean -- 320 files, no errors --
         * this driver fails the group descriptor checksum for group 2, cannot
         * read inode 209 at all, and reports 137 GB of file data from an `ls`
         * of a 5 MiB volume. Writing to one is worse: 150 files created leave
         * 59 inodes in groups still flagged INODE_UNINIT, which e2fsck reports
         * as damage. The identical volume without meta_bg is clean both ways,
         * so it is the feature and not the allocator.
         *
         * Under meta_bg the group descriptors are scattered through the volume
         * instead of following the superblock, and lwext4's placement
         * arithmetic does not agree with e2fsprogs about where they are past
         * the first meta block group. Both shim helpers that read descriptors
         * directly already returned ENOTSUP on such a volume, which was the
         * standing hint that nobody had checked the rest of it.
         *
         * Refused rather than downgraded to read-only, deliberately: a driver
         * that returns the wrong bytes is worse than one that declines. The
         * first version of this fix WAS a read-only downgrade, until `check`
         * on the seed reported an inode it could not read and the reads turned
         * out to be wrong as well.
         *
         * Found while building the fuzzing seed corpus, on a volume nothing
         * had mutated. The fuzzing only got as far as making us write to one.
         */
        else if (bad_incompat & 0x0010)
            why = "filesystem uses meta_bg descriptor placement, which this "
                  "driver reads incorrectly";
        snprintf(out->unsupported, sizeof(out->unsupported),
                 "%s (incompat 0x%08x)", why, bad_incompat);
        return EOK;
    }

    uint32_t bad_ro = out->feature_ro_compat & ~(uint32_t)RO_COMPAT_SUPPORTED;
    if (bad_ro) {
        out->verdict = EXT4B_PROBE_READ_ONLY;
        const char *why = "unsupported read-only features";
        if (bad_ro & 0x8000) why = "filesystem uses fs-verity";
        else if (bad_ro & 0x0200) why = "filesystem uses bigalloc";
        else if (bad_ro & 0x0100) why = "filesystem uses quotas";
        else if (bad_ro & 0x2000) why = "filesystem uses project quotas";
        snprintf(out->unsupported, sizeof(out->unsupported),
                 "%s (ro_compat 0x%08x)", why, bad_ro);
        return EOK;
    }

    /*
     * metadata_csum_seed (INCOMPAT 0x2000) stores an explicit checksum seed in
     * the superblock so that tune2fs can change the volume UUID without
     * rewriting every metadata checksum on it. mke2fs sets it to
     * crc32c(~0, uuid) at creation, so the stored seed and the derived one
     * agree until somebody runs `tune2fs -U`.
     *
     * lwext4 used to derive the seed from the UUID everywhere and had no
     * notion of the field, so a volume whose UUID had been changed was
     * downgraded to read-only here -- every checksum lwext4 wrote would have
     * been wrong. patches/lwext4/0012 gives it ext4_sb_csum_seed(), which
     * honours the stored value, so the volume is now writable and the
     * downgrade is gone. The suites write to that fixture and hand it to
     * e2fsck, which is what a wrong seed would fail.
     */

    out->verdict = EXT4B_PROBE_USABLE;
    return EOK;
}

/* =============================================================== format == */

int ext4b_format(ext4b_device *dev, const ext4b_format_options *opts)
{
    if (!dev || !opts)
        return EINVAL;
    if (dev->mounted)
        return EBUSY;
    if (dev->read_only || !dev->write_fn)
        return EROFS;

    int fs_type;
    switch (opts->generation) {
    case 2:  fs_type = F_SET_EXT2; break;
    case 3:  fs_type = F_SET_EXT3; break;
    case 4:  fs_type = F_SET_EXT4; break;
    default: return EINVAL;
    }

    /* ext2 has no journal by definition; asking for one would produce a
     * filesystem whose feature bits contradict its own generation. */
    if (opts->generation == 2 && opts->journal)
        return EINVAL;

    switch (opts->block_size) {
    case 0: case 1024: case 2048: case 4096: break;
    default: return EINVAL;
    }

    /* lwext4 addresses the volume in filesystem blocks, so it cannot format a
     * device whose blocks are larger than the filesystem block size. */
    uint32_t block_size = opts->block_size ? opts->block_size : 4096;
    if (dev->iface.ph_bsize > block_size)
        return EINVAL;

    /*
     * Clear foreign filesystem signatures before building ours. ext4 never
     * touches the first 1024 bytes (the "boot area"), which is exactly where
     * FAT, exFAT and NTFS keep their magic -- formatting over a FAT volume
     * would otherwise leave a boot sector that a FAT prober still claims,
     * and the volume goes to the wrong driver. The last 64 KiB gets the same
     * treatment for the signatures that anchor at the end (HFS+ alternate
     * header, RAID metadata). FSKit has a wipeResource facility for this,
     * but it is not reachable from a CLI-initiated format ("no connector
     * talking to fskitd is available"), and 128 KiB of zeroes needs no
     * facility.
     */
    {
        enum { WIPE_SPAN = 64 * 1024 };
        uint64_t dev_bytes = dev->iface.ph_bcnt * (uint64_t)dev->iface.ph_bsize;
        uint8_t *zeroes = calloc(1, WIPE_SPAN);
        if (!zeroes)
            return ENOMEM;
        int wr = 0;
        if (dev_bytes <= 2 * WIPE_SPAN) {
            for (uint64_t off = 0; off < dev_bytes && wr == 0; off += WIPE_SPAN) {
                size_t len = (size_t)((dev_bytes - off < WIPE_SPAN)
                                      ? dev_bytes - off : WIPE_SPAN);
                wr = dev->write_fn(dev->ctx, zeroes, off, len);
            }
        } else {
            wr = dev->write_fn(dev->ctx, zeroes, 0, WIPE_SPAN);
            if (wr == 0)
                wr = dev->write_fn(dev->ctx, zeroes,
                                   dev_bytes - WIPE_SPAN, WIPE_SPAN);
        }
        free(zeroes);
        if (wr != 0)
            return EIO;
    }

    struct ext4_mkfs_info info;
    memset(&info, 0, sizeof(info));
    info.block_size     = block_size;
    info.inode_size     = opts->inode_size;
    info.inodes         = opts->inode_count;
    info.journal        = opts->journal;
    info.journal_blocks = opts->journal_blocks;
    info.label          = opts->label ? opts->label : "";
    memcpy(info.uuid, opts->uuid, sizeof(info.uuid));

    /*
     * ext4_mkfs() drives the block device itself -- it calls ext4_block_init(),
     * binds its own bcache, and tears both down again -- so it must be handed a
     * device that is not already open. That is exactly the state a freshly
     * created ext4b_device is in.
     */
    struct ext4_fs fs;
    memset(&fs, 0, sizeof(fs));

    int r = ext4_mkfs(&fs, &dev->bdev, &info, fs_type);
    if (r != EOK)
        return r;

    /* mkfs wrote through the cache it just destroyed; make sure the bytes have
     * actually reached the medium before we report success. */
    if (dev->flush_fn) {
        int fr = dev->flush_fn(dev->ctx);
        if (fr != 0)
            return fr;
    }
    return EOK;
}

/*
 * A free that ran past the end of the volume, refused by the allocator.
 *
 * The guard stops the damage -- crediting groups that do not exist, which
 * leaves a descriptor claiming more free blocks than its group holds -- but
 * the range is what identifies whatever produced it, and lwext4's own
 * debug output is compiled out of this build. So it comes here.
 */
void ext4b_report_bad_free(uint64_t first, uint32_t count, uint64_t blocks)
{
    bridge_logf(3, "refused a free of %u block(s) at %llu: the range ends at "
                   "%llu, past the end of a %llu-block volume. The accounting "
                   "is protected; the extent that produced this range is not "
                   "-- e2fsck is the fix [build %s]",
                count, (unsigned long long)first,
                (unsigned long long)(first + count - 1),
                (unsigned long long)blocks, EXT4B_BUILD_ID);
}

/*
 * lwext4's own diagnostics, for the two levels worth hearing.
 *
 * Called from the ext4_dbg macro when CONFIG_DEBUG_PRINTF is off, which is
 * every build here. Only "[warn]" and "[error]" are passed on: the rest is
 * per-block tracing that would bury the log and, in an appex, cost work to
 * produce for nobody.
 */
void ext4b_report_dbg(const char *fmt, ...)
{
    if (!fmt)
        return;
    if (strncmp(fmt, DBG_WARN, 6) != 0 && strncmp(fmt, DBG_ERROR, 7) != 0)
        return;

    char msg[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(msg, sizeof msg, fmt, ap);
    va_end(ap);

    /* These carry a trailing newline for printf; the logger adds its own. */
    size_t n = strlen(msg);
    while (n > 0 && (msg[n - 1] == '\n' || msg[n - 1] == '\r'))
        msg[--n] = '\0';

    /* bridge_logf already prefixes "core:"; adding another produced
     * "core: core: [warn]" in the field. */
    bridge_logf(3, "%s [build %s]", msg, EXT4B_BUILD_ID);
}

/* ================================================================ mount == */

/*
 * One group descriptor, read straight out of the descriptor table.
 *
 * Never through ext4_fs_get_block_group_ref: that call is not a read, because
 * referencing a group still flagged BLOCK_UNINIT makes it initialize the
 * bitmap, clear the flag and dirty the descriptor. Walking every group through
 * it would materialize the whole volume -- undoing the lazy format, and
 * failing outright on a read-only mount, which is how this was caught.
 *
 * The addressing is mirrored here for the ordinary layout only, lwext4 keeping
 * its own version static. META_BG scatters the table across the volume, so
 * rather than guess at an address this declines: a missing diagnostic beats a
 * confident wrong one.
 *
 * The descriptor is read field by field while its block is held rather than
 * copied out whole, because a descriptor is 32 or 64 bytes depending on the
 * volume and struct ext4_bgroup is the larger of the two -- copying blindly
 * would read past the end of the last descriptor in a block.
 */
static int bridge_read_group_info(struct ext4_fs *fs, uint32_t i,
                                  ext4b_group_info *out)
{
    if (ext4_sb_feature_incom(&fs->sb, EXT4_FINCOM_META_BG))
        return ENOTSUP;

    uint32_t bsize      = ext4_sb_get_block_size(&fs->sb);
    uint32_t dsc_size   = ext4_sb_get_desc_size(&fs->sb);
    uint32_t dsc_cnt    = bsize / dsc_size;
    uint32_t first_data = ext4_get32(&fs->sb, first_data_block);

    uint64_t block_id = first_data + (i / dsc_cnt) + 1;
    uint32_t offset   = (i % dsc_cnt) * dsc_size;
    struct ext4_block block;

    if (ext4_block_get(fs->bdev, &block, block_id) != EOK)
        return EIO;

    struct ext4_bgroup *bg = (struct ext4_bgroup *)(block.data + offset);
    out->index        = i;
    out->blocks       = ext4_blocks_in_group_cnt(&fs->sb, i);
    out->free_blocks  = ext4_bg_get_free_blocks_count(bg, &fs->sb);
    out->block_uninit = ext4_bg_has_flag(bg, EXT4_BLOCK_GROUP_BLOCK_UNINIT);
    out->inode_uninit = ext4_bg_has_flag(bg, EXT4_BLOCK_GROUP_INODE_UNINIT);

    if (ext4_block_set(fs->bdev, &block) != EOK)
        return EIO;
    return EOK;
}

int ext4b_free_blocks_raw(ext4b_device *dev,
                          uint64_t *free_blocks, uint64_t *total_blocks)
{
    if (!dev || !free_blocks || !total_blocks)
        return EINVAL;
    if (!dev->mounted || !dev->bdev.fs)
        return ENODEV;
    *free_blocks  = ext4_sb_get_free_blocks_cnt(&dev->bdev.fs->sb);
    *total_blocks = ext4_sb_get_blocks_cnt(&dev->bdev.fs->sb);
    return EOK;
}

int ext4b_group_count(ext4b_device *dev, uint32_t *out)
{
    if (!dev || !out)
        return EINVAL;
    if (!dev->mounted || !dev->bdev.fs)
        return ENODEV;
    if (ext4_sb_feature_incom(&dev->bdev.fs->sb, EXT4_FINCOM_META_BG))
        return ENOTSUP;
    *out = ext4_block_group_cnt(&dev->bdev.fs->sb);
    return EOK;
}

int ext4b_group_stats(ext4b_device *dev, uint32_t first,
                      ext4b_group_info *out, uint32_t max, uint32_t *filled)
{
    if (!dev || !out || !filled)
        return EINVAL;
    if (!dev->mounted || !dev->bdev.fs)
        return ENODEV;

    struct ext4_fs *fs = dev->bdev.fs;
    uint32_t groups = ext4_block_group_cnt(&fs->sb);
    uint32_t n = 0;

    *filled = 0;
    for (uint32_t i = first; i < groups && n < max; i++, n++) {
        int r = bridge_read_group_info(fs, i, &out[n]);
        if (r != EOK)
            return r;
    }
    *filled = n;
    return EOK;
}

/*
 * The superblock carries a cached total of free blocks; the group descriptors
 * carry the per-group counts the allocator actually works from. They are two
 * records of one fact, and only one of them can be trusted at a time.
 *
 * A stick in the field reported more free blocks than the volume has, and the
 * count climbed as files were copied. Six offline reproductions of that
 * workload -- including the same partial-last-group geometry, preallocation,
 * xattrs, tail trimming and delete/rewrite cycles -- all came back exact, so
 * the divergence has not been cornered yet. This prints, in one line at mount,
 * which of the two records is wrong, which is the fork the offline work could
 * not resolve: a bad cached sum is cosmetic until e2fsck, while bad descriptor
 * counts are what fragment allocation down to eight-block runs.
 */
static void bridge_audit_free_accounting(ext4b_device *dev, bool unreplayed)
{
    struct ext4_fs *fs = dev->bdev.fs;
    if (!fs)
        return;

    uint64_t sb_free = ext4_sb_get_free_blocks_cnt(&fs->sb);
    uint64_t total   = ext4_sb_get_blocks_cnt(&fs->sb);
    uint32_t groups  = ext4_block_group_cnt(&fs->sb);
    uint64_t sum     = 0;

    /*
     * Per group, not just in total. A descriptor claiming more free blocks
     * than its group holds is impossible on its own, and the sum hides it:
     * the field volume had three such groups while the descriptors still
     * summed to less than the volume size, so a test on the sum alone
     * reported the damage as confined to the cached total. That verdict says
     * allocation is healthy, which was exactly wrong -- the allocator was
     * scanning groups for free blocks that do not exist.
     */
    uint32_t bad_groups = 0;
    uint32_t first_bad  = 0;

    for (uint32_t i = 0; i < groups; i++) {
        ext4b_group_info g;
        if (bridge_read_group_info(fs, i, &g) != EOK)
            return;              /* META_BG or a read error is its own report */
        sum += g.free_blocks;
        if (g.free_blocks > g.blocks) {
            if (!bad_groups)
                first_bad = i;
            bad_groups++;
        }
    }

    if (sb_free == sum && sb_free <= total && !bad_groups) {
        bridge_logf(1, "free-space accounting agrees: %llu of %llu blocks "
                       "free across %u group(s)%s [build %s]",
                    (unsigned long long)sb_free,
                    (unsigned long long)total, groups,
                    unreplayed ? " (pre-recovery)" : "", EXT4B_BUILD_ID);
        return;
    }

    bridge_logf(3, "free-space accounting disagrees: the superblock says %llu "
                   "free, the %u group descriptors sum to %llu, and the volume "
                   "holds %llu blocks%s -- e2fsck is the fix",
                (unsigned long long)sb_free, groups,
                (unsigned long long)sum, (unsigned long long)total,
                (bad_groups || sum > total)
                    ? "; the descriptors themselves are impossible"
                    : (sb_free > total ? "; only the cached total is "
                                         "impossible" : ""));
    if (bad_groups)
        bridge_logf(3, "  %u group(s) claim more free blocks than they hold, "
                       "starting at group %u -- allocation is working from a "
                       "broken map, so expect short runs [build %s]",
                    bad_groups, first_bad, EXT4B_BUILD_ID);

    /*
     * Whether these numbers are the volume's committed state at all.
     *
     * A read-only mount does not replay, so the superblock read here is the
     * one the last crash left behind, and its cached total can be wildly
     * wrong while the journal holds the correct value a few blocks away.
     * A field volume reported 2,471,492 free of 1,920,357 this way; one
     * read-write mount replayed the log and the same volume read 1,750,596,
     * in agreement with its descriptors. Reporting that as corruption sent
     * an investigation after a number that recovery was about to correct.
     *
     * Per-group impossibility is not in that category: on the same volume
     * replay left all three bad descriptors exactly as they were. So the
     * caveat goes on the totals, and the group line above still stands.
     */
    if (unreplayed)
        bridge_logf(3, "  these are pre-recovery values: the journal is "
                       "unreplayed, so the cached total may simply be stale. "
                       "Mount read-write to replay, then re-read before "
                       "concluding anything from the totals [build %s]",
                    EXT4B_BUILD_ID);
    bridge_logf(3, "  (reported by build %s)", EXT4B_BUILD_ID);
}

int ext4b_mount(ext4b_device *dev, bool read_only)
{
    if (!dev)
        return EINVAL;
    if (dev->mounted)
        return EBUSY;

    /*
     * Safety gate. lwext4 lists RECOVER under EXT_FINCOM_IGNORED, so it will
     * cheerfully mount a filesystem with an unreplayed journal and then write
     * to it — which corrupts the volume. We therefore probe first and refuse
     * a read-write mount of a dirty volume unless recovery has been run.
     */
    ext4b_probe_info info;
    int r = ext4b_probe(dev, &info);
    if (r != EOK)
        return r;

    if (info.verdict == EXT4B_PROBE_NOT_EXT)
        return ENOTSUP;
    if (info.verdict == EXT4B_PROBE_UNSUPPORTED) {
        bridge_log(3, info.unsupported);
        return ENOTSUP;
    }
    if (info.verdict == EXT4B_PROBE_READ_ONLY && !read_only) {
        bridge_log(3, info.unsupported);
        return EROFS;
    }
    if (!read_only && dev->read_only)
        return EROFS;

    r = ext4_device_register(&dev->bdev, BRIDGE_DEV_NAME);
    if (r == EEXIST) {
        /*
         * DIAGNOSTIC. The device name is a single global slot, and lwext4
         * keeps the FIRST registrant: ext4_mount looks the device up by name
         * and binds s_bdevices[i].bd. So a mount that lands here is about to
         * be wired to a different volume's block device, while the
         * unwritten-extent fast path writes through &dev->bdev -- this
         * volume's own. Metadata to one medium, data to another.
         *
         * Whether that ever happens in the field is the open question this
         * line exists to answer; it is not yet known to occur.
         */
        bridge_logf(3, "device slot %s was already registered: this mount "
                       "binds another volume's block device [build %s]",
                    BRIDGE_DEV_NAME, EXT4B_BUILD_ID);
    }
    if (r != EOK && r != EEXIST)
        return r;

    r = ext4_mount(BRIDGE_DEV_NAME, BRIDGE_MOUNT_POINT, read_only);
    if (r != EOK) {
        ext4_device_unregister(BRIDGE_DEV_NAME);
        return r;
    }

    dev->mounted   = true;
    dev->read_only = read_only || dev->read_only;

    if (dev->read_only && info.needs_recovery) {
        /* No replay on a read-only mount, so no way to show the committed
         * state: every file predates the crash. Without this line, "the
         * files look old" is unattributable in the field.
         *
         * Level 3, which is the error channel. It was 2, and 2 is the level
         * for things worth having in a log somebody streams on purpose --
         * which nobody does while looking at a volume whose files look wrong.
         * The Swift logger routes >= 3 to os_log's error channel, and the
         * per-mount ring buffer keeps level-3 lines so they can be shown to
         * the person holding the stick rather than only to whoever thinks to
         * go looking. This is the one line that explains the symptom. */
        bridge_log(3, "read-only mount of an unreplayed journal: "
                      "contents predate the last crash");
    }

    if (!dev->read_only) {
        /*
         * Replay before touching anything. lwext4 lists RECOVER under
         * EXT_FINCOM_IGNORED, so ext4_mount() above will happily attach to a
         * volume with an unreplayed journal and let us write over it.
         */
        if (info.needs_recovery) {
            bridge_log(1, "replaying journal");
            uint64_t t0 = mono_ms();
            r = ext4_recover(BRIDGE_MOUNT_POINT);
            if (r != EOK) {
                bridge_logf(3, "journal recovery failed (errno %d) after "
                               "%llu ms; refusing read-write mount",
                            r, (unsigned long long)(mono_ms() - t0));
                ext4_umount(BRIDGE_MOUNT_POINT);
                ext4_device_unregister(BRIDGE_DEV_NAME);
                dev->mounted = false;
                return r;
            }
            struct ext4_fs *rfs = bridge_fs(dev);
            if (rfs && rfs->last_recovery.recovered)
                bridge_logf(1, "journal replayed: %u transaction(s), "
                               "%u block(s), log %u blocks, in %llu ms",
                            rfs->last_recovery.trans_replayed,
                            rfs->last_recovery.blocks_replayed,
                            rfs->last_recovery.log_blocks,
                            (unsigned long long)(mono_ms() - t0));
            else
                bridge_logf(1, "journal replayed in %llu ms",
                            (unsigned long long)(mono_ms() - t0));

            /*
             * And re-validate the superblock, because recovery can have
             * replaced it.
             *
             * jbd2 replays whatever the log says, by block number, and block
             * 1 of a 1 KiB volume is the superblock. Patch 0023 gave that
             * branch a writer; nothing gave it a reader that asks whether
             * what landed is still a filesystem. A log staging garbage for
             * block 1 -- which is four debugfs commands to produce -- left
             * the driver holding a superblock whose s_log_block_size was
             * 955747801, and the very next thing it did was shift by it:
             *
             *   ext4_super.h:95: runtime error: shift exponent 955747801 is
             *   too large for 32-bit type 'int'
             *
             * ext4b_probe reads the superblock from the medium and applies
             * every gate above, so calling it again is exactly the question
             * that needs asking. A volume that recovery has made unreadable
             * is not one to keep mounting: unwind and refuse, and say which
             * of the two states the user is in, because "it mounted before
             * the crash and not after" is otherwise unattributable.
             */
            ext4b_probe_info after;
            int pr = ext4b_probe(dev, &after);
            if (pr != EOK || after.verdict == EXT4B_PROBE_NOT_EXT ||
                after.verdict == EXT4B_PROBE_UNSUPPORTED) {
                bridge_logf(3, "journal replay left an unusable superblock "
                               "(%s); refusing the mount. The log replayed "
                               "over the superblock, which means the volume "
                               "needs e2fsck, not a retry",
                            pr != EOK ? "unreadable"
                                      : (after.unsupported[0] ? after.unsupported
                                                              : "not ext"));
                ext4_umount(BRIDGE_MOUNT_POINT);
                ext4_device_unregister(BRIDGE_DEV_NAME);
                dev->mounted = false;
                return EIO;
            }
            if (after.verdict == EXT4B_PROBE_READ_ONLY) {
                bridge_logf(3, "journal replay left a volume that can only be "
                               "read (%s); refusing the read-write mount",
                            after.unsupported);
                ext4_umount(BRIDGE_MOUNT_POINT);
                ext4_device_unregister(BRIDGE_DEV_NAME);
                dev->mounted = false;
                return EROFS;
            }
        }

        /*
         * Attach the journal. Without this fs->jbd_journal stays NULL, every
         * transaction we open is a silent no-op, and mutations land on the
         * medium unjournaled -- which a power cut then leaves torn with no way
         * to recover. Crash-consistency testing is what exposed this.
         */
        if (info.has_journal) {
            r = ext4_journal_start(BRIDGE_MOUNT_POINT);
            if (r != EOK) {
                bridge_logf(3, "could not start journal (errno %d); "
                               "refusing read-write mount", r);
                ext4_umount(BRIDGE_MOUNT_POINT);
                ext4_device_unregister(BRIDGE_DEV_NAME);
                dev->mounted = false;
                return r;
            }
            dev->journal_running = true;
        }

        /*
         * Finish anything the last session was in the middle of deleting.
         * After journal recovery, because the list itself is journaled state;
         * after the journal is running, because settling an entry means
         * freeing blocks and that has to be a transaction like any other.
         */
        uint32_t freed = 0, dropped = 0;
        uint64_t t0 = mono_ms();
        int orphan_r = dev->skip_orphan_cleanup
                     ? EOK
                     : ext4b_orphan_cleanup(dev, &freed, &dropped);
        if (orphan_r != EOK) {
            bridge_logf(3, "orphan-list cleanup failed (errno %d) after "
                           "reclaiming %u and dropping %u in %llu ms; the "
                           "volume is usable but some space may still be "
                           "unreclaimed",
                        orphan_r, freed, dropped,
                        (unsigned long long)(mono_ms() - t0));
        } else if (freed || dropped) {
            bridge_logf(1, "orphan list: reclaimed %u interrupted delete(s), "
                           "dropped %u stale entry/entries in %llu ms",
                        freed, dropped,
                        (unsigned long long)(mono_ms() - t0));
        }
    }

    bridge_audit_free_accounting(dev, dev->read_only && info.needs_recovery);
    return EOK;
}

int ext4b_unmount(ext4b_device *dev)
{
    if (!dev || !dev->mounted)
        return EINVAL;

    /* Teardown always runs to the end -- a device left half-registered is
     * worse than any single failed step -- but the FIRST failure is the one
     * reported. Four layers each dropped their own error here, and a stick
     * that failed its final write-back ejected "clean". */
    int r = EOK;
    int step;

    /* Before the transaction drain, so the trims it issues go into the same
     * journal as everything else. Blocks allocated ahead of a write are an
     * optimisation between one write and the next; nothing may outlive the
     * mount that took them, or the volume ejects holding space no file uses
     * and only e2fsck can explain it. */
    if (!dev->read_only) {
        struct ext4_fs *fs = bridge_fs(dev);
        if (fs) {
            step = resv_drain(dev, fs);
            if (r == EOK)
                r = step;
        }
    }

    /* Before the journal stops. A transaction still open here is a set of
     * mutations the caller was told had succeeded, and stopping the journal
     * underneath it discards them. */
    step = txn_drain(dev);
    if (r == EOK)
        r = step;

    if (dev->journal_running) {
        step = ext4_journal_stop(BRIDGE_MOUNT_POINT);
        if (r == EOK)
            r = step;
        dev->journal_running = false;
    }

    step = ext4_umount(BRIDGE_MOUNT_POINT);
    if (r == EOK)
        r = step;
    ext4_device_unregister(BRIDGE_DEV_NAME);
    dev->mounted = false;

    if (dev->flush_fn) {
        step = dev->flush_fn(dev->ctx) == 0 ? EOK : EIO;
        if (r == EOK)
            r = step;
    }
    return r;
}

int ext4b_journal_recover(ext4b_device *dev)
{
    if (!dev)
        return EINVAL;
    if (dev->read_only)
        return EROFS;

    /* DiskArbitration's pre-mount check lands here on a device nothing has
     * mounted yet, and lwext4's replay machinery only exists inside a
     * mounted context -- the old EINVAL made the whole check fail, and
     * DiskArbitration answered a failed check by mounting read-only with
     * the journal unreplayed. Every post-crash plug-in served pre-crash
     * contents. Recovery on an unmounted device is a mount and a clean
     * unmount: the mount replays and settles orphans, the unmount
     * checkpoints, and both already report every failure honestly. */
    if (!dev->mounted) {
        int r = ext4b_mount(dev, false);
        if (r != EOK)
            return r;
        return ext4b_unmount(dev);
    }

    int r = ext4_recover(BRIDGE_MOUNT_POINT);
    if (r == EOK && dev->flush_fn)
        /* The claim "replayed the journal" is the claim that the replay is
         * on the medium; a discarded flush made fsck report it anyway. */
        r = dev->flush_fn(dev->ctx) == 0 ? EOK : EIO;
    return r;
}

int ext4b_sync(ext4b_device *dev)
{
    if (!dev || !dev->mounted)
        return EINVAL;

    /* Batched mutations are not on the medium until their transaction
     * commits, and this is the call that promises they are. */
    int dr = txn_drain(dev);
    if (dr != EOK)
        return dr;

    int r = ext4_cache_flush(BRIDGE_MOUNT_POINT);
    if (r != EOK)
        return r;
    if (dev->flush_fn)
        return dev->flush_fn(dev->ctx);
    return EOK;
}

int ext4b_set_label(ext4b_device *dev, const char *label)
{
    if (!dev || !dev->mounted || !label)
        return EINVAL;
    if (dev->read_only)
        return EROFS;

    struct ext4_sblock *sb = NULL;
    int r = ext4_get_sblock(BRIDGE_MOUNT_POINT, &sb);
    if (r != EOK)
        return r;

    size_t len = strlen(label);
    if (len > sizeof(sb->volume_name))
        return ENAMETOOLONG;

    /* Fixed-width and zero-padded: a 16-byte name has no terminator, so the
     * field is cleared first rather than strncpy'd into. */
    memset(sb->volume_name, 0, sizeof(sb->volume_name));
    memcpy(sb->volume_name, label, len);

    /* Write it through now instead of waiting for unmount to flush the
     * superblock: a rename the user can see in Finder but that vanishes on
     * power loss is worse than one that fails outright. */
    r = ext4_sb_write(&dev->bdev, sb);
    if (r != EOK)
        return r;

    if (dev->flush_fn)
        return dev->flush_fn(dev->ctx);
    return EOK;
}

int ext4b_statfs(ext4b_device *dev, ext4b_statfs_info *out)
{
    if (!dev || !dev->mounted || !out)
        return EINVAL;

    struct ext4_mount_stats st;
    int r = ext4_mount_point_stats(BRIDGE_MOUNT_POINT, &st);
    if (r != EOK)
        return r;

    out->block_size   = st.block_size;
    out->total_blocks = st.blocks_count;
    out->free_blocks  = st.free_blocks_count;
    out->total_inodes = st.inodes_count;
    out->free_inodes  = st.free_inodes_count;

    /*
     * A volume can claim more free blocks than it has. Measured on a real
     * stick: 2,045,724 free against 1,920,357 total, which df renders as
     * "negative filesystem block count" and Disk Utility as 106.5% free.
     * The superblock's counters are ordinary metadata and drift like any
     * other -- an interrupted format, an unclean history, a bad sector under
     * the group descriptors.
     *
     * Two things follow. The number is clamped, because passing an
     * impossible one up produces nonsense in every tool that asks and
     * teaches the user to distrust all of them. And it is said out loud
     * once, because the same broken free-space picture is what the block
     * allocator works from: on that stick it handed out four-block runs
     * where a healthy volume gives two hundred and forty, and a copy that
     * should stream ran at 3.9 MB/s. Silent bad numbers are how a corrupt
     * volume passes for a slow driver.
     */
    if (out->free_blocks > out->total_blocks) {
        /*
         * Reported once per mount and then again whenever the count climbs
         * another 4096 blocks. The one-shot version cost a diagnosis: it
         * caught the first crossing at 1,922,214 and stayed silent while the
         * count grew to 2,320,442, hiding the fact that the number *drifts
         * upward as the volume is written* rather than arriving broken.
         */
        if (!dev->warned_free_blocks ||
            out->free_blocks > dev->warned_free_at + 4096) {
            bridge_logf(3, "free block count (%llu) exceeds the volume size "
                           "(%llu blocks) by %llu%s: the superblock's "
                           "accounting is corrupt, allocation will be poor, "
                           "and e2fsck is the fix [build %s]",
                        (unsigned long long)out->free_blocks,
                        (unsigned long long)out->total_blocks,
                        (unsigned long long)(out->free_blocks -
                                             out->total_blocks),
                        dev->warned_free_blocks ? " (still growing)" : "",
                        EXT4B_BUILD_ID);
            dev->warned_free_blocks = true;
            dev->warned_free_at = out->free_blocks;
        }
        out->free_blocks = out->total_blocks;
    }
    if (out->free_inodes > out->total_inodes)
        out->free_inodes = out->total_inodes;

    /*
     * Available != free. s_r_blocks_count is set aside for root so a full
     * volume stays usable by privileged processes; unprivileged callers see
     * it as unavailable, and df/Finder show it as used. Reporting free as
     * available overstates space by (default) 5%. The mount-stats struct does
     * not carry the reserve, so read it from the superblock directly.
     */
    struct ext4_fs *fs = dev->bdev.fs;   /* bridge_fs is defined below */
    uint64_t reserved = 0;
    if (fs) {
        reserved = to_le32(fs->sb.reserved_blocks_count_lo);
        if (to_le32(fs->sb.features_incompatible) & EXT4_FINCOM_64BIT)
            reserved |= (uint64_t)to_le32(fs->sb.reserved_blocks_count_hi) << 32;
    }
    /*
     * Derived from the clamped free count, not from st.free_blocks_count.
     * Clamping only free left available holding the raw value, so df kept
     * printing "Avail 8.9Gi" against a "Size 7.3Gi" volume -- the clamp
     * looked ineffective because the number df shows never went through it.
     */
    out->avail_blocks = (out->free_blocks > reserved)
                      ? out->free_blocks - reserved
                      : 0;
    return EOK;
}

/* ================================================================ inode == */

static struct ext4_fs *bridge_fs(ext4b_device *dev)
{
    return dev->bdev.fs;
}

static ext4b_item_type type_from_mode(uint32_t mode)
{
    switch (mode & EXT4_INODE_MODE_TYPE_MASK) {
    case EXT4_INODE_MODE_FILE:      return EXT4B_TYPE_FILE;
    case EXT4_INODE_MODE_DIRECTORY: return EXT4B_TYPE_DIR;
    case EXT4_INODE_MODE_SOFTLINK:  return EXT4B_TYPE_SYMLINK;
    case EXT4_INODE_MODE_FIFO:      return EXT4B_TYPE_FIFO;
    case EXT4_INODE_MODE_CHARDEV:   return EXT4B_TYPE_CHARDEV;
    case EXT4_INODE_MODE_BLOCKDEV:  return EXT4B_TYPE_BLOCKDEV;
    case EXT4_INODE_MODE_SOCKET:    return EXT4B_TYPE_SOCKET;
    default:                        return EXT4B_TYPE_UNKNOWN;
    }
}

/* The *_extra fields pack nanoseconds in the upper 30 bits. */
static uint32_t nsec_from_extra(uint32_t extra)
{
    return extra >> 2;
}

int ext4b_getattr(ext4b_device *dev, uint32_t inode, ext4b_attrs *out)
{
    if (!dev || !dev->mounted || !out || inode == 0)
        return EINVAL;

    struct ext4_fs *fs = bridge_fs(dev);
    if (!fs)
        return EINVAL;

    struct ext4_inode_ref ref;
    int r = ext4_fs_get_inode_ref(fs, inode, &ref);
    if (r != EOK)
        return r;

    struct ext4_sblock *sb = &fs->sb;
    memset(out, 0, sizeof(*out));

    uint32_t mode = ext4_inode_get_mode(sb, ref.inode);
    out->inode       = inode;
    out->type        = type_from_mode(mode);
    out->mode        = mode & 0x0FFF;
    out->uid         = ext4_inode_get_uid(ref.inode);
    out->gid         = ext4_inode_get_gid(ref.inode);
    out->link_count  = ext4_inode_get_links_cnt(ref.inode);
    out->size        = ext4_inode_get_size(sb, ref.inode);
    out->flags       = ext4_inode_get_flags(ref.inode);
    out->uses_extents = ext4_inode_has_flag(ref.inode, EXT4_INODE_FLAG_EXTENTS);
    out->inline_data  = (out->flags & 0x10000000) != 0;  /* EXT4_INODE_FLAG_INLINE_DATA */

    /* blocks_count is expressed in 512-byte units regardless of block size. */
    out->alloc_size = ext4_inode_get_blocks_count(sb, ref.inode) * 512ull;

    out->atime = (int64_t)ext4_inode_get_access_time(ref.inode);
    out->mtime = (int64_t)ext4_inode_get_modif_time(ref.inode);
    out->ctime = (int64_t)ext4_inode_get_change_inode_time(ref.inode);

    /* Creation time and sub-second precision only exist on inodes large
     * enough to carry the extra fields. */
    uint16_t extra_isize = ext4_inode_get_extra_isize(sb, ref.inode);
    if (extra_isize >= 24) {
        out->crtime    = (int64_t)to_le32(ref.inode->crtime);
        out->crtime_ns = nsec_from_extra(to_le32(ref.inode->crtime_extra));
        out->atime_ns  = nsec_from_extra(to_le32(ref.inode->atime_extra));
        out->mtime_ns  = nsec_from_extra(to_le32(ref.inode->mtime_extra));
        out->ctime_ns  = nsec_from_extra(to_le32(ref.inode->ctime_extra));
    } else {
        out->crtime = out->mtime;   /* best available approximation */
    }

    ext4_fs_put_inode_ref(&ref);
    return EOK;
}

/* ============================================================ directory == */

static ext4b_item_type type_from_dirent(uint8_t ftype)
{
    switch (ftype) {
    case 1:  return EXT4B_TYPE_FILE;
    case 2:  return EXT4B_TYPE_DIR;
    case 3:  return EXT4B_TYPE_CHARDEV;
    case 4:  return EXT4B_TYPE_BLOCKDEV;
    case 5:  return EXT4B_TYPE_FIFO;
    case 6:  return EXT4B_TYPE_SOCKET;
    case 7:  return EXT4B_TYPE_SYMLINK;
    default: return EXT4B_TYPE_UNKNOWN;
    }
}

int ext4b_lookup(ext4b_device *dev,
                 uint32_t dir_inode,
                 const char *name, size_t name_len,
                 uint32_t *out_inode,
                 ext4b_item_type *out_type)
{
    if (!dev || !dev->mounted || !name || !out_inode)
        return EINVAL;
    if (name_len == 0 || name_len > 255)
        return ENAMETOOLONG;

    struct ext4_fs *fs = bridge_fs(dev);
    if (!fs)
        return EINVAL;

    struct ext4_inode_ref parent;
    int r = ext4_fs_get_inode_ref(fs, dir_inode, &parent);
    if (r != EOK)
        return r;

    if (!ext4_inode_is_type(&fs->sb, parent.inode, EXT4_INODE_MODE_DIRECTORY)) {
        ext4_fs_put_inode_ref(&parent);
        return ENOTDIR;
    }

    struct ext4_dir_search_result result;
    r = ext4_dir_find_entry(&result, &parent, name, (uint32_t)name_len);
    if (r != EOK) {
        ext4_fs_put_inode_ref(&parent);
        return r == ENOENT ? ENOENT : r;
    }

    *out_inode = ext4_dir_en_get_inode(result.dentry);
    if (out_type) {
        uint8_t ftype = ext4_dir_en_get_inode_type(&fs->sb, result.dentry);
        *out_type = type_from_dirent(ftype);
    }

    ext4_dir_destroy_result(&parent, &result);
    ext4_fs_put_inode_ref(&parent);
    return EOK;
}

int ext4b_readdir(ext4b_device *dev,
                  uint32_t dir_inode,
                  uint64_t cookie,
                  ext4b_dirent_fn cb,
                  void *cb_ctx)
{
    if (!dev || !dev->mounted || !cb)
        return EINVAL;

    struct ext4_fs *fs = bridge_fs(dev);
    if (!fs)
        return EINVAL;

    struct ext4_inode_ref dir;
    int r = ext4_fs_get_inode_ref(fs, dir_inode, &dir);
    if (r != EOK)
        return r;

    if (!ext4_inode_is_type(&fs->sb, dir.inode, EXT4_INODE_MODE_DIRECTORY)) {
        ext4_fs_put_inode_ref(&dir);
        return ENOTDIR;
    }

    struct ext4_dir_iter it;
    r = ext4_dir_iterator_init(&it, &dir, cookie);
    if (r != EOK) {
        ext4_fs_put_inode_ref(&dir);
        return r;
    }

    while (it.curr != NULL) {
        uint32_t ino = ext4_dir_en_get_inode(it.curr);

        /* inode 0 marks a deleted slot that still occupies directory space. */
        if (ino == 0) {
            r = ext4_dir_iterator_next(&it);
            if (r != EOK)
                break;
            continue;
        }

        uint16_t nlen  = ext4_dir_en_get_name_len(&fs->sb, it.curr);
        uint8_t  ftype = ext4_dir_en_get_inode_type(&fs->sb, it.curr);
        /*
         * ext4 names are at most EXT4_NAME_LEN (255). A longer one is a
         * corrupt or hostile directory entry; the old code clamped it to 255
         * and handed FSKit a *different* name than what is on disk, which is
         * how a lookup of that name then fails. Skip it instead of inventing
         * a name -- truncatesLongNames is false, and that promise applies to
         * reads too.
         */
        if (nlen > 255) {
            r = ext4_dir_iterator_next(&it);
            if (r != EOK)
                break;
            continue;
        }

        /* Copy the name out before advancing: stepping the iterator may
         * release the underlying block and invalidate it.curr. */
        char namebuf[256];
        memcpy(namebuf, it.curr->name, nlen);
        namebuf[nlen] = '\0';

        /* Advance first, so the cookie handed to the callback resumes *after*
         * this entry — matching FSKit's packEntry(nextCookie:) contract. */
        r = ext4_dir_iterator_next(&it);
        if (r != EOK)
            break;

        if (!cb(cb_ctx, namebuf, nlen, ino,
                type_from_dirent(ftype), it.curr_off))
            break;
    }

    ext4_dir_iterator_fini(&it);
    ext4_fs_put_inode_ref(&dir);
    return r;
}

/* ================================================================= data == */

int ext4b_read(ext4b_device *dev,
               uint32_t inode,
               uint64_t offset,
               void *buf,
               size_t count,
               size_t *out_read)
{
    if (!dev || !dev->mounted || !buf || !out_read)
        return EINVAL;

    *out_read = 0;
    if (count == 0)
        return EOK;

    struct ext4_fs *fs = bridge_fs(dev);
    if (!fs)
        return EINVAL;

    struct ext4_inode_ref ref;
    int r = ext4_fs_get_inode_ref(fs, inode, &ref);
    if (r != EOK)
        return r;

    uint64_t size = ext4_inode_get_size(&fs->sb, ref.inode);
    if (offset >= size) {
        ext4_fs_put_inode_ref(&ref);
        return EOK;             /* reading past EOF is not an error */
    }
    if (offset + count > size)
        count = (size_t)(size - offset);

    uint32_t bsize = ext4_sb_get_block_size(&fs->sb);
    uint8_t *dst = buf;
    size_t remaining = count;

    /*
     * Whole contiguous blocks are read with one device command per run, for
     * the reason the write path above coalesces: this loop issued one read
     * per block -- 25,606 of them for a 100 MB file -- and a USB stick
     * charges a round trip for each.
     *
     * A run is read straight into the caller's buffer rather than through
     * the block cache, which is both faster and more correct here. File data
     * is written directly to the medium (ext4_block_writebytes), and nothing
     * invalidates a cached copy when that happens, so a block read once and
     * still resident could answer a later read with pre-write contents. The
     * medium is the truth for data blocks; the one thing that outranks it is
     * a buffer still holding unwritten changes, so any DIRTY resident is
     * copied over the run afterwards. Partial head and tail blocks keep the
     * cached path, where a read-modify-write wants the buffer anyway.
     */
    while (remaining > 0) {
        uint32_t lblk = (uint32_t)((offset) / bsize);
        uint32_t in_blk_off = (uint32_t)(offset % bsize);
        uint32_t chunk = bsize - in_blk_off;
        if (chunk > remaining)
            chunk = (uint32_t)remaining;

        ext4_fsblk_t fblk = 0;
        r = ext4_fs_get_inode_dblk_idx(&ref, lblk, &fblk, true);
        if (r != EOK)
            break;

        if (in_blk_off == 0 && chunk == bsize && fblk != 0) {
            /* Extend the run as far as the mapping stays contiguous. */
            uint32_t run = 1;
            while ((size_t)(run + 1) * bsize <= remaining) {
                ext4_fsblk_t next = 0;
                if (ext4_fs_get_inode_dblk_idx(&ref, lblk + run, &next,
                                               true) != EOK)
                    break;
                if (next != fblk + run)
                    break;
                run++;
            }

            r = ext4_blocks_get_direct(&dev->bdev, dst, fblk, run);
            if (r != EOK)
                break;

            for (uint32_t i = 0; i < run; i++) {
                struct ext4_block cached;
                struct ext4_buf *cbuf =
                    ext4_bcache_find_get(dev->bdev.bc, &cached, fblk + i);
                if (cbuf) {
                    if (ext4_bcache_test_flag(cbuf, BC_DIRTY))
                        memcpy(dst + (size_t)i * bsize, cbuf->data, bsize);
                    ext4_block_set(&dev->bdev, &cached);
                }
            }

            chunk = run * bsize;
        } else if (fblk == 0) {
            /* Sparse hole — reads as zeroes. */
            memset(dst, 0, chunk);
        } else {
            struct ext4_block b;
            r = ext4_block_get(&dev->bdev, &b, fblk);
            if (r != EOK)
                break;
            memcpy(dst, b.data + in_blk_off, chunk);
            ext4_block_set(&dev->bdev, &b);
        }

        dst       += chunk;
        offset    += chunk;
        remaining -= chunk;
        *out_read += chunk;
    }

    ext4_fs_put_inode_ref(&ref);
    /* count was clamped to EOF above, so a loop that stopped short stopped on
     * an error -- and a short count with rc 0 is indistinguishable from EOF
     * to the caller. `cp` off a failing stick was producing silently
     * truncated files this way. *out_read still says how far we got. */
    return r;
}

int ext4b_readlink(ext4b_device *dev,
                   uint32_t inode,
                   char *buf, size_t buf_size,
                   size_t *out_len)
{
    if (!dev || !dev->mounted || !buf || !out_len || buf_size == 0)
        return EINVAL;

    struct ext4_fs *fs = bridge_fs(dev);
    if (!fs)
        return EINVAL;

    struct ext4_inode_ref ref;
    int r = ext4_fs_get_inode_ref(fs, inode, &ref);
    if (r != EOK)
        return r;

    if (!ext4_inode_is_type(&fs->sb, ref.inode, EXT4_INODE_MODE_SOFTLINK)) {
        ext4_fs_put_inode_ref(&ref);
        return EINVAL;
    }

    uint64_t size = ext4_inode_get_size(&fs->sb, ref.inode);
    if (size >= buf_size) {
        ext4_fs_put_inode_ref(&ref);
        return ENAMETOOLONG;
    }

    /* Targets shorter than 60 bytes live inline in the block pointer array;
     * longer ones occupy a data block. */
    if (size < sizeof(ref.inode->blocks)) {
        memcpy(buf, ref.inode->blocks, (size_t)size);
        buf[size] = '\0';
        *out_len = (size_t)size;
        ext4_fs_put_inode_ref(&ref);
        return EOK;
    }

    ext4_fs_put_inode_ref(&ref);

    size_t got = 0;
    r = ext4b_read(dev, inode, 0, buf, (size_t)size, &got);
    if (r != EOK)
        return r;
    buf[got] = '\0';
    *out_len = got;
    return EOK;
}

/* ============================================================== extents == */

int ext4b_map_extents(ext4b_device *dev,
                      uint32_t inode,
                      uint64_t offset,
                      uint64_t length,
                      ext4b_extent *out,
                      size_t max_extents,
                      size_t *out_count)
{
    if (!dev || !dev->mounted || !out || !out_count || max_extents == 0)
        return EINVAL;

    *out_count = 0;
    if (length == 0)
        return EOK;

    struct ext4_fs *fs = bridge_fs(dev);
    if (!fs)
        return EINVAL;

    struct ext4_inode_ref ref;
    int r = ext4_fs_get_inode_ref(fs, inode, &ref);
    if (r != EOK)
        return r;

    uint32_t bsize = ext4_sb_get_block_size(&fs->sb);
    uint64_t fsize = ext4_inode_get_size(&fs->sb, ref.inode);

    size_t n = 0;

#if CONFIG_EXTENT_ENABLE && CONFIG_EXTENTS_ENABLE
    /* Extent-mapped inodes get the accurate answer: the probe can tell an
     * unwritten extent from a hole -- the mapping API folds both into 0 --
     * and is not clamped to i_size, so preallocated blocks past EOF are
     * visible. That is not cosmetic: it is how the tests see them. */
    if (ext4_inode_has_flag(ref.inode, EXT4_INODE_FLAG_EXTENTS)) {
        uint32_t lblk     = (uint32_t)(offset / bsize);
        uint32_t end_lblk = (uint32_t)((offset + length - 1) / bsize);
        while (lblk <= end_lblk && n < max_extents) {
            ext4_fsblk_t fblk = 0;
            uint32_t run = 0;
            bool unwr = false;
            r = ext4_extent_probe(&ref, lblk, &fblk, &run, &unwr);
            if (r != EOK)
                break;
            if (fblk == 0 && run == 0)
                break;                     /* the gap runs to EOF */
            if (run > end_lblk - lblk + 1)
                run = end_lblk - lblk + 1;
            out[n].logical_offset  = (uint64_t)lblk * bsize;
            out[n].physical_offset = (uint64_t)fblk * bsize;
            out[n].length          = (uint64_t)run * bsize;
            out[n].is_hole         = (fblk == 0);
            out[n].is_unwritten    = unwr;
            n++;
            lblk += run;
        }
        *out_count = n;
        ext4_fs_put_inode_ref(&ref);
        /* Both normal exits (gap to EOF, out[] full) leave r == EOK; a
         * nonzero r is a probe that failed mid-file, and a silently
         * truncated map is a wrong map. */
        return r;
    }
#endif

    if (offset >= fsize) {
        ext4_fs_put_inode_ref(&ref);
        return EOK;
    }
    if (offset + length > fsize)
        length = fsize - offset;

    uint32_t lblk     = (uint32_t)(offset / bsize);
    uint32_t end_lblk = (uint32_t)((offset + length - 1) / bsize);

    while (lblk <= end_lblk && n < max_extents) {
        ext4_fsblk_t fblk = 0;
        r = ext4_fs_get_inode_dblk_idx(&ref, lblk, &fblk, true);
        if (r != EOK)
            break;

        /* Coalesce the longest physically contiguous run starting here. */
        uint32_t run = 1;
        while (lblk + run <= end_lblk) {
            ext4_fsblk_t next = 0;
            if (ext4_fs_get_inode_dblk_idx(&ref, lblk + run, &next, true) != EOK)
                break;
            bool contiguous = (fblk == 0) ? (next == 0) : (next == fblk + run);
            if (!contiguous)
                break;
            run++;
        }

        out[n].logical_offset  = (uint64_t)lblk * bsize;
        out[n].physical_offset = (uint64_t)fblk * bsize;
        out[n].length          = (uint64_t)run * bsize;
        out[n].is_hole         = (fblk == 0);
        out[n].is_unwritten    = false;    /* indirect files have no such state */
        n++;

        lblk += run;
    }

    *out_count = n;
    ext4_fs_put_inode_ref(&ref);
    /* Same contract as the extent path above: nonzero r means the map
     * stopped on an error, not at EOF. */
    return r;
}

/* ------------------------------------------------------- xattr namespaces -- */
/*
 * ext4 stores an attribute as (namespace index, suffix): "user.colour" is
 * index 1 plus "colour". macOS attribute names carry no such namespace --
 * Finder and the kernel set names like com.apple.provenance,
 * com.apple.FinderInfo and com.apple.quarantine directly.
 *
 * Names that already carry an ext4 namespace pass through untouched, so a
 * volume shared with Linux keeps its user and security semantics. Anything
 * else is filed under the user namespace with its full name preserved, which
 * is what lets macOS metadata round-trip; on Linux it shows up as
 * "user.com.apple.provenance".
 */
#define EXT4B_XATTR_INDEX_USER 1

static const char *xattr_split(const char *name, uint8_t *index, size_t *len)
{
    bool found = false;
    size_t sub_len = 0;
    const char *sub =
        ext4_extract_xattr_name(name, strlen(name), index, &sub_len, &found);
    if (found) {
        *len = sub_len;
        return sub;
    }
    *index = EXT4B_XATTR_INDEX_USER;
    *len = strlen(name);
    return name;
}

/* ================================================================ xattr == */

int ext4b_listxattr(ext4b_device *dev, uint32_t inode,
                    ext4b_xattr_fn cb, void *cb_ctx)
{
    if (!dev || !dev->mounted || !cb)
        return EINVAL;

    struct ext4_fs *fs = bridge_fs(dev);
    if (!fs)
        return EINVAL;

    struct ext4_inode_ref ref;
    int r = ext4_fs_get_inode_ref(fs, inode, &ref);
    if (r != EOK)
        return r;

    size_t list_len = 0;
    r = ext4_xattr_list(&ref, NULL, &list_len);
    if (r != EOK || list_len == 0) {
        ext4_fs_put_inode_ref(&ref);
        return r;
    }

    struct ext4_xattr_list_entry *list = calloc(1, list_len);
    if (!list) {
        ext4_fs_put_inode_ref(&ref);
        return ENOMEM;
    }

    r = ext4_xattr_list(&ref, list, &list_len);
    if (r == EOK) {
        for (struct ext4_xattr_list_entry *e = list; e != NULL; e = e->next) {
            size_t plen = 0;
            const char *prefix = ext4_get_xattr_name_prefix(e->name_index, &plen);
            char full[256];
            if (plen + e->name_len >= sizeof(full))
                continue;
            if (plen && prefix)
                memcpy(full, prefix, plen);
            memcpy(full + plen, e->name, e->name_len);
            full[plen + e->name_len] = '\0';
            if (!cb(cb_ctx, full, plen + e->name_len))
                break;
        }
    }

    free(list);
    ext4_fs_put_inode_ref(&ref);
    return r;
}

/*
 * "This attribute is not set" has two names, and the platforms disagree.
 *
 * lwext4 speaks Linux and returns ENODATA, which is what Linux's getxattr(2)
 * documents. macOS documents ENOATTR for the same condition, and its value is
 * different -- 93 against 96. Handing ENODATA to a macOS caller is not a
 * near-miss: getxattr(2) never returns it, so callers that switch on the
 * errno fall through to their error path. Finder does exactly that, and
 * refuses to copy a file whose com.apple.FinderInfo it cannot resolve.
 *
 * Translated here rather than in lwext4, because lwext4 is right about Linux.
 */
static int xattr_errno(int rc)
{
    /*
     * ENOATTR is macOS's name; Linux calls the same condition ENODATA and has
     * no ENOATTR at all. The shim's callers on macOS need ENOATTR -- Finder
     * stops copying a file without it -- so the mapping stays, and on Linux
     * the answer is already the right one.
     */
#ifdef ENOATTR
    return rc == ENODATA ? ENOATTR : rc;
#else
    return rc;
#endif
}

int ext4b_getxattr(ext4b_device *dev, uint32_t inode,
                   const char *name,
                   void *buf, size_t buf_size, size_t *out_len)
{
    if (!dev || !dev->mounted || !name || !out_len)
        return EINVAL;

    struct ext4_fs *fs = bridge_fs(dev);
    if (!fs)
        return EINVAL;

    struct ext4_inode_ref ref;
    int r = ext4_fs_get_inode_ref(fs, inode, &ref);
    if (r != EOK)
        return r;

    uint8_t name_index = 0;
    size_t  name_len   = 0;
    const char *short_name = xattr_split(name, &name_index, &name_len);

    r = ext4_xattr_get(&ref, name_index, short_name, name_len,
                       buf, buf_size, out_len);
    ext4_fs_put_inode_ref(&ref);
    return xattr_errno(r);
}

/* ============================================================== writing == */

#include <ext4_balloc.h>
#include <ext4_ialloc.h>
#include <ext4_bitmap.h>
#include <ext4_block_group.h>
#include <ext4_journal.h>
#include <ext4_dir_idx.h>
#include <ext4_trans.h>
#include <time.h>

bool ext4b_is_writable(ext4b_device *dev)
{
    return dev && dev->mounted && !dev->read_only;
}

/* --------------------------------------------------------- transactions -- */
/*
 * Mirrors lwext4's own __ext4_trans_start/stop/abort, which are static inside
 * ext4.c. We reach the same state through fs->jbd_journal / fs->curr_trans.
 */

static int txn_begin(struct ext4_fs *fs)
{
#if CONFIG_JOURNALING_ENABLE
    if (fs->jbd_journal && !fs->curr_trans) {
        struct jbd_trans *trans = jbd_journal_new_trans(fs->jbd_journal);
        if (!trans)
            return ENOMEM;
        fs->curr_trans = trans;
        atomic_store(&g_txn_owner, (uintptr_t)pthread_self());
    } else if (fs->jbd_journal) {
        /* A transaction was already open, which is the normal case under
         * batching: one transaction spans many operations before it commits.
         *
         * The owner-thread identity is NOT a concurrency signal here. The
         * executor serialises every core call onto one serial queue, but GCD
         * runs those strictly-sequential blocks on whichever pooled thread is
         * free, so a later op in the same batch legitimately runs on a
         * different thread than the one that opened the transaction. Comparing
         * pthread_self() against the batch's opener therefore fires on every
         * serial hand-off -- a false positive that says nothing about real
         * concurrency.
         *
         * Real concurrent entry -- two threads genuinely inside lwext4 at once
         * -- is caught by io_enter/io_leave around the block callbacks, which
         * every operation drives and which clear on leave. So here we simply
         * take ownership of the ongoing batch; the serial queue guarantees the
         * previous op has already returned. */
        atomic_store(&g_txn_owner, (uintptr_t)pthread_self());
    }
#endif
    return EOK;
}

static int txn_commit(struct ext4_fs *fs)
{
#if CONFIG_JOURNALING_ENABLE
    if (fs->jbd_journal && fs->curr_trans) {
        int r = jbd_journal_commit_trans(fs->jbd_journal, fs->curr_trans);
        fs->curr_trans = NULL;
        atomic_store(&g_txn_owner, 0);
        return r;
    }
#endif
    return EOK;
}

static void txn_abort(struct ext4_fs *fs)
{
#if CONFIG_JOURNALING_ENABLE
    if (fs->jbd_journal && fs->curr_trans) {
        jbd_journal_free_trans(fs->jbd_journal, fs->curr_trans, true);
        fs->curr_trans = NULL;
        atomic_store(&g_txn_owner, 0);
    }
#endif
}

/* BRIDGE_TXN_BATCH: how many mutations may share one journal transaction.
 *
 * One was the old behaviour and it is enormously expensive. Every transaction
 * pays two write barriers -- jbd issues one either side of the commit block --
 * and a barrier is an XPC round trip to the privileged helper plus a real
 * DKIOCSYNCHRONIZE on the drive. Creating four hundred small files spent
 * fourteen seconds almost entirely on that: 36 ms per file, of which the
 * filesystem work is a rounding error.
 *
 * Linux ext4 does not work this way and never has. A transaction stays open,
 * accumulates hundreds of operations, and commits every few seconds or when
 * something asks; the barriers are paid once for the batch rather than once
 * per operation.
 *
 * Sixteen is deliberately modest. The bound that matters is journal space --
 * an over-large transaction cannot be committed at all -- and sixteen
 * operations touching a few dozen blocks each sits far inside the smallest
 * journal mkfs will create. */

/* Is the open transaction full?
 *
 * The operation count is the cheap bound and it is not the real one. lwext4's
 * jbd has no notion of a transaction being too large for the journal: it
 * allocates journal blocks from a ring as the transaction commits, and when the
 * ring runs out it purges one checkpointed transaction and carries on. With a
 * transaction big enough, that wraps into blocks the same transaction is still
 * using, and recovery then replays a log that overwrote itself. Linux avoids
 * this by reserving credits per handle up front; there is nothing equivalent
 * here.
 *
 * It is journal *size* that decides, not operation count, which is why this was
 * so easy to miss: sixteen operations were harmless on a 256 MB volume and
 * corrupted a 64 MB one, whose journal is the 4 MB minimum. The reorder suite
 * ran on the larger image and passed.
 *
 * So the real bound is the number of blocks the transaction has dirtied
 * against the journal's capacity. A quarter is deliberately cautious: each
 * dirty block needs a journal block plus descriptor and commit overhead, and
 * being wrong here corrupts filesystems rather than slowing them down.
 */
static bool txn_must_commit(ext4b_device *dev, struct ext4_fs *fs)
{
    if (dev->txn_ops >= dev->txn_batch)
        return true;

#if CONFIG_JOURNALING_ENABLE
    if (fs->jbd_journal && fs->curr_trans) {
        struct jbd_journal *jbd = fs->jbd_journal;
        uint32_t maxlen = jbd_get32(&jbd->jbd_fs->sb, maxlen);
        if (maxlen && (uint32_t)fs->curr_trans->data_cnt > maxlen / 4)
            return true;

        /* And against what the ring actually has left, not just its total
         * size: the tail is held back by committed-but-uncheckpointed
         * predecessors, so a modest transaction can still force the
         * allocator to flush a checkpoint mid-commit to make room. That is
         * safe now -- the wrap path barriers and republishes the tail --
         * but it serializes the commit behind a checkpoint flush and two
         * barriers at the worst possible moment. Committing early keeps the
         * stall out of the commit path. Each dirtied block costs a log
         * block plus tag, so half the free space is the cautious bound. */
        uint32_t first = jbd_get32(&jbd->jbd_fs->sb, first);
        if (maxlen > first) {
            uint32_t ring = maxlen - first;
            uint32_t used = (jbd->last + ring - jbd->start) % ring;
            uint32_t free_blocks = ring - used;
            if ((uint32_t)fs->curr_trans->data_cnt > free_blocks / 2)
                return true;
        }
    }
#endif
    return false;
}

/* Close a mutation.
 *
 * The transaction is no longer committed here on every call. It stays open and
 * collects the next mutation, until the batch is full or something explicitly
 * asks for durability -- ext4b_sync, or unmount. macOS calls the volume's
 * synchronize periodically, so an idle batch does not sit uncommitted
 * indefinitely.
 *
 * What this trades away is worth stating. A failed operation used to roll back
 * completely, because it was alone in its transaction and aborting it undid
 * exactly that operation. Batched with others, an abort would discard their
 * work too -- so a failure with siblings commits the batch and returns the
 * error, which can leave the failed operation's partial changes behind. That
 * is what Linux does, and the guarantee being given up was a side effect of
 * transaction-per-operation rather than a designed property; nothing tests it.
 * A failure that is alone in its transaction still rolls back exactly as
 * before, and most do: almost every error path here returns before touching
 * anything.
 *
 * On a journalled volume no barrier is issued here at all. jbd already
 * barriers either side of the commit block, so once the commit returns the
 * transaction is on the medium and a crash replays it. Without a journal there
 * is nothing to replay, so the barrier there is the only thing making the
 * change durable and it stays. */
static int txn_finish(ext4b_device *dev, struct ext4_fs *fs, int r)
{
    if (r != EOK) {
        if (dev->txn_ops == 0) {
            txn_abort(fs);
            return r;
        }
        /* Siblings in the batch did nothing wrong -- but if the commit that
         * carries them ALSO fails, that failure must not hide behind the
         * original error: the original was one operation, the commit is the
         * whole batch. Report the commit's. */
        int cr = txn_commit(fs);
        dev->txn_ops = 0;
        return (cr != EOK) ? cr : r;
    }

    dev->txn_ops++;
    if (!txn_must_commit(dev, fs))
        return EOK;

    r = txn_commit(fs);
    dev->txn_ops = 0;
    if (r == EOK) {
        /* These two are the durability of everything just committed on a
         * journal-less volume, and of the checkpoint write-back on a
         * journalled one. fsync(2) used to return 0 over their failures. */
        r = ext4_block_cache_flush(&dev->bdev);
        if (r == EOK && dev->flush_fn && !dev->journal_running)
            r = dev->flush_fn(dev->ctx) == 0 ? EOK : EIO;
    }
    return r;
}

/* Commit whatever is open, for the paths that must not defer: sync, unmount,
 * and anything that hands the volume to somebody else. */
static int txn_drain(ext4b_device *dev)
{
    struct ext4_fs *fs = bridge_fs(dev);
    if (!fs || dev->txn_ops == 0)
        return EOK;

    int r = txn_commit(fs);
    dev->txn_ops = 0;
    if (r == EOK)
        r = ext4_block_cache_flush(&dev->bdev);
    return r;
}

/* Guard shared by every mutating entry point. */
#define WRITE_PROLOGUE(dev, fs)                                                \
    struct ext4_fs *fs;                                                        \
    do {                                                                       \
        if (!(dev) || !(dev)->mounted)                                         \
            return EINVAL;                                                     \
        if ((dev)->read_only)                                                  \
            return EROFS;                                                      \
        fs = bridge_fs(dev);                                                   \
        if (!fs)                                                               \
            return EINVAL;                                                     \
    } while (0)

/* ----------------------------------------------------------- timestamps -- */

typedef enum {
    TOUCH_ATIME = 1 << 0,
    TOUCH_MTIME = 1 << 1,
    TOUCH_CTIME = 1 << 2,
    TOUCH_CRTIME = 1 << 3,
} touch_flags;

static uint32_t now_seconds(void)
{
    struct timespec ts;
    if (clock_gettime(CLOCK_REALTIME, &ts) != 0)
        return 0;
    return (uint32_t)ts.tv_sec;
}

/*
 * lwext4 never updates inode times; filling that gap is ours to do. The
 * sub-second *_extra fields only exist on inodes large enough to carry them.
 */
static void touch(struct ext4_fs *fs, struct ext4_inode_ref *ref,
                  touch_flags which)
{
    uint32_t t = now_seconds();

    if (which & TOUCH_ATIME) ext4_inode_set_access_time(ref->inode, t);
    if (which & TOUCH_MTIME) ext4_inode_set_modif_time(ref->inode, t);
    if (which & TOUCH_CTIME) ext4_inode_set_change_inode_time(ref->inode, t);

    if (ext4_inode_get_extra_isize(&fs->sb, ref->inode) >= 24) {
        if (which & TOUCH_CRTIME)
            ref->inode->crtime = to_le32(t);
    }
    ref->dirty = true;
}

/* ------------------------------------------------------------ directory -- */

/* lwext4's equivalent (ext4_has_children) is static; this reimplements it. */
static int dir_has_children(struct ext4_inode_ref *dir, bool *out)
{
    struct ext4_fs *fs = dir->fs;
    *out = false;

    if (!ext4_inode_is_type(&fs->sb, dir->inode, EXT4_INODE_MODE_DIRECTORY))
        return ENOTDIR;

    struct ext4_dir_iter it;
    int r = ext4_dir_iterator_init(&it, dir, 0);
    if (r != EOK)
        return r;

    while (it.curr != NULL) {
        uint32_t ino = ext4_dir_en_get_inode(it.curr);
        if (ino != 0) {
            uint16_t len = ext4_dir_en_get_name_len(&fs->sb, it.curr);
            const char *nm = (const char *)it.curr->name;
            bool dot    = (len == 1 && nm[0] == '.');
            bool dotdot = (len == 2 && nm[0] == '.' && nm[1] == '.');
            if (!dot && !dotdot) {
                *out = true;
                break;
            }
        }
        r = ext4_dir_iterator_next(&it);
        if (r != EOK)
            break;
    }

    ext4_dir_iterator_fini(&it);
    return r == EOK ? EOK : r;
}

static int type_to_filetype(ext4b_item_type t)
{
    switch (t) {
    case EXT4B_TYPE_FILE:     return EXT4_DE_REG_FILE;
    case EXT4B_TYPE_DIR:      return EXT4_DE_DIR;
    case EXT4B_TYPE_SYMLINK:  return EXT4_DE_SYMLINK;
    case EXT4B_TYPE_FIFO:     return EXT4_DE_FIFO;
    case EXT4B_TYPE_CHARDEV:  return EXT4_DE_CHRDEV;
    case EXT4B_TYPE_BLOCKDEV: return EXT4_DE_BLKDEV;
    case EXT4B_TYPE_SOCKET:   return EXT4_DE_SOCK;
    default:                  return -1;
    }
}

/*
 * Port of lwext4's static ext4_link(). Adds `child` to `parent` under `name`,
 * creating the "." and ".." entries (or the HTree index) for a new directory
 * and maintaining link counts. `rename` suppresses the link-count increment
 * and dot-entry creation, since a rename moves an existing entry.
 */
static int link_child(struct ext4_fs *fs,
                      struct ext4_inode_ref *parent,
                      struct ext4_inode_ref *child,
                      const char *name, uint32_t name_len,
                      bool rename)
{
    if (name_len > EXT4_DIRECTORY_FILENAME_LEN)
        return ENAMETOOLONG;

    int r = ext4_dir_add_entry(parent, name, name_len, child);
    if (r != EOK)
        return r;

    bool is_dir = ext4_inode_is_type(&fs->sb, child->inode,
                                     EXT4_INODE_MODE_DIRECTORY);

    if (is_dir && !rename) {
#if CONFIG_DIR_INDEX_ENABLE
        if (ext4_sb_feature_com(&fs->sb, EXT4_FCOM_DIR_INDEX)) {
            r = ext4_dir_dx_init(child, parent);
            if (r != EOK)
                return r;
            ext4_inode_set_flag(child->inode, EXT4_INODE_FLAG_INDEX);
            child->dirty = true;
        } else
#endif
        {
            r = ext4_dir_add_entry(child, ".", 1, child);
            if (r != EOK) {
                ext4_dir_remove_entry(parent, name, name_len);
                return r;
            }
            r = ext4_dir_add_entry(child, "..", 2, parent);
            if (r != EOK) {
                ext4_dir_remove_entry(parent, name, name_len);
                ext4_dir_remove_entry(child, ".", 1);
                return r;
            }
        }

        /* A fresh directory has two links: its name, and its own ".". */
        ext4_inode_set_links_cnt(child->inode, 2);
        ext4_fs_inode_links_count_inc(parent);
        child->dirty = true;
        parent->dirty = true;
        return EOK;
    }

    /* Re-parenting an existing directory: repoint its "..". */
    if (is_dir) {
        if (!ext4_inode_has_flag(child->inode, EXT4_INODE_FLAG_INDEX)) {
            struct ext4_dir_search_result res;
            r = ext4_dir_find_entry(&res, child, "..", 2);
            if (r != EOK)
                return EIO;
            ext4_dir_en_set_inode(res.dentry, parent->index);
            ext4_trans_set_block_dirty(res.block.buf);
            r = ext4_dir_destroy_result(child, &res);
            if (r != EOK)
                return r;
        } else {
#if CONFIG_DIR_INDEX_ENABLE
            r = ext4_dir_dx_reset_parent_inode(child, parent->index);
            if (r != EOK)
                return r;
#endif
        }
        ext4_fs_inode_links_count_inc(parent);
        parent->dirty = true;
    }

    if (!rename) {
        ext4_fs_inode_links_count_inc(child);
        child->dirty = true;
    }
    return EOK;
}

/* Port of lwext4's static ext4_unlink(), plus the parent timestamp updates
 * lwext4 leaves as a TODO. */
static int unlink_child(struct ext4_fs *fs,
                        struct ext4_inode_ref *parent,
                        struct ext4_inode_ref *child,
                        const char *name, uint32_t name_len)
{
    bool has_children = false;
    bool is_dir = ext4_inode_is_type(&fs->sb, child->inode,
                                     EXT4_INODE_MODE_DIRECTORY);

    if (is_dir) {
        int rc = dir_has_children(child, &has_children);
        if (rc != EOK)
            return rc;
        if (has_children)
            return ENOTEMPTY;
    }

    int rc = ext4_dir_remove_entry(parent, name, name_len);
    if (rc != EOK)
        return rc;

    if (is_dir) {
        /* The child's ".." no longer counts against the parent. */
        ext4_fs_inode_links_count_dec(parent);
        parent->dirty = true;
        /* Drop the directory's own "." link as well as its name. */
        ext4_inode_set_links_cnt(child->inode, 0);
    } else {
        ext4_fs_inode_links_count_dec(child);
    }

    touch(fs, parent, TOUCH_MTIME | TOUCH_CTIME);
    touch(fs, child, TOUCH_CTIME);
    child->dirty = true;
    return EOK;
}

/* ------------------------------------------------ immutable / append-only -- */
/*
 * `chattr +i` and `chattr +a`. These are the two inode flags a Linux user sets
 * specifically to stop a file being changed, so a driver that ignores them
 * hands back exactly the protection the user asked for -- and the user has no
 * way to know until the file is gone.
 *
 * The rules below are Linux's, from may_delete(), vfs_link(), notify_change()
 * and xattr_permission():
 *
 *   immutable    nothing about the file may change: not its contents, not its
 *                size, not its attributes, not its extended attributes, not
 *                its names. A directory that is immutable cannot gain or lose
 *                entries either.
 *   append-only  the file may grow but its existing contents may not be
 *                rewritten in place. Size changes through truncate are refused
 *                even when they would grow the file, because truncate is not
 *                an append. Attribute changes are still allowed; only root can
 *                clear the flag, and clearing it is not something this driver
 *                offers at all. See ext4b_write for what "in place" can and
 *                cannot mean once a buffer cache is in the way.
 *
 * Both refuse with EPERM, which is what Linux returns and what the tools that
 * set these flags expect to see.
 */

static bool is_immutable(struct ext4_inode_ref *ref)
{
    return ext4_inode_has_flag(ref->inode, EXT4_INODE_FLAG_IMMUTABLE);
}

static bool is_append_only(struct ext4_inode_ref *ref)
{
    return ext4_inode_has_flag(ref->inode, EXT4_INODE_FLAG_APPEND);
}

/* Removing or renaming an entry changes both the directory and the thing named
 * in it, so both have to allow it. */
static bool unlink_forbidden(struct ext4_inode_ref *dir,
                             struct ext4_inode_ref *victim)
{
    return is_immutable(dir) || is_append_only(dir)
        || is_immutable(victim) || is_append_only(victim);
}

/*
 * The inode a directory's ".." points at. NOT ext4_dir_find_entry: on an
 * htree-indexed directory (lwext4 sets EXT4_INODE_FLAG_INDEX on the dirs it
 * creates) that walks the hash index, which never contains "." or ".." --
 * those live only in the first data block. So read the first block and match
 * ".." there directly. Returns 0 on any failure, which callers treat as
 * "stop walking".
 */
static uint32_t dir_parent_inode(struct ext4_fs *fs, uint32_t dir_inode)
{
    struct ext4_inode_ref d;
    if (ext4_fs_get_inode_ref(fs, dir_inode, &d) != EOK)
        return 0;

    uint32_t parent = 0;
    ext4_fsblk_t fblk = 0;
    if (ext4_fs_get_inode_dblk_idx(&d, 0, &fblk, false) == EOK && fblk != 0) {
        struct ext4_block b;
        if (ext4_trans_block_get(fs->bdev, &b, fblk) == EOK) {
            struct ext4_dir_en *en = NULL;
            if (ext4_dir_find_in_block(&b, &fs->sb, 2, "..", &en) == EOK && en)
                parent = ext4_dir_en_get_inode(en);
            ext4_block_set(fs->bdev, &b);
        }
    }
    ext4_fs_put_inode_ref(&d);
    return parent;
}

/* ---------------------------------------------------------------- create -- */

static int create_common(ext4b_device *dev, struct ext4_fs *fs,
                         uint32_t parent_inode,
                         const char *name, size_t name_len,
                         int filetype,
                         uint32_t mode, uint32_t uid, uint32_t gid,
                         const char *symlink_target, size_t target_len,
                         uint32_t *out_inode)
{
    if (name_len == 0 || name_len > EXT4_DIRECTORY_FILENAME_LEN)
        return ENAMETOOLONG;

    int r = txn_begin(fs);
    if (r != EOK)
        return r;

    struct ext4_inode_ref parent;
    r = ext4_fs_get_inode_ref(fs, parent_inode, &parent);
    if (r != EOK)
        return txn_finish(dev, fs, r);

    if (is_immutable(&parent)) {
        ext4_fs_put_inode_ref(&parent);
        return txn_finish(dev, fs, EPERM);
    }

    if (!ext4_inode_is_type(&fs->sb, parent.inode, EXT4_INODE_MODE_DIRECTORY)) {
        ext4_fs_put_inode_ref(&parent);
        return txn_finish(dev, fs, ENOTDIR);
    }

    /* Refuse to shadow an existing name rather than silently replacing it. */
    struct ext4_dir_search_result probe_res;
    if (ext4_dir_find_entry(&probe_res, &parent, name, (uint32_t)name_len) == EOK) {
        ext4_dir_destroy_result(&parent, &probe_res);
        ext4_fs_put_inode_ref(&parent);
        return txn_finish(dev, fs, EEXIST);
    }

    struct ext4_inode_ref child;
    r = ext4_fs_alloc_inode(fs, &child, filetype);
    if (r != EOK) {
        ext4_fs_put_inode_ref(&parent);
        return txn_finish(dev, fs, r);
    }
    ext4_fs_inode_blocks_init(fs, &child);

    /* alloc_inode applies a default mode; override with what was asked for,
     * preserving the type bits it set. */
    uint32_t full_mode = ext4_inode_get_mode(&fs->sb, child.inode);
    full_mode = (full_mode & EXT4_INODE_MODE_TYPE_MASK) | (mode & 0x0FFF);
    ext4_inode_set_mode(&fs->sb, child.inode, full_mode);
    ext4_inode_set_uid(child.inode, uid);
    ext4_inode_set_gid(child.inode, gid);
    touch(fs, &child, TOUCH_ATIME | TOUCH_MTIME | TOUCH_CTIME | TOUCH_CRTIME);
    child.dirty = true;

    r = link_child(fs, &parent, &child, name, (uint32_t)name_len, false);
    if (r != EOK) {
        ext4_fs_free_inode(&child);
        child.dirty = false;
        ext4_fs_put_inode_ref(&child);
        ext4_fs_put_inode_ref(&parent);
        return txn_finish(dev, fs, r);
    }

    /* Symlink payload: short targets live inline in the block-pointer array,
     * longer ones need a real data block. */
    if (symlink_target && target_len > 0) {
        if (target_len < sizeof(child.inode->blocks)) {
            memset(child.inode->blocks, 0, sizeof(child.inode->blocks));
            memcpy(child.inode->blocks, symlink_target, target_len);
            ext4_inode_set_size(child.inode, target_len);
            child.dirty = true;
        } else {
            ext4_fsblk_t fblk = 0;
            uint32_t iblk = 0;
            r = ext4_fs_append_inode_dblk(&child, &fblk, &iblk);
            if (r == EOK) {
                uint32_t bsize = ext4_sb_get_block_size(&fs->sb);
                uint8_t *tmp = calloc(1, bsize);
                if (!tmp) {
                    r = ENOMEM;
                } else {
                    memcpy(tmp, symlink_target, target_len);
                    r = ext4_block_writebytes(&dev->bdev,
                                              (uint64_t)fblk * bsize, tmp, bsize);
                    free(tmp);
                    if (r == EOK) {
                        ext4_inode_set_size(child.inode, target_len);
                        child.dirty = true;
                    }
                }
            }
            if (r != EOK) {
                /*
                 * The name is already linked but the target never made it to
                 * disk. Undo the link and free the inode rather than leave a
                 * zero-length symlink -- under batching txn_finish commits, so
                 * "return the error" is not enough to make it not have
                 * happened.
                 */
                ext4_dir_remove_entry(&parent, name, (uint32_t)name_len);
                ext4_fs_inode_links_count_dec(&child);
                ext4_inode_set_del_time(child.inode, now_seconds());
                ext4_fs_free_inode(&child);
                child.dirty = false;
                ext4_fs_put_inode_ref(&child);
                ext4_fs_put_inode_ref(&parent);
                return txn_finish(dev, fs, r);
            }
        }
    }

    touch(fs, &parent, TOUCH_MTIME | TOUCH_CTIME);

    if (out_inode)
        *out_inode = child.index;

    ext4_fs_put_inode_ref(&child);
    ext4_fs_put_inode_ref(&parent);
    return txn_finish(dev, fs, EOK);
}

int ext4b_create(ext4b_device *dev,
                 uint32_t parent_inode,
                 const char *name, size_t name_len,
                 ext4b_item_type type,
                 uint32_t mode, uint32_t uid, uint32_t gid,
                 uint32_t *out_inode)
{
    WRITE_PROLOGUE(dev, fs);
    int filetype = type_to_filetype(type);
    if (filetype < 0 || type == EXT4B_TYPE_SYMLINK)
        return EINVAL;   /* symlinks go through ext4b_symlink */
    return create_common(dev, fs, parent_inode, name, name_len, filetype,
                         mode, uid, gid, NULL, 0, out_inode);
}

int ext4b_symlink(ext4b_device *dev,
                  uint32_t parent_inode,
                  const char *name, size_t name_len,
                  const char *target, size_t target_len,
                  uint32_t uid, uint32_t gid,
                  uint32_t *out_inode)
{
    WRITE_PROLOGUE(dev, fs);
    if (!target || target_len == 0)
        return EINVAL;
    /*
     * An ext4 symlink target lives either inline in the inode's block array
     * (a fast symlink) or in exactly one data block (a slow symlink). Either
     * way it cannot exceed one block -- and it must be rejected HERE, before
     * create_common allocates and links the inode, or a target too long to
     * store would (a) overflow the one-block staging buffer, and (b) leave a
     * linked, zero-length symlink behind when the payload write bailed.
     * The terminator has to fit too, hence >= not >.
     */
    uint32_t bsize = ext4_sb_get_block_size(&fs->sb);
    if (target_len >= bsize || target_len > 4095)
        return ENAMETOOLONG;
    return create_common(dev, fs, parent_inode, name, name_len,
                         EXT4_DE_SYMLINK, 0777, uid, gid,
                         target, target_len, out_inode);
}

int ext4b_hardlink(ext4b_device *dev,
                   uint32_t parent_inode,
                   const char *name, size_t name_len,
                   uint32_t target_inode)
{
    WRITE_PROLOGUE(dev, fs);
    if (name_len == 0 || name_len > EXT4_DIRECTORY_FILENAME_LEN)
        return ENAMETOOLONG;

    int r = txn_begin(fs);
    if (r != EOK)
        return r;

    struct ext4_inode_ref parent, child;
    r = ext4_fs_get_inode_ref(fs, parent_inode, &parent);
    if (r != EOK)
        return txn_finish(dev, fs, r);

    r = ext4_fs_get_inode_ref(fs, target_inode, &child);
    if (r != EOK) {
        ext4_fs_put_inode_ref(&parent);
        return txn_finish(dev, fs, r);
    }

    /* A new name is a change to the file as much as to the directory. */
    if (is_immutable(&parent) || is_immutable(&child) || is_append_only(&child)) {
        ext4_fs_put_inode_ref(&child);
        ext4_fs_put_inode_ref(&parent);
        return txn_finish(dev, fs, EPERM);
    }

    /* POSIX forbids hard links to directories: they would let a user create
     * cycles that fsck cannot untangle. */
    if (ext4_inode_is_type(&fs->sb, child.inode, EXT4_INODE_MODE_DIRECTORY)) {
        ext4_fs_put_inode_ref(&child);
        ext4_fs_put_inode_ref(&parent);
        return txn_finish(dev, fs, EPERM);
    }

    /* Refuse to shadow an existing name -- link(2) returns EEXIST, and
     * silently adding a second directory entry for the same name corrupts
     * the directory. create_common guards this; hardlink did not. */
    struct ext4_dir_search_result exists;
    if (ext4_dir_find_entry(&exists, &parent, name, (uint32_t)name_len) == EOK) {
        ext4_dir_destroy_result(&parent, &exists);
        ext4_fs_put_inode_ref(&child);
        ext4_fs_put_inode_ref(&parent);
        return txn_finish(dev, fs, EEXIST);
    }

    r = link_child(fs, &parent, &child, name, (uint32_t)name_len, false);
    if (r == EOK) {
        touch(fs, &child, TOUCH_CTIME);
        touch(fs, &parent, TOUCH_MTIME | TOUCH_CTIME);
    }

    ext4_fs_put_inode_ref(&child);
    ext4_fs_put_inode_ref(&parent);
    return txn_finish(dev, fs, r);
}

/* ---------------------------------------------------------- orphan list -- */
/*
 * An inode that has lost its last name but is still open cannot be freed yet.
 * ext4 records those on a singly-linked list so that a crash in that window is
 * recoverable instead of a permanent leak: the head is the superblock's
 * s_last_orphan, and each entry stores the next inode number in its own
 * i_dtime -- a field that means nothing until the inode is really deleted.
 *
 * This is deliberately the same on-disk convention Linux and e2fsck already
 * use. A volume left with orphans by this driver is cleaned up correctly by
 * either of them, and one left by Linux is cleaned up by us.
 *
 * Atomicity is copied from Linux too, now. The superblock is a journaled
 * block (lwext4 patches 0022/0023): a list edit made inside a transaction --
 * the head publish on add, the head advance on remove, the predecessor patch
 * mid-chain -- commits together with the inode change it protects, or not at
 * all. There is no ordering to choose and no half-state for a cut to find:
 * before the commit neither half happened, after it both did.
 *
 * That sentence used to be thirty lines of carefully measured ordering
 * discipline, and one admitted imperfection: with two simultaneous
 * open-unlinks, a cut between publishing the second head (a direct device
 * write then) and committing its transaction lost the rest of the chain --
 * measured, four consecutive cut points stranding an inode. The two-orphan
 * sweep in Tests/run_orphan_tests.sh covers every cut of that scenario now,
 * and the Linux kernel replays the superblock-carrying transactions clean.
 *
 * Volumes without a journal (ext2) still take the direct write and the old
 * ordering, adding-side publish-first: there is no atomicity to be had, and
 * the worst outcome stays a leaked inode that e2fsck reclaims -- never a
 * live file destroyed.
 */

/* A corrupt or circular chain must not be able to spin the driver. */
#define ORPHAN_WALK_LIMIT 4096

static uint32_t orphan_next(struct ext4_inode_ref *ref)
{
    return ext4_inode_get_del_time(ref->inode);
}

static void orphan_set_next(struct ext4_inode_ref *ref, uint32_t next)
{
    ext4_inode_set_del_time(ref->inode, next);
    ref->dirty = true;
}

/* Reserved inodes are never orphans, and neither is anything past the end of
 * the table. Anything else terminates the walk rather than being followed. */
static bool orphan_plausible(struct ext4_fs *fs, uint32_t ino)
{
    uint32_t first = ext4_get32(&fs->sb, first_inode);
    if (first < EXT4B_ROOT_INO)
        first = EXT4_GOOD_OLD_FIRST_INO;
    return ino >= first && ino <= ext4_get32(&fs->sb, inodes_count);
}

/*
 * Is this inode actually allocated? lwext4's free_inode clears the bitmap bit
 * but leaves the inode body alone, so link count and mode look exactly the
 * same before and after -- the bitmap is the only thing that can tell them
 * apart, and telling them apart is what stops recovery freeing an inode twice.
 */
static int inode_in_use(struct ext4_fs *fs, uint32_t index, bool *out)
{
    uint32_t per_group = ext4_get32(&fs->sb, inodes_per_group);
    if (per_group == 0 || index == 0)
        return EINVAL;

    struct ext4_block_group_ref bg_ref;
    int r = ext4_fs_get_block_group_ref(fs, (index - 1) / per_group, &bg_ref);
    if (r != EOK)
        return r;

    struct ext4_block b;
    r = ext4_block_get(fs->bdev, &b,
                       ext4_bg_get_inode_bitmap(bg_ref.block_group, &fs->sb));
    if (r != EOK) {
        ext4_fs_put_block_group_ref(&bg_ref);
        return r;
    }

    *out = ext4_bmap_is_bit_set(b.data, (index - 1) % per_group);

    ext4_block_set(fs->bdev, &b);
    ext4_fs_put_block_group_ref(&bg_ref);
    return EOK;
}

/* The head is the only part of the list that is not inside an inode, so this
 * is the only place the superblock is written for it.
 *
 * Inside a journal transaction, the head goes through the journal
 * (ext4_sb_write_trans) and commits atomically with the inode change it
 * points at. That closes the gap this file used to document at length: a
 * crash between a direct head publish and the commit of the unlink behind it
 * lost every orphan already on the chain -- measured, four consecutive cut
 * points leaking an inode in the two-orphan sweep. Atomic means there is no
 * "between" any more: before the commit neither the head nor the unlink
 * happened; after it, both did.
 *
 * Without a journal (ext2) or outside a transaction, the old direct write
 * and barrier remain -- there is no atomicity to be had there, and immediate
 * durability is the best that mode can offer. */
static int orphan_publish_head(ext4b_device *dev, struct ext4_fs *fs,
                               uint32_t ino)
{
    ext4_set32(&fs->sb, last_orphan, ino);
#if CONFIG_JOURNALING_ENABLE
    if (fs->jbd_journal && fs->curr_trans)
        return ext4_sb_write_trans(fs->bdev, &fs->sb);
#endif
    int r = ext4_sb_write(fs->bdev, &fs->sb);
    if (r != EOK)
        return r;
    if (dev->flush_fn)
        return dev->flush_fn(dev->ctx);
    return EOK;
}

/* Take an inode off the list. Runs in its own transaction: patching a
 * mid-chain predecessor is an inode write and has to be journaled like any
 * other. */
static int orphan_del(ext4b_device *dev, struct ext4_fs *fs, uint32_t ino)
{
    uint32_t head = ext4_get32(&fs->sb, last_orphan);
    if (head == 0 || ino == 0)
        return EOK;

    int r = txn_begin(fs);
    if (r != EOK)
        return r;

    /* What follows the victim, so the chain can be closed over it. */
    uint32_t after = 0;
    struct ext4_inode_ref victim;
    r = ext4_fs_get_inode_ref(fs, ino, &victim);
    if (r != EOK)
        return txn_finish(dev, fs, r);
    after = orphan_next(&victim);
    if (!orphan_plausible(fs, after))
        after = 0;
    /* Clear the pointer while the inode is still ours to write. Leaving a
     * stale inode number in i_dtime would look like a deletion timestamp far
     * in the future to anything reading the inode afterwards. */
    orphan_set_next(&victim, 0);
    ext4_fs_put_inode_ref(&victim);

    if (head == ino) {
        /* Inside the transaction, so the head moves in the same commit that
         * rewrites the victim's inode. On failure the journal discards the
         * block; only the in-memory copy needs putting back. */
        r = orphan_publish_head(dev, fs, after);
        r = txn_finish(dev, fs, r);
        if (r != EOK)
            ext4_set32(&fs->sb, last_orphan, head);
        return r;
    }

    uint32_t prev = head;
    for (uint32_t guard = 0; prev != 0 && guard < ORPHAN_WALK_LIMIT; guard++) {
        if (!orphan_plausible(fs, prev))
            break;

        struct ext4_inode_ref ref;
        r = ext4_fs_get_inode_ref(fs, prev, &ref);
        if (r != EOK)
            return txn_finish(dev, fs, r);

        uint32_t next = orphan_next(&ref);
        if (next == ino) {
            orphan_set_next(&ref, after);
            ext4_fs_put_inode_ref(&ref);
            return txn_finish(dev, fs, EOK);
        }
        ext4_fs_put_inode_ref(&ref);
        prev = next;
    }

    /* Not on the list. Not an error: release_inode is also reached for inodes
     * that were never deferred. */
    return txn_finish(dev, fs, EOK);
}

/*
 * Walk the list left behind by an interrupted session and settle every entry.
 * Called once at mount, after journal recovery, so that a volume this driver
 * crashed on comes back whole without anyone having to run e2fsck.
 *
 * Two kinds of entry can be on the list, and they are told apart by the link
 * count exactly as Linux tells them apart:
 *
 *   links == 0  the delete was interrupted after the name went away. Finish
 *               it: truncate the blocks and free the inode.
 *   links  > 0  the inode still has a name, so this is an entry we published
 *               and then crashed before -- or after -- the transaction that
 *               was supposed to unlink it. Drop it from the list and leave the
 *               file alone. Linux truncates such an inode to its own i_size
 *               here, which for an intact file is a no-op; not touching it at
 *               all reaches the same result without needing i_size to be
 *               trustworthy.
 */
int ext4b_orphan_cleanup(ext4b_device *dev, uint32_t *out_freed,
                         uint32_t *out_dropped)
{
    if (out_freed)   *out_freed = 0;
    if (out_dropped) *out_dropped = 0;

    WRITE_PROLOGUE(dev, fs);

    for (uint32_t guard = 0; guard < ORPHAN_WALK_LIMIT; guard++) {
        uint32_t ino = ext4_get32(&fs->sb, last_orphan);
        if (ino == 0)
            return EOK;

        if (!orphan_plausible(fs, ino)) {
            /* An inode number outside the table, or one of the reserved ones,
             * cannot be an orphan under any writer -- so there is nothing in
             * it for anyone to recover, and leaving it would mean complaining
             * about the same superblock at every mount from now on. Linux
             * clears the head and stops here too. */
            bridge_log(3, "orphan list head is not a usable inode; clearing it");
            return orphan_publish_head(dev, fs, 0);
        }

        int r = txn_begin(fs);
        if (r != EOK)
            return r;

        struct ext4_inode_ref ref;
        r = ext4_fs_get_inode_ref(fs, ino, &ref);
        if (r != EOK)
            return txn_finish(dev, fs, r);

        uint32_t next = orphan_next(&ref);
        if (!orphan_plausible(fs, next))
            next = 0;

        /* The release may have got as far as freeing the inode and no
         * further, in which case there is nothing left to do but drop the
         * entry. Freeing it a second time would corrupt the group counters. */
        bool in_use = true;
        r = inode_in_use(fs, ino, &in_use);
        if (r != EOK) {
            /* Cannot tell. Both guesses are destructive: freeing an
             * already-freed inode corrupts the group counters, and dropping
             * a still-allocated one leaks it beyond anything but e2fsck.
             * The head has not moved yet, so stopping leaves the whole list
             * for the next mount, which the caller already treats as
             * "usable; some space may be unreclaimed". The old fallback
             * guessed in_use=true -- which routed an unreadable bitmap into
             * truncate-and-free, the exact double-free the comment above
             * promises to avoid. */
            ext4_fs_put_inode_ref(&ref);
            return txn_finish(dev, fs, r);
        }

        r = orphan_publish_head(dev, fs, next);
        if (r != EOK) {
            ext4_fs_put_inode_ref(&ref);
            return txn_finish(dev, fs, r);
        }

        bool freed = false;
        if (!in_use) {
            /* Already freed. Its i_dtime holds a real deletion time now, and
             * clearing it would turn a settled inode back into e2fsck's
             * "deleted inode with zero dtime", so the inode is left exactly as
             * it is. */
            ext4_fs_put_inode_ref(&ref);
            r = txn_finish(dev, fs, EOK);
            if (r == EOK && out_dropped)
                (*out_dropped)++;
        } else if (ext4_inode_get_links_cnt(ref.inode) != 0) {
            orphan_set_next(&ref, 0);
            ext4_fs_put_inode_ref(&ref);
            r = txn_finish(dev, fs, EOK);
            if (r == EOK && out_dropped)
                (*out_dropped)++;
        } else {
            ext4_inode_set_del_time(ref.inode, now_seconds());
            ref.dirty = true;
            r = ext4_fs_truncate_inode(&ref, 0);
            if (r == EOK)
                r = ext4_fs_free_inode(&ref);
            ext4_fs_put_inode_ref(&ref);
            r = txn_finish(dev, fs, r);
            freed = (r == EOK);
            if (freed && out_freed)
                (*out_freed)++;
        }
        if (r != EOK)
            return r;
    }

    bridge_log(3, "orphan list is longer than expected or circular; stopping");
    return EOK;
}

#ifdef EXT4B_TEST_HOOKS
void ext4b_set_orphan_cleanup(ext4b_device *dev, bool enabled)
{
    if (dev)
        dev->skip_orphan_cleanup = !enabled;
}

int ext4b_orphan_head(ext4b_device *dev, uint32_t *out_head)
{
    if (!dev || !dev->mounted || !out_head)
        return EINVAL;
    struct ext4_fs *fs = bridge_fs(dev);
    if (!fs)
        return EINVAL;
    *out_head = ext4_get32(&fs->sb, last_orphan);
    return EOK;
}
#endif /* EXT4B_TEST_HOOKS */

/* ---------------------------------------------------------------- unlink -- */

int ext4b_unlink(ext4b_device *dev,
                 uint32_t parent_inode,
                 const char *name, size_t name_len)
{
    return ext4b_unlink_ex(dev, parent_inode, name, name_len, false, NULL);
}

int ext4b_release_inode(ext4b_device *dev, uint32_t inode)
{
    WRITE_PROLOGUE(dev, fs);
    if (inode < EXT4B_ROOT_INO)
        return EINVAL;

    /* This inode is about to stop existing. A later eviction that tried to
     * return its reservation would be reading a freed inode -- and if the
     * number had been handed out again by then, trimming somebody else's
     * file. */
    resv_forget(dev, inode);

    /* One file deleted while open is the overwhelmingly common case, and it is
     * the head of the list. Only a middle entry has to come off before it is
     * freed -- see the ordering note above. */
    bool is_head = (ext4_get32(&fs->sb, last_orphan) == inode);
    if (!is_head) {
        int dr = orphan_del(dev, fs, inode);
        if (dr != EOK)
            return dr;
    }

    int r = txn_begin(fs);
    if (r != EOK)
        return r;

    struct ext4_inode_ref ref;
    r = ext4_fs_get_inode_ref(fs, inode, &ref);
    if (r != EOK)
        return txn_finish(dev, fs, r);

    /* Only inodes that genuinely have no names left. Anything else means the
     * caller lost track of a reference, and freeing it would destroy a file
     * that is still reachable. */
    if (ext4_inode_get_links_cnt(ref.inode) != 0) {
        ext4_fs_put_inode_ref(&ref);
        return txn_finish(dev, fs, EBUSY);
    }

    /* Somebody may have got here first -- mount-time cleanup settles exactly
     * these inodes, and a caller that also remembers owing a release will ask
     * for one it no longer owes. Freeing an inode twice does not fail, it
     * quietly decrements the group's free count a second time and leaves the
     * volume reporting "Free inodes count wrong", so this is checked rather
     * than assumed. Doing nothing is the honest answer: the inode is already
     * in the state the caller wanted. */
    bool in_use = true;
    if (inode_in_use(fs, inode, &in_use) == EOK && !in_use) {
        ext4_fs_put_inode_ref(&ref);
        return txn_finish(dev, fs, EOK);
    }

    /* Read the successor out before the deletion time overwrites the field it
     * lives in. */
    uint32_t next = orphan_next(&ref);
    if (!orphan_plausible(fs, next))
        next = 0;

    ext4_inode_set_del_time(ref.inode, now_seconds());
    ref.dirty = true;
    r = ext4_fs_truncate_inode(&ref, 0);
    if (r == EOK)
        r = ext4_fs_free_inode(&ref);

    ext4_fs_put_inode_ref(&ref);

    /* The head advance joins the same transaction as the free, which ends
     * the choose-your-failure ordering this used to need: freed-but-listed
     * and listed-but-freed were both real states a cut could leave, and the
     * order only picked which. Now the commit carries both or neither. */
    if (r == EOK && is_head)
        r = orphan_publish_head(dev, fs, next);
    r = txn_finish(dev, fs, r);
    if (r != EOK && is_head)
        ext4_set32(&fs->sb, last_orphan, inode);

    return r;
}

int ext4b_unlink_ex(ext4b_device *dev,
                    uint32_t parent_inode,
                    const char *name, size_t name_len,
                    bool defer_release,
                    bool *out_unreferenced)
{
    if (out_unreferenced)
        *out_unreferenced = false;

    WRITE_PROLOGUE(dev, fs);
    if (name_len == 0)
        return EINVAL;
    if ((name_len == 1 && name[0] == '.') ||
        (name_len == 2 && name[0] == '.' && name[1] == '.'))
        return EINVAL;

    int r = txn_begin(fs);
    if (r != EOK)
        return r;

    struct ext4_inode_ref parent;
    r = ext4_fs_get_inode_ref(fs, parent_inode, &parent);
    if (r != EOK)
        return txn_finish(dev, fs, r);

    struct ext4_dir_search_result res;
    r = ext4_dir_find_entry(&res, &parent, name, (uint32_t)name_len);
    if (r != EOK) {
        ext4_fs_put_inode_ref(&parent);
        return txn_finish(dev, fs, ENOENT);
    }
    uint32_t child_ino = ext4_dir_en_get_inode(res.dentry);
    ext4_dir_destroy_result(&parent, &res);

    struct ext4_inode_ref child;
    r = ext4_fs_get_inode_ref(fs, child_ino, &child);
    if (r != EOK) {
        ext4_fs_put_inode_ref(&parent);
        return txn_finish(dev, fs, r);
    }

    if (unlink_forbidden(&parent, &child)) {
        ext4_fs_put_inode_ref(&child);
        ext4_fs_put_inode_ref(&parent);
        return txn_finish(dev, fs, EPERM);
    }

    r = unlink_child(fs, &parent, &child, name, (uint32_t)name_len);
    if (r != EOK) {
        ext4_fs_put_inode_ref(&child);
        ext4_fs_put_inode_ref(&parent);
        return txn_finish(dev, fs, r);
    }

    /* Last name gone. Normally that means releasing the blocks and the inode
     * right here; with defer_release the caller has said the file may still be
     * open, so the inode stays allocated until it tells us otherwise. */
    bool joined_orphans = false;
    uint32_t prev_head = ext4_get32(&fs->sb, last_orphan);
    if (ext4_inode_get_links_cnt(child.inode) == 0) {
        if (defer_release) {
            /* An inode with no links, no dtime and no orphan record is what
             * e2fsck calls a "deleted inode with zero dtime": ext4 expects
             * anything in that position to be on the orphan list, so that is
             * where it goes. i_dtime carries the next pointer until the inode
             * is really deleted, which is the same use Linux puts it to. */
            orphan_set_next(&child, prev_head);
            joined_orphans = true;
            if (out_unreferenced)
                *out_unreferenced = true;
        } else {
            /* Gone for good: nothing may try to return blocks to it later. */
            resv_forget(dev, child.index);
            ext4_inode_set_del_time(child.inode, now_seconds());
            r = ext4_fs_truncate_inode(&child, 0);
            if (r == EOK)
                r = ext4_fs_free_inode(&child);
        }
    }

    ext4_fs_put_inode_ref(&child);
    ext4_fs_put_inode_ref(&parent);

    /* Inside the transaction: the head and the unlink it protects commit
     * together, or not at all. */
    if (r == EOK && joined_orphans) {
        int pr = orphan_publish_head(dev, fs, child_ino);
        if (pr != EOK) {
            bridge_log(3, "could not record the deleted-but-open inode on the "
                          "orphan list; a crash before it is closed would leak "
                          "it");
            ext4_set32(&fs->sb, last_orphan, prev_head);
            joined_orphans = false;
        }
    }

    r = txn_finish(dev, fs, r);

    /* The unlink did not happen after all, so neither should the list entry.
     * An aborted transaction already discarded the journaled superblock
     * block; this puts the in-memory copy back (and, on a journal-less
     * volume, un-publishes the direct write). */
    if (r != EOK && joined_orphans)
        orphan_publish_head(dev, fs, prev_head);

    return r;
}

/* ---------------------------------------------------------------- rename -- */

int ext4b_rename(ext4b_device *dev,
                 uint32_t src_parent, const char *src_name, size_t src_len,
                 uint32_t dst_parent, const char *dst_name, size_t dst_len)
{
    WRITE_PROLOGUE(dev, fs);
    if (src_len == 0 || dst_len == 0 || dst_len > EXT4_DIRECTORY_FILENAME_LEN)
        return EINVAL;

    int r = txn_begin(fs);
    if (r != EOK)
        return r;

    struct ext4_inode_ref sp, dp, child;
    bool have_sp = false, have_dp = false, have_child = false;

    r = ext4_fs_get_inode_ref(fs, src_parent, &sp);
    if (r != EOK)
        goto out;
    have_sp = true;

    if (dst_parent == src_parent) {
        dp = sp;    /* same inode; do not take a second reference */
    } else {
        r = ext4_fs_get_inode_ref(fs, dst_parent, &dp);
        if (r != EOK)
            goto out;
        have_dp = true;
    }

    /* Locate the entry being moved. */
    struct ext4_dir_search_result res;
    r = ext4_dir_find_entry(&res, &sp, src_name, (uint32_t)src_len);
    if (r != EOK) {
        r = ENOENT;
        goto out;
    }
    uint32_t child_ino = ext4_dir_en_get_inode(res.dentry);
    ext4_dir_destroy_result(&sp, &res);

    r = ext4_fs_get_inode_ref(fs, child_ino, &child);
    if (r != EOK)
        goto out;
    have_child = true;

    /* A rename takes a name away from one directory and gives it to another,
     * so it is subject to the same protection as an unlink at the source and
     * a create at the destination. */
    if (unlink_forbidden(&sp, &child) || is_immutable(&dp)) {
        r = EPERM;
        goto out;
    }

    bool child_is_dir =
        ext4_inode_is_type(&fs->sb, child.inode, EXT4_INODE_MODE_DIRECTORY);

    /*
     * Refuse to move a directory into its own subtree. Without this the moved
     * directory and everything under it becomes an unreachable cycle -- '..'
     * points into a loop, nothing points at the loop, and only e2fsck can
     * find it. Walk the destination's ancestry to the root: if the thing
     * being moved appears in it, the move would close a cycle. (rename(2)
     * answers EINVAL for exactly this.)
     */
    if (child_is_dir && dst_parent != src_parent) {
        uint32_t walk = dst_parent;
        while (walk != EXT4_INODE_ROOT_INDEX) {
            if (walk == child_ino) { r = EINVAL; goto out; }
            uint32_t parent_of = dir_parent_inode(fs, walk);
            if (parent_of == 0 || parent_of == walk)
                break;                     /* malformed or self-parent: stop */
            walk = parent_of;
        }
    }

    /* If something already occupies the destination, remove it first --
     * rename(2) replaces the target atomically. */
    struct ext4_dir_search_result dst_res;
    if (ext4_dir_find_entry(&dst_res, &dp, dst_name, (uint32_t)dst_len) == EOK) {
        uint32_t victim_ino = ext4_dir_en_get_inode(dst_res.dentry);
        ext4_dir_destroy_result(&dp, &dst_res);

        if (victim_ino != child_ino) {
            struct ext4_inode_ref victim;
            r = ext4_fs_get_inode_ref(fs, victim_ino, &victim);
            if (r != EOK)
                goto out;

            /*
             * Type compatibility, as rename(2) requires it: a directory may
             * only replace an (empty) directory, and a non-directory may only
             * replace a non-directory. unlink_child below rejects a non-empty
             * directory (ENOTEMPTY); the two cases it cannot see are a
             * non-dir over a dir (EISDIR) and a dir over a non-dir (ENOTDIR).
             */
            bool victim_is_dir =
                ext4_inode_is_type(&fs->sb, victim.inode, EXT4_INODE_MODE_DIRECTORY);
            if (!child_is_dir && victim_is_dir) {
                ext4_fs_put_inode_ref(&victim);
                r = EISDIR;
                goto out;
            }
            if (child_is_dir && !victim_is_dir) {
                ext4_fs_put_inode_ref(&victim);
                r = ENOTDIR;
                goto out;
            }

            /* Renaming over a protected file destroys it just as surely as
             * unlinking it would. */
            if (unlink_forbidden(&dp, &victim)) {
                ext4_fs_put_inode_ref(&victim);
                r = EPERM;
                goto out;
            }

            r = unlink_child(fs, &dp, &victim, dst_name, (uint32_t)dst_len);
            if (r == EOK && ext4_inode_get_links_cnt(victim.inode) == 0) {
                /* Renamed over: same rule as an unlink that frees. */
                resv_forget(dev, victim.index);
                ext4_inode_set_del_time(victim.inode, now_seconds());
                r = ext4_fs_truncate_inode(&victim, 0);
                if (r == EOK)
                    r = ext4_fs_free_inode(&victim);
            }
            ext4_fs_put_inode_ref(&victim);
            if (r != EOK)
                goto out;
        }
    }

    /* Link under the new name, then drop the old one. Ordering matters: if the
     * link fails we must not have already destroyed the only reference. */
    r = link_child(fs, &dp, &child, dst_name, (uint32_t)dst_len, true);
    if (r != EOK)
        goto out;

    r = ext4_dir_remove_entry(&sp, src_name, (uint32_t)src_len);
    if (r != EOK)
        goto out;

    /* Moving a directory out of sp removes its ".." reference to sp. */
    if (ext4_inode_is_type(&fs->sb, child.inode, EXT4_INODE_MODE_DIRECTORY) &&
        src_parent != dst_parent) {
        ext4_fs_inode_links_count_dec(&sp);
        sp.dirty = true;
    }

    touch(fs, &child, TOUCH_CTIME);
    touch(fs, &sp, TOUCH_MTIME | TOUCH_CTIME);
    if (src_parent != dst_parent)
        touch(fs, &dp, TOUCH_MTIME | TOUCH_CTIME);

out:
    if (have_child) ext4_fs_put_inode_ref(&child);
    if (have_dp)    ext4_fs_put_inode_ref(&dp);
    if (have_sp)    ext4_fs_put_inode_ref(&sp);
    return txn_finish(dev, fs, r);
}

/* ------------------------------------------------------------------ data -- */

/* How well file data is coalescing, which decides how many commands a copy
 * costs on media that charges per command. Data writes only: metadata goes
 * through the cache and is counted by the bridge's own meter, and the two
 * together are what separate "runs are short" from "most commands are
 * metadata". Reported every 32 MiB of file data. */
static struct {
    uint64_t runs;
    uint64_t blocks;
    uint64_t bytes;
    uint64_t reported;
    uint32_t longest;
} g_run_meter;

static void run_meter_record(uint32_t blocks, uint32_t bsize)
{
    g_run_meter.runs++;
    g_run_meter.blocks += blocks;
    g_run_meter.bytes  += (uint64_t)blocks * bsize;
    if (blocks > g_run_meter.longest)
        g_run_meter.longest = blocks;

    if (g_run_meter.bytes - g_run_meter.reported < (32u << 20))
        return;
    g_run_meter.reported = g_run_meter.bytes;
    bridge_logf(1, "data write runs: %llu runs, %llu MB, avg %llu blocks "
                   "(%llu KB), longest %u blocks",
                (unsigned long long)g_run_meter.runs,
                (unsigned long long)(g_run_meter.bytes >> 20),
                (unsigned long long)(g_run_meter.blocks / g_run_meter.runs),
                (unsigned long long)((g_run_meter.bytes / g_run_meter.runs) >> 10),
                g_run_meter.longest);
}

/* Issue a pending run of contiguous whole blocks as one command, and clear
 * it. Zero blocks is not an error: callers flush unconditionally. */
static int bridge_flush_run(struct ext4_blockdev *bdev, uint32_t bsize,
                            ext4_fsblk_t first, uint32_t *blocks,
                            const uint8_t *src)
{
    if (*blocks == 0)
        return EOK;

    int r = ext4_block_writebytes(bdev, (uint64_t)first * bsize, src,
                                  (*blocks) * bsize);
    /* File data goes straight to the medium, so a block that happens to be
     * resident in the cache now holds pre-write bytes -- and the partial
     * head/tail path below reads through the cache, where it would find
     * them. Refresh rather than invalidate: a resident buffer may be dirty
     * with metadata, and these are the newest bytes for this block either
     * way. Costs one lookup per block, no I/O. */
    if (r == EOK) {
        for (uint32_t i = 0; i < *blocks; i++)
            ext4_bcache_update_if_cached(bdev->bc, first + i, 0,
                                         src + (size_t)i * bsize, bsize);
    }
    run_meter_record(*blocks, bsize);
    *blocks = 0;
    return r;
}

/*
 * Give back whatever an inode holds past end-of-file.
 *
 * No transaction of its own: every caller already has one open, and the
 * trim has to land or not land with the operation that prompted it. Not an
 * error on an indirect-mapped inode -- ext2 and ext3 never reserve, because
 * the append path there hands back one block at a time whatever it is asked
 * for, so there is nothing to return.
 */
static int trim_alloc_to_size(struct ext4_fs *fs, uint32_t inode)
{
    struct ext4_inode_ref ref;
    int r = ext4_fs_get_inode_ref(fs, inode, &ref);
    if (r != EOK)
        return r;

    if (!ext4_inode_has_flag(ref.inode, EXT4_INODE_FLAG_EXTENTS)) {
        ext4_fs_put_inode_ref(&ref);
        return EOK;
    }

    /* Never touch an inode that has been freed. The table is cleared at every
     * path that deletes one, so this should be unreachable -- and it is the
     * guard that matters most, because removing space from a freed inode
     * would hand its blocks back a second time. Belt as well as braces. */
    if (ext4_inode_get_links_cnt(ref.inode) == 0 &&
        ext4_inode_get_del_time(ref.inode) != 0) {
        ext4_fs_put_inode_ref(&ref);
        return EOK;
    }

    uint32_t bsize = ext4_sb_get_block_size(&fs->sb);
    uint64_t fsize = ext4_inode_get_size(&fs->sb, ref.inode);
    uint32_t keep  = (uint32_t)((fsize + bsize - 1) / bsize);

    r = ext4_extent_remove_space(&ref, keep, EXT_MAX_BLOCKS);
    if (r == EOK)
        ref.dirty = true;

    ext4_fs_put_inode_ref(&ref);
    return r;
}

/* Drop an inode from the table without returning anything, for callers that
 * are about to make the question moot: a truncate or an unlink has already
 * dealt with the blocks, and a preallocation means the space past EOF is now
 * the caller's on purpose and must not be taken away. */
static void resv_forget(ext4b_device *dev, uint32_t inode)
{
    for (unsigned i = 0; i < EXT4B_RESERVE_SLOTS; i++)
        if (dev->resv[i].inode == inode)
            dev->resv[i].inode = 0;
}

/* How far this inode's reservation reaches, or 0 if it holds none. Answering
 * from the table rather than from the extent tree is the point: walking the
 * tree to find the end of the allocation would cost a lookup per block on
 * every write, which is the cost this whole thing exists to avoid. */
static uint32_t resv_end(const ext4b_device *dev, uint32_t inode)
{
    for (unsigned i = 0; i < EXT4B_RESERVE_SLOTS; i++)
        if (dev->resv[i].inode == inode)
            return dev->resv[i].end_lblk;
    return 0;
}

/* Record how far this inode is now reserved, evicting the oldest entry if the
 * table is full. The eviction is what bounds the space in flight, so its
 * failure is reported rather than swallowed: a trim that silently did not
 * happen is a leak, and leaks are the failure mode this arrangement risks. */
static int resv_set(ext4b_device *dev, struct ext4_fs *fs,
                    uint32_t inode, uint32_t end_lblk)
{
    for (unsigned i = 0; i < EXT4B_RESERVE_SLOTS; i++) {
        if (dev->resv[i].inode == inode) {
            dev->resv[i].end_lblk = end_lblk;
            return EOK;
        }
    }
    for (unsigned i = 0; i < EXT4B_RESERVE_SLOTS; i++) {
        if (dev->resv[i].inode == 0) {
            dev->resv[i].inode = inode;
            dev->resv[i].end_lblk = end_lblk;
            return EOK;
        }
    }

    unsigned slot = dev->resv_next % EXT4B_RESERVE_SLOTS;
    dev->resv_next = slot + 1;
    uint32_t victim = dev->resv[slot].inode;
    dev->resv[slot].inode = inode;
    dev->resv[slot].end_lblk = end_lblk;
    return trim_alloc_to_size(fs, victim);
}

/* Everything still held, returned. Called where a volume stops accepting
 * writes: the reservations are an optimisation between one write and the
 * next, and nothing may outlive the mount that made them.
 *
 * Owns its transaction, unlike the trims above, because its one caller --
 * unmount -- sits above the transaction helpers and may have nothing open.
 * txn_begin joins an open batch rather than nesting, so this is correct
 * either way. Every slot is attempted even after one fails, and the first
 * error is the one reported: a volume half-drained is worse than a volume
 * that reports the problem. */
static int resv_release_all(ext4b_device *dev, struct ext4_fs *fs)
{
    int first_err = EOK;
    for (unsigned i = 0; i < EXT4B_RESERVE_SLOTS; i++) {
        uint32_t inode = dev->resv[i].inode;
        dev->resv[i].inode = 0;
        if (inode == 0)
            continue;
        int tr = trim_alloc_to_size(fs, inode);
        if (tr != EOK && first_err == EOK)
            first_err = tr;
    }
    return first_err;
}

static int resv_drain(ext4b_device *dev, struct ext4_fs *fs)
{
    int r = txn_begin(fs);
    if (r != EOK)
        return r;
    return txn_finish(dev, fs, resv_release_all(dev, fs));
}

int ext4b_write(ext4b_device *dev,
                uint32_t inode,
                uint64_t offset,
                const void *buf,
                size_t count,
                size_t *out_written)
{
    WRITE_PROLOGUE(dev, fs);
    if (!buf || !out_written)
        return EINVAL;

    *out_written = 0;
    if (count == 0)
        return EOK;

    int r = txn_begin(fs);
    if (r != EOK)
        return r;

    struct ext4_inode_ref ref;
    r = ext4_fs_get_inode_ref(fs, inode, &ref);
    if (r != EOK)
        return txn_finish(dev, fs, r);

    if (ext4_inode_is_type(&fs->sb, ref.inode, EXT4_INODE_MODE_DIRECTORY)) {
        ext4_fs_put_inode_ref(&ref);
        return txn_finish(dev, fs, EISDIR);
    }

    const uint32_t bsize = ext4_sb_get_block_size(&fs->sb);
    uint64_t fsize = ext4_inode_get_size(&fs->sb, ref.inode);

    /*
     * Refuse a write the address space cannot hold, BEFORE any of the loop
     * below runs. Two failures otherwise: the logical block number
     * (offset / bsize) is truncated to 32 bits, so an offset past bsize*2^32
     * wraps to a low block and overwrites live data; and even short of that,
     * the append-past-EOF loop walks out one block at a time, so a write at a
     * huge sparse offset spins through hundreds of millions of allocations
     * inside the volume's serial executor before it finally hits ENOSPC.
     * The ceiling is what the extent/indirect map can address: bsize * 2^32.
     */
    const uint64_t max_file_size = (uint64_t)bsize << 32;
    if (count > max_file_size || offset > max_file_size - count) {
        ext4_fs_put_inode_ref(&ref);
        return txn_finish(dev, fs, EFBIG);
    }

    /*
     * Append-only, at the level this layer can see it.
     *
     * The obvious rule -- the write must start exactly at end-of-file -- is
     * wrong here, and measurably so: through a real mount an append does not
     * arrive as a write at EOF. macOS's buffer cache rewrites whole pages, so
     * appending five bytes to a five-byte file arrives as a ten-byte write at
     * offset zero, and a strict check refuses it. The kernel does the real
     * enforcement anyway, and does it better than this layer could: with
     * UF_APPEND reported, open(2) for anything but O_APPEND fails with EPERM
     * before a byte reaches us.
     *
     * What is left worth checking is the case no cache produces: a write that
     * lies wholly inside the existing file and does not reach its end. That is
     * an overwrite by any reading, and it is refused.
     */
    if (is_immutable(&ref) ||
        (is_append_only(&ref) && offset + count < fsize)) {
        ext4_fs_put_inode_ref(&ref);
        return txn_finish(dev, fs, EPERM);
    }

    /* Blocks the file already has backing for. */
    uint32_t have_blocks = (uint32_t)((fsize + bsize - 1) / bsize);

    /*
     * Allocate ahead of this write, so the next one continues in the same
     * run rather than restarting after whichever file allocated in between.
     * See "Allocating ahead" at the top of this file for why that is the
     * thing worth fixing and what bounds it.
     *
     * The blocks are taken as unwritten, which is what preallocation means
     * everywhere else here: they read as zeros, so nothing is exposed if the
     * file is later grown over them, and the write path already has a tested
     * route through them -- it is the same one a Finder copy takes.
     *
     * Reservations are only extended, never re-walked. The table remembers
     * where each one reaches, so a write that lands inside it does no
     * allocation work at all; without that, every call would walk the
     * already-backed blocks one at a time looking for the end, which is the
     * cost this exists to avoid.
     */
    if (count >= (uint64_t)EXT4B_RESERVE_TRIGGER * bsize &&
        offset <= fsize && offset + count > fsize &&
        ext4_inode_has_flag(ref.inode, EXT4_INODE_FLAG_EXTENTS)) {
        /* `offset <= fsize` is not decoration. Without it, a sparse write at
         * a huge offset would ask for every block from end-of-file to there,
         * which is a terabyte of allocation for a one-megabyte write. This is
         * an append optimisation, and an append is what it applies to. */
        uint32_t reach = resv_end(dev, inode);
        if (reach == 0) {
            /*
             * Nothing of ours past this file's end -- so before taking any,
             * check that nothing of anyone else's is there either. Space
             * already allocated past end-of-file belongs to an explicit
             * preallocation, and extending it here would put it in the table
             * and trim it away later, undoing an fcntl the application was
             * told had succeeded. A Finder copy preallocates every file, so
             * this is the common case, not a corner.
             */
            ext4_fsblk_t at = 0;
            uint32_t run = 0;
            bool unwr = false;
            if (ext4_extent_map_range(&ref, have_blocks, 1, &at, &run,
                                      &unwr) == EOK && at != 0)
                goto no_reservation;
            reach = have_blocks;
        } else if (reach < have_blocks) {
            reach = have_blocks;
        }

        uint32_t through = (uint32_t)((offset + count + bsize - 1) / bsize);

        /* Not on a volume that is filling up: turning fragmented files into
         * fragmented free space is the worse trade, and a nearly full volume
         * is exactly where that bites. */
        uint64_t spare = ext4_sb_get_free_blocks_cnt(&fs->sb);
        if (spare <= (uint64_t)EXT4B_RESERVE_AHEAD * EXT4B_RESERVE_SLOTS * 4) {
            /*
             * Below the threshold, hold nothing. Stopping at "take no more"
             * is not enough: whatever is already held is blocks no file is
             * using, and the volume can then report itself full with them
             * still out. Measured on a 512 MB volume filled to ENOSPC one
             * file at a time -- 8 MiB less data fitted than on the same
             * volume without reservations, which is exactly one reservation
             * left holding when the threshold stopped the evictions that
             * would have returned it.
             */
            int dr = resv_release_all(dev, fs);
            if (dr != EOK) {
                ext4_fs_put_inode_ref(&ref);
                return txn_finish(dev, fs, dr);
            }
        } else if (through > reach) {
            uint32_t ask = (through - reach) + EXT4B_RESERVE_AHEAD;
            uint32_t alloc = 0;

            /* Best effort. A reservation that could not be taken -- no room,
             * a partial run -- is not a failed write; the append path below
             * allocates what it needs as it always did. But whatever WAS
             * taken has to be recorded, or it is a leak. */
            (void)ext4_extent_preallocate(&ref, reach, ask, &alloc);
            if (alloc > 0) {
                ref.dirty = true;
                int sr = resv_set(dev, fs, inode, reach + alloc);
                if (sr != EOK) {
                    /* An eviction that failed to give its blocks back. That
                     * is the one failure here worth stopping for. */
                    ext4_fs_put_inode_ref(&ref);
                    return txn_finish(dev, fs, sr);
                }
            }
        }
    }
no_reservation:
    ;

    const uint8_t *src = buf;
    size_t remaining = count;
    uint64_t pos = offset;

    /*
     * A run of physically contiguous whole blocks, written with one device
     * command.
     *
     * This loop used to issue one write per block: 25,600 commands for a
     * 100 MB file. A disk image hides that behind the page cache -- it
     * measured 57 MB/s -- while a USB stick charges a round trip for each
     * one, which is how a 100 MB copy in Finder came to look like a hang.
     * The blocks are almost always consecutive on disk, so the fix is to
     * notice: accumulate while the mapping stays contiguous and flush the
     * run in a single ext4_block_writebytes, which passes a multi-block
     * length straight to the device.
     *
     * Only whole blocks join a run. A partial head or tail is a
     * read-modify-write of one block and is issued on its own, as before.
     */
    ext4_fsblk_t run_first = 0;
    uint32_t run_blocks = 0;
    uint64_t run_bytes = 0;
    const uint8_t *run_src = NULL;

    /* Batch the block writes; the cache is flushed by txn_finish. */
    ext4_block_cache_write_back(&dev->bdev, 1);

    while (remaining > 0) {
        uint32_t lblk = (uint32_t)(pos / bsize);
        uint32_t in_off = (uint32_t)(pos % bsize);
        uint32_t chunk = bsize - in_off;
        if (chunk > remaining)
            chunk = (uint32_t)remaining;

        ext4_fsblk_t fblk = 0;

        /*
         * A whole-block write into space that is already allocated but still
         * unwritten -- which is every byte of a file macOS preallocated
         * before copying into it.
         *
         * Converting an unwritten extent zeroes it first, so that a reader
         * cannot see whatever those blocks held for their previous owner.
         * When the caller is about to overwrite every one of those bytes,
         * that doubles the writing: the whole range goes to the medium as
         * zeros and then again as data. On the stick this came from, a
         * 522 MB copy wrote 994 MB.
         *
         * The zeroing is not what makes it safe, though -- the ORDER is. So
         * take the same order the kernel does: write the data while the
         * extent is still unwritten, and mark it written only afterwards. A
         * crash in between leaves the extent unwritten, which reads back as
         * zeros, exposing nothing. The conversion is journalled metadata and
         * the commit barriers behind the data write, so the medium learns
         * the blocks are live only after it has their contents.
         */
        if (!EXT4B_NO_UNWRITTEN_FASTPATH && in_off == 0 && remaining >= bsize) {
            uint32_t want = (uint32_t)(remaining / bsize);
            uint32_t mapped = 0;
            bool is_unwritten = false;
            ext4_fsblk_t at = 0;

            if (ext4_extent_map_range(&ref, lblk, want, &at, &mapped,
                                      &is_unwritten) == EOK &&
                at != 0 && mapped > 0 && is_unwritten) {
                /* The accumulated run belongs to a different mapping and
                 * must land before this one is issued and declared live. */
                r = bridge_flush_run(&dev->bdev, bsize, run_first,
                                     &run_blocks, run_src);
                if (r != EOK)
                    break;
                *out_written += run_bytes;
                run_bytes = 0;

                uint32_t n = mapped * bsize;
                r = ext4_block_writebytes(&dev->bdev,
                                          (uint64_t)at * bsize, src, n);
                if (r == EOK) {
                    for (uint32_t i = 0; i < mapped; i++)
                        ext4_bcache_update_if_cached(dev->bdev.bc, at + i, 0,
                                                     src + (size_t)i * bsize,
                                                     bsize);
                }
                run_meter_record(mapped, bsize);
                if (r != EOK)
                    break;

                /* Only now is the range allowed to read back as data. */
                r = ext4_extent_mark_written(&ref, lblk, mapped);
                if (r != EOK)
                    break;

                *out_written += n;
                src       += n;
                pos       += n;
                remaining -= n;
                if (have_blocks < lblk + mapped)
                    have_blocks = lblk + mapped;
                continue;
            }
        }

        /*
         * have_blocks comes from the file SIZE, and preallocated space lives
         * past i_size -- F_PREALLOCATE reserves blocks without growing the
         * file. So a block that macOS reserved is invisible here, and the
         * trailing partial block of a preallocated write was classified as
         * past-the-end and appended instead of mapped: the tail landed
         * somewhere else entirely and its own blocks stayed unwritten, which
         * reads back as zeros. Whole blocks escaped this because the fast
         * path above maps them itself; only the tail fell through.
         *
         * Ask the extent map before concluding a block is past the end.
         */
        bool     already_mapped = false;
        bool     tail_unwritten = false;
        ext4_fsblk_t mapped_at  = 0;
        if (lblk >= have_blocks &&
            ext4_inode_has_flag(ref.inode, EXT4_INODE_FLAG_EXTENTS)) {
            uint32_t n_lb = 0;
            bool     unwr = false;
            if (ext4_extent_map_range(&ref, lblk, 1, &mapped_at, &n_lb,
                                      &unwr) == EOK && mapped_at != 0 &&
                n_lb > 0) {
                already_mapped = true;
                tail_unwritten = unwr;
            }
        }

        if (already_mapped) {
            /* The extent map already named the block. Not through
             * init_inode_dblk_idx: that reports an unwritten extent as a hole
             * and hands back 0, which the guard below turns into EIO -- so the
             * tail was dropped and the file came back short. */
            fblk = mapped_at;
        } else if (lblk < have_blocks) {
            /* Within the allocated range: map, allocating if it is a hole. */
            r = ext4_fs_init_inode_dblk_idx(&ref, lblk, &fblk);
        } else {
            /*
             * Past the end. append_inode_dblk only ever adds at the current
             * end, so walk out to lblk one block at a time. Intermediate
             * blocks are left unwritten, which is what makes a sparse write
             * past EOF read back as zeroes.
             */
            while (have_blocks <= lblk) {
                uint32_t appended = 0;
                uint32_t got = 0;
                /* At the block this write actually needs, ask for the whole
                 * rest of it. One mapping call then covers the run: the
                 * blocks come from one allocation, and if they were
                 * preallocated -- which is what macOS does before a large
                 * copy -- the unwritten extent is converted, and zeroed, in
                 * one step instead of one command per block. Blocks being
                 * walked over to reach a sparse offset still go one at a
                 * time; they are holes, and nothing is written to them. */
                uint32_t want = 1;
                if (have_blocks == lblk) {
                    uint64_t need = (remaining + bsize - 1) / bsize;
                    if (need > UINT32_MAX)
                        need = UINT32_MAX;
                    if (need > 1)
                        want = (uint32_t)need;
                }
                r = ext4_fs_append_inode_dblk_range(&ref, &fblk, &appended,
                                                    want, &got);
                if (r != EOK)
                    break;
                have_blocks += got;
            }
        }
        if (r != EOK)
            break;

        if (fblk == 0) {
            r = EIO;
            break;
        }

        if (in_off == 0 && chunk == bsize) {
            /* Whole block: extend the run, or start a new one. */
            if (run_blocks && fblk == run_first + run_blocks) {
                run_blocks++;
                run_bytes += chunk;
            } else {
                r = bridge_flush_run(&dev->bdev, bsize, run_first,
                                     &run_blocks, run_src);
                if (r != EOK)
                    break;
                *out_written += run_bytes;
                run_bytes = chunk;
                run_first  = fblk;
                run_blocks = 1;
                run_src    = src;
            }
        } else {
            /* Partial block: flush what is pending, then write this one. */
            r = bridge_flush_run(&dev->bdev, bsize, run_first,
                                 &run_blocks, run_src);
            if (r != EOK)
                break;
            *out_written += run_bytes;
            run_bytes = 0;

            if (tail_unwritten) {
                /*
                 * Allocated but unwritten -- preallocated space. There is
                 * nothing on the medium to merge with: an unwritten extent
                 * reads as zeros whatever its blocks hold. So compose the
                 * whole block, zeros plus this chunk, write it, and mark it
                 * written only afterwards. Marking first would publish
                 * whatever the blocks held for their previous owner, and
                 * writing only the chunk would leave the rest of the block
                 * holding it.
                 */
                uint8_t *whole = calloc(1, bsize);
                if (!whole) {
                    r = ENOMEM;
                    break;
                }
                memcpy(whole + in_off, src, chunk);
                r = ext4_block_writebytes(&dev->bdev,
                                          (uint64_t)fblk * bsize, whole,
                                          bsize);
                if (r == EOK)
                    ext4_bcache_update_if_cached(dev->bdev.bc, fblk, 0,
                                                 whole, bsize);
                free(whole);
                if (r != EOK)
                    break;
                r = ext4_extent_mark_written(&ref, lblk, 1);
                if (r != EOK)
                    break;
            } else {
                r = ext4_block_writebytes(&dev->bdev,
                                          (uint64_t)fblk * bsize + in_off,
                                          src, chunk);
                if (r != EOK)
                    break;
                ext4_bcache_update_if_cached(dev->bdev.bc, fblk, in_off, src,
                                             chunk);
            }
            *out_written += chunk;
        }

        src        += chunk;
        pos        += chunk;
        remaining  -= chunk;
    }

    /* Whatever the loop still holds. A run counts as written only once its
     * command has been issued, so a failure here leaves those bytes out of
     * the count rather than reporting data the device never saw. */
    {
        int run_r = bridge_flush_run(&dev->bdev, bsize, run_first,
                                     &run_blocks, run_src);
        if (run_r == EOK)
            *out_written += run_bytes;
        else if (r == EOK)
            r = run_r;
    }

    /* Leaving write-back mode is what issues the queued metadata writes; a
     * discarded failure here meant blocks the caller was told about never
     * landed. */
    int flush_r = ext4_block_cache_write_back(&dev->bdev, 0);

    /* Growing the file is only visible once i_size says so -- and only as far
     * as the bytes that actually landed, which is no longer the same as how
     * far the loop walked now that a run can fail after its blocks were
     * mapped. */
    if (*out_written > 0) {
        uint64_t end = offset + *out_written;
        if (end > fsize)
            ext4_inode_set_size(ref.inode, end);
        touch(fs, &ref, TOUCH_MTIME | TOUCH_CTIME);
        ref.dirty = true;
    }

    /* A partial write that made progress is still a success; the caller sees
     * how far it got. Report an error only when nothing was written -- that
     * is POSIX's short write, and ENOSPC mid-loop is its ordinary cause. A
     * failed flush is different: it invalidates the count already reported,
     * so it wins over the short-write rule. */
    if (*out_written > 0)
        r = EOK;
    if (flush_r != EOK)
        r = flush_r;

    ext4_fs_put_inode_ref(&ref);
    return txn_finish(dev, fs, r);
}

/* Zero what a grow would otherwise expose.
 *
 * "Growing leaves a hole" is true only where nothing is allocated. Blocks
 * past i_size routinely are: an append asks the extent layer for a run and
 * gets whole blocks, the write fills part of the last one, and i_size comes
 * back down to the bytes actually written -- leaving the tail of that block,
 * and any blocks the run allocated beyond it, mapped and holding whatever
 * their previous owner left there. Moving i_size back up over them publishes
 * it. Measured: write a file of a recognisable pattern, delete it, write
 * 5000 bytes to a new file and truncate that to 8192, and the deleted file's
 * bytes are readable at offsets 5000..8191.
 *
 * So the newly-covered range is zeroed wherever it is backed. Holes are left
 * alone -- they read as zeros already -- and the walk stops at the first one,
 * which is what keeps a grow to a huge size from touching a million
 * mappings: allocation past EOF is contiguous with the tail. */
static int zero_exposed_range(ext4b_device *dev, struct ext4_fs *fs,
                              struct ext4_inode_ref *ref,
                              uint64_t from, uint64_t to)
{
    const uint32_t bsize = ext4_sb_get_block_size(&fs->sb);
    uint8_t *zeros = ext4_calloc(1, bsize);
    if (!zeros)
        return ENOMEM;

    int r = EOK;
    uint64_t pos = from;
    while (pos < to) {
        uint32_t lblk = (uint32_t)(pos / bsize);
        uint32_t in_off = (uint32_t)(pos % bsize);
        uint32_t chunk = bsize - in_off;
        if (chunk > to - pos)
            chunk = (uint32_t)(to - pos);

        ext4_fsblk_t fblk = 0;
        uint32_t mapped = 0;
        bool unwritten = false;

        if (ext4_inode_has_flag(ref->inode, EXT4_INODE_FLAG_EXTENTS)) {
            uint32_t want = (uint32_t)((to - pos + bsize - 1) / bsize);
            r = ext4_extent_map_range(ref, lblk, want, &fblk, &mapped,
                                      &unwritten);
            if (r != EOK)
                break;
        } else {
            r = ext4_fs_get_inode_dblk_idx(ref, lblk, &fblk, true);
            if (r != EOK)
                break;
            mapped = fblk ? 1 : 0;
        }

        /* A hole, or an unwritten extent: both already read as zeros, and
         * nothing after a hole can be backed by this file's allocation. */
        if (fblk == 0 || mapped == 0 || unwritten)
            break;

        for (uint32_t i = 0; i < mapped && pos < to; i++) {
            uint32_t off = (i == 0) ? in_off : 0;
            uint32_t n = bsize - off;
            if (n > to - pos)
                n = (uint32_t)(to - pos);

            r = ext4_block_writebytes(&dev->bdev,
                                      (uint64_t)(fblk + i) * bsize + off,
                                      zeros, n);
            if (r != EOK)
                goto out;
            ext4_bcache_update_if_cached(dev->bdev.bc, fblk + i, off, zeros, n);
            pos += n;
        }
    }

out:
    ext4_free(zeros);
    return r;
}

int ext4b_truncate(ext4b_device *dev, uint32_t inode, uint64_t new_size)
{
    WRITE_PROLOGUE(dev, fs);

    /* A truncate settles this inode's blocks itself, and a shrink frees the
     * very ones a reservation was pointing at. Anything the table still
     * believes about it is stale from here. */
    resv_forget(dev, inode);

    int r = txn_begin(fs);
    if (r != EOK)
        return r;

    struct ext4_inode_ref ref;
    r = ext4_fs_get_inode_ref(fs, inode, &ref);
    if (r != EOK)
        return txn_finish(dev, fs, r);

    if (ext4_inode_is_type(&fs->sb, ref.inode, EXT4_INODE_MODE_DIRECTORY)) {
        ext4_fs_put_inode_ref(&ref);
        return txn_finish(dev, fs, EISDIR);
    }

    if (is_immutable(&ref) || is_append_only(&ref)) {
        ext4_fs_put_inode_ref(&ref);
        return txn_finish(dev, fs, EPERM);
    }

    uint64_t old_size = ext4_inode_get_size(&fs->sb, ref.inode);

    if (new_size < old_size) {
        r = ext4_fs_truncate_inode(&ref, new_size);
    } else if (new_size > old_size) {
        /* Only a hole reads back as zeroes; anything already allocated past
         * i_size holds its previous owner's bytes until this clears them. */
        r = zero_exposed_range(dev, fs, &ref, old_size, new_size);
        if (r == EOK) {
            ext4_inode_set_size(ref.inode, new_size);
            ref.dirty = true;
        }
    }

    if (r == EOK && new_size != old_size)
        touch(fs, &ref, TOUCH_MTIME | TOUCH_CTIME);

    ext4_fs_put_inode_ref(&ref);
    return txn_finish(dev, fs, r);
}

int ext4b_preallocate(ext4b_device *dev,
                      uint32_t inode,
                      uint64_t offset,
                      uint64_t length,
                      uint64_t *out_allocated)
{
    WRITE_PROLOGUE(dev, fs);

    if (out_allocated)
        *out_allocated = 0;
    if (length == 0)
        return EOK;

    /* From here the space past EOF is the caller's on purpose, and an
     * eviction that trimmed it would silently undo an fcntl the application
     * was told had succeeded. The write path's own reservation, if any, is
     * subsumed by what is about to be allocated. */
    resv_forget(dev, inode);

    int r = txn_begin(fs);
    if (r != EOK)
        return r;

    struct ext4_inode_ref ref;
    r = ext4_fs_get_inode_ref(fs, inode, &ref);
    if (r != EOK)
        return txn_finish(dev, fs, r);

    if (ext4_inode_is_type(&fs->sb, ref.inode, EXT4_INODE_MODE_DIRECTORY)) {
        ext4_fs_put_inode_ref(&ref);
        return txn_finish(dev, fs, EISDIR);
    }
    if (is_immutable(&ref) || is_append_only(&ref)) {
        ext4_fs_put_inode_ref(&ref);
        return txn_finish(dev, fs, EPERM);
    }
    /* Unwritten extents are an extent-tree concept; an ext2/3 indirect file
     * has nowhere to record "allocated but not written", and the honest
     * answer is the one every filesystem without the feature gives. */
    if (!ext4_inode_has_flag(ref.inode, EXT4_INODE_FLAG_EXTENTS)) {
        ext4_fs_put_inode_ref(&ref);
        return txn_finish(dev, fs, ENOTSUP);
    }

    uint32_t bsize = ext4_sb_get_block_size(&fs->sb);
    uint64_t first = offset / bsize;
    uint64_t last  = (offset + length - 1) / bsize;
    if (last >= UINT32_MAX) {
        ext4_fs_put_inode_ref(&ref);
        return txn_finish(dev, fs, EFBIG);
    }

    uint32_t got = 0;
    r = ext4_extent_preallocate(&ref, (uint32_t)first,
                                (uint32_t)(last - first + 1), &got);
    /* The size does not move: that is the entire point. i_blocks moved with
     * every allocation (ext4_balloc maintains it), which is what getattr's
     * alloc_size reports and what makes the space visible. */
    if (got)
        ref.dirty = true;

    if (out_allocated)
        *out_allocated = (uint64_t)got * bsize;

    ext4_fs_put_inode_ref(&ref);
    return txn_finish(dev, fs, r);
}

/* Drop preallocated space past EOF -- the trim half of preallocation.
 * FSKit's contract: space preallocated without the persist flag is released
 * when the item deactivates. Everything past the size-derived block count is
 * unwritten preallocation by construction (writes always extend the size),
 * so removing from there to the end of the tree is exactly the trim. */
int ext4b_trim_preallocation(ext4b_device *dev, uint32_t inode)
{
    WRITE_PROLOGUE(dev, fs);

    int r = txn_begin(fs);
    if (r != EOK)
        return r;

    /* Whatever the write path was holding for this inode is going back in the
     * same call, so the table must not keep pointing at it -- a later
     * eviction would then trim an inode that had legitimately been given
     * space past EOF since. */
    resv_forget(dev, inode);

    return txn_finish(dev, fs, trim_alloc_to_size(fs, inode));
}

int ext4b_setattr(ext4b_device *dev,
                  uint32_t inode,
                  ext4b_setattr_mask mask,
                  const ext4b_attrs *attrs)
{
    WRITE_PROLOGUE(dev, fs);
    if (!attrs)
        return EINVAL;

    /* Resizing reallocates blocks, so route it through the truncate path
     * rather than duplicating that logic here. */
    if (mask & EXT4B_SET_SIZE) {
        int tr = ext4b_truncate(dev, inode, attrs->size);
        if (tr != EOK)
            return tr;
        mask &= ~EXT4B_SET_SIZE;
        if (mask == 0)
            return EOK;
    }

    int r = txn_begin(fs);
    if (r != EOK)
        return r;

    struct ext4_inode_ref ref;
    r = ext4_fs_get_inode_ref(fs, inode, &ref);
    if (r != EOK)
        return txn_finish(dev, fs, r);

    /* Append-only leaves attributes alone -- only the size is protected, and
     * that went through ext4b_truncate above. Immutable means what it says. */
    if (is_immutable(&ref)) {
        ext4_fs_put_inode_ref(&ref);
        return txn_finish(dev, fs, EPERM);
    }

    if (mask & EXT4B_SET_MODE) {
        uint32_t m = ext4_inode_get_mode(&fs->sb, ref.inode);
        m = (m & EXT4_INODE_MODE_TYPE_MASK) | (attrs->mode & 0x0FFF);
        ext4_inode_set_mode(&fs->sb, ref.inode, m);
    }
    if (mask & EXT4B_SET_UID)   ext4_inode_set_uid(ref.inode, attrs->uid);
    if (mask & EXT4B_SET_GID)   ext4_inode_set_gid(ref.inode, attrs->gid);
    if (mask & EXT4B_SET_ATIME) ext4_inode_set_access_time(ref.inode, (uint32_t)attrs->atime);
    if (mask & EXT4B_SET_MTIME) ext4_inode_set_modif_time(ref.inode, (uint32_t)attrs->mtime);

    /* Any attribute change updates ctime, by definition. */
    touch(fs, &ref, TOUCH_CTIME);
    ref.dirty = true;

    ext4_fs_put_inode_ref(&ref);
    return txn_finish(dev, fs, EOK);
}

/* ----------------------------------------------------------- xattr write -- */


int ext4b_setxattr(ext4b_device *dev, uint32_t inode,
                   const char *name,
                   const void *value, size_t value_len)
{
    WRITE_PROLOGUE(dev, fs);
    if (!name)
        return EINVAL;

    uint8_t name_index = 0;
    size_t  short_len  = 0;
    const char *short_name = xattr_split(name, &name_index, &short_len);

    int r = txn_begin(fs);
    if (r != EOK)
        return r;

    struct ext4_inode_ref ref;
    r = ext4_fs_get_inode_ref(fs, inode, &ref);
    if (r != EOK)
        return txn_finish(dev, fs, r);

    /* Linux refuses xattr changes on both, not just immutable: an append-only
     * file whose metadata can be rewritten is not append-only. */
    if (is_immutable(&ref) || is_append_only(&ref)) {
        ext4_fs_put_inode_ref(&ref);
        return txn_finish(dev, fs, EPERM);
    }

    r = ext4_xattr_set(&ref, name_index, short_name, short_len, value, value_len);
    if (r == EOK)
        touch(fs, &ref, TOUCH_CTIME);

    ext4_fs_put_inode_ref(&ref);
    return txn_finish(dev, fs, r);
}

int ext4b_removexattr(ext4b_device *dev, uint32_t inode, const char *name)
{
    WRITE_PROLOGUE(dev, fs);
    if (!name)
        return EINVAL;

    uint8_t name_index = 0;
    size_t  short_len  = 0;
    const char *short_name = xattr_split(name, &name_index, &short_len);

    int r = txn_begin(fs);
    if (r != EOK)
        return r;

    struct ext4_inode_ref ref;
    r = ext4_fs_get_inode_ref(fs, inode, &ref);
    if (r != EOK)
        return txn_finish(dev, fs, r);

    if (is_immutable(&ref) || is_append_only(&ref)) {
        ext4_fs_put_inode_ref(&ref);
        return txn_finish(dev, fs, EPERM);
    }

    r = ext4_xattr_remove(&ref, name_index, short_name, short_len);
    if (r == EOK)
        touch(fs, &ref, TOUCH_CTIME);

    ext4_fs_put_inode_ref(&ref);
    return xattr_errno(txn_finish(dev, fs, r));
}
