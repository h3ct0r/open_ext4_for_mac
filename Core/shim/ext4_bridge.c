/*
 * ext4_bridge.c — lwext4 ⇄ FSKit bridge implementation.
 *
 * Copyright (C) 2026 open_ext4_for_mac contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "ext4_bridge.h"

#include <ext4.h>
#include <ext4_fs.h>
#include <ext4_dir.h>
#include <ext4_inode.h>
#include <ext4_super.h>
#include <ext4_extent.h>
#include <ext4_blockdev.h>
#include <ext4_bcache.h>
#include <ext4_xattr.h>
#include <ext4_crc32.h>
#include <ext4_types.h>
#include <ext4_misc.h>
#include <ext4_errno.h>
#include <ext4_mkfs.h>

#include <stdlib.h>
#include <string.h>
#include <errno.h>

/* One volume per extension instance (FSUnaryFileSystem), so fixed names are
 * sufficient for lwext4's global device/mount-point tables. */
#define BRIDGE_DEV_NAME "ext4dev"
#define BRIDGE_MOUNT_POINT "/vol/"

/* Block cache entries. lwext4's default of 8 is sized for microcontrollers;
 * a desktop volume needs far more to avoid thrashing metadata reads. */
#define BRIDGE_BCACHE_BLOCKS 1024

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
    bool     bcache_ready;
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
    return dev->read_fn(dev->ctx, buf, off, len) == 0 ? EOK : EIO;
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
    return dev->write_fn(dev->ctx, buf, off, len) == 0 ? EOK : EIO;
}

static int bd_open(struct ext4_blockdev *bdev)   { (void)bdev; return EOK; }
static int bd_close(struct ext4_blockdev *bdev)  { (void)bdev; return EOK; }
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
    dev->read_only = read_only;

    dev->iface.open     = bd_open;
    dev->iface.bread    = bd_bread;
    dev->iface.bwrite   = bd_bwrite;
    dev->iface.close    = bd_close;
    dev->iface.lock     = bd_lock;
    dev->iface.unlock   = bd_unlock;
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

/* ================================================================ probe == */

/* Superblock field offsets, from the ext4 on-disk specification. Parsed by
 * hand rather than via lwext4 so that probing never mounts and never trusts
 * structure sizes on untrusted media. */
#define SB_OFFSET              1024
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

#define EXT_MAGIC 0xEF53

/*
 * Feature gate. Deliberately expressed as an allow-list: any bit we have not
 * explicitly vetted causes a refusal or a read-only downgrade. An unknown
 * INCOMPAT bit means the on-disk layout may differ in ways we cannot see, so
 * writing would risk corruption.
 */
#define INCOMPAT_SUPPORTED  (0x0002 /* FILETYPE  */ | \
                             0x0004 /* RECOVER   */ | \
                             0x0010 /* META_BG   */ | \
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

    /* Sanity: the volume must not claim to be larger than the device. */
    uint64_t fs_bytes = out->block_count * (uint64_t)out->block_size;
    uint64_t dev_bytes = dev->iface.ph_bcnt * (uint64_t)dev->iface.ph_bsize;
    if (out->block_count == 0 || fs_bytes > dev_bytes) {
        out->verdict = EXT4B_PROBE_UNSUPPORTED;
        snprintf(out->unsupported, sizeof(out->unsupported),
                 "superblock claims %llu blocks, larger than the device",
                 (unsigned long long)out->block_count);
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
     * rewriting every metadata checksum. lwext4 has no notion of this field --
     * its ext4_sblock struct does not even declare it -- and always derives the
     * seed from the UUID.
     *
     * mke2fs sets s_checksum_seed = crc32c(~0, uuid) at creation, so the two
     * agree until somebody changes the UUID. When they still agree, lwext4's
     * derived seed is correct and the volume is safe. When they diverge, every
     * checksum lwext4 computes would be wrong, so we refuse to write.
     */
    if (out->feature_incompat & 0x2000) {
        uint32_t stored  = rd32(sb, SBF_CHECKSUM_SEED);
        uint32_t derived = ext4_crc32c(EXT4_CRC32_INIT, out->uuid, 16);
        if (stored != derived) {
            out->verdict = EXT4B_PROBE_READ_ONLY;
            snprintf(out->unsupported, sizeof(out->unsupported),
                     "volume UUID was changed after creation "
                     "(csum seed %08x != derived %08x); writing is unsafe",
                     stored, derived);
            return EOK;
        }
    }

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
    if (dev->read_only)
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

/* ================================================================ mount == */

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
    if (r != EOK && r != EEXIST)
        return r;

    r = ext4_mount(BRIDGE_DEV_NAME, BRIDGE_MOUNT_POINT, read_only);
    if (r != EOK) {
        ext4_device_unregister(BRIDGE_DEV_NAME);
        return r;
    }

    dev->mounted   = true;
    dev->read_only = read_only || dev->read_only;

    if (!dev->read_only) {
        /*
         * Replay before touching anything. lwext4 lists RECOVER under
         * EXT_FINCOM_IGNORED, so ext4_mount() above will happily attach to a
         * volume with an unreplayed journal and let us write over it.
         */
        if (info.needs_recovery) {
            bridge_log(1, "replaying journal");
            r = ext4_recover(BRIDGE_MOUNT_POINT);
            if (r != EOK) {
                bridge_log(3, "journal recovery failed; refusing read-write mount");
                ext4_umount(BRIDGE_MOUNT_POINT);
                ext4_device_unregister(BRIDGE_DEV_NAME);
                dev->mounted = false;
                return r;
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
                bridge_log(3, "could not start journal; refusing read-write mount");
                ext4_umount(BRIDGE_MOUNT_POINT);
                ext4_device_unregister(BRIDGE_DEV_NAME);
                dev->mounted = false;
                return r;
            }
            dev->journal_running = true;
        }
    }

    return EOK;
}

int ext4b_unmount(ext4b_device *dev)
{
    if (!dev || !dev->mounted)
        return EINVAL;

    if (dev->journal_running) {
        ext4_journal_stop(BRIDGE_MOUNT_POINT);
        dev->journal_running = false;
    }

    int r = ext4_umount(BRIDGE_MOUNT_POINT);
    ext4_device_unregister(BRIDGE_DEV_NAME);
    dev->mounted = false;

    if (dev->flush_fn)
        dev->flush_fn(dev->ctx);
    return r;
}

int ext4b_journal_recover(ext4b_device *dev)
{
    if (!dev || !dev->mounted)
        return EINVAL;
    if (dev->read_only)
        return EROFS;

    int r = ext4_recover(BRIDGE_MOUNT_POINT);
    if (r == EOK && dev->flush_fn)
        dev->flush_fn(dev->ctx);
    return r;
}

int ext4b_journal_start(ext4b_device *dev)
{
    if (!dev || !dev->mounted)
        return EINVAL;
    if (dev->read_only)
        return EROFS;
    if (dev->journal_running)
        return EOK;

    int r = ext4_journal_start(BRIDGE_MOUNT_POINT);
    if (r == EOK)
        dev->journal_running = true;
    return r;
}

int ext4b_journal_stop(ext4b_device *dev)
{
    if (!dev || !dev->mounted)
        return EINVAL;
    if (!dev->journal_running)
        return EOK;

    int r = ext4_journal_stop(BRIDGE_MOUNT_POINT);
    dev->journal_running = false;
    return r;
}

int ext4b_sync(ext4b_device *dev)
{
    if (!dev || !dev->mounted)
        return EINVAL;

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
    out->avail_blocks = st.free_blocks_count;
    out->total_inodes = st.inodes_count;
    out->free_inodes  = st.free_inodes_count;
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
        if (nlen > 255)
            nlen = 255;

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

        if (fblk == 0) {
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
    return (*out_read > 0) ? EOK : r;
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
    if (offset >= fsize) {
        ext4_fs_put_inode_ref(&ref);
        return EOK;
    }
    if (offset + length > fsize)
        length = fsize - offset;

    uint32_t lblk     = (uint32_t)(offset / bsize);
    uint32_t end_lblk = (uint32_t)((offset + length - 1) / bsize);
    size_t   n        = 0;

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
        n++;

        lblk += run;
    }

    *out_count = n;
    ext4_fs_put_inode_ref(&ref);
    return (n > 0) ? EOK : r;
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
    return r;
}

/* ============================================================== writing == */

#include <ext4_balloc.h>
#include <ext4_ialloc.h>
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
    }
#endif
}

/* Close a mutation: commit on success, abort on failure, then push the
 * result to stable storage so a crash cannot lose an acknowledged change. */
static int txn_finish(ext4b_device *dev, struct ext4_fs *fs, int r)
{
    if (r != EOK) {
        txn_abort(fs);
        return r;
    }
    r = txn_commit(fs);
    if (r == EOK) {
        ext4_block_cache_flush(&dev->bdev);
        if (dev->flush_fn)
            dev->flush_fn(dev->ctx);
    }
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
    if (target_len > 4095)
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

    /* POSIX forbids hard links to directories: they would let a user create
     * cycles that fsck cannot untangle. */
    if (ext4_inode_is_type(&fs->sb, child.inode, EXT4_INODE_MODE_DIRECTORY)) {
        ext4_fs_put_inode_ref(&child);
        ext4_fs_put_inode_ref(&parent);
        return txn_finish(dev, fs, EPERM);
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

/* ---------------------------------------------------------------- unlink -- */

int ext4b_unlink(ext4b_device *dev,
                 uint32_t parent_inode,
                 const char *name, size_t name_len)
{
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

    r = unlink_child(fs, &parent, &child, name, (uint32_t)name_len);
    if (r != EOK) {
        ext4_fs_put_inode_ref(&child);
        ext4_fs_put_inode_ref(&parent);
        return txn_finish(dev, fs, r);
    }

    /* Last name gone: release the blocks and the inode itself. */
    if (ext4_inode_get_links_cnt(child.inode) == 0) {
        ext4_inode_set_del_time(child.inode, now_seconds());
        r = ext4_fs_truncate_inode(&child, 0);
        if (r == EOK)
            r = ext4_fs_free_inode(&child);
    }

    ext4_fs_put_inode_ref(&child);
    ext4_fs_put_inode_ref(&parent);
    return txn_finish(dev, fs, r);
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

            r = unlink_child(fs, &dp, &victim, dst_name, (uint32_t)dst_len);
            if (r == EOK && ext4_inode_get_links_cnt(victim.inode) == 0) {
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

    /* Blocks the file already has backing for. */
    uint32_t have_blocks = (uint32_t)((fsize + bsize - 1) / bsize);

    const uint8_t *src = buf;
    size_t remaining = count;
    uint64_t pos = offset;

    /* Batch the block writes; the cache is flushed by txn_finish. */
    ext4_block_cache_write_back(&dev->bdev, 1);

    while (remaining > 0) {
        uint32_t lblk = (uint32_t)(pos / bsize);
        uint32_t in_off = (uint32_t)(pos % bsize);
        uint32_t chunk = bsize - in_off;
        if (chunk > remaining)
            chunk = (uint32_t)remaining;

        ext4_fsblk_t fblk = 0;
        if (lblk < have_blocks) {
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
                r = ext4_fs_append_inode_dblk(&ref, &fblk, &appended);
                if (r != EOK)
                    break;
                have_blocks++;
            }
        }
        if (r != EOK)
            break;

        if (fblk == 0) {
            r = EIO;
            break;
        }

        r = ext4_block_writebytes(&dev->bdev,
                                  (uint64_t)fblk * bsize + in_off, src, chunk);
        if (r != EOK)
            break;

        src        += chunk;
        pos        += chunk;
        remaining  -= chunk;
        *out_written += chunk;
    }

    ext4_block_cache_write_back(&dev->bdev, 0);

    /* Growing the file is only visible once i_size says so. */
    if (*out_written > 0) {
        if (pos > fsize)
            ext4_inode_set_size(ref.inode, pos);
        touch(fs, &ref, TOUCH_MTIME | TOUCH_CTIME);
        ref.dirty = true;
    }

    /* A partial write that made progress is still a success; the caller sees
     * how far it got. Report an error only when nothing was written. */
    if (*out_written > 0)
        r = EOK;

    ext4_fs_put_inode_ref(&ref);
    return txn_finish(dev, fs, r);
}

int ext4b_truncate(ext4b_device *dev, uint32_t inode, uint64_t new_size)
{
    WRITE_PROLOGUE(dev, fs);

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

    uint64_t old_size = ext4_inode_get_size(&fs->sb, ref.inode);

    if (new_size < old_size) {
        r = ext4_fs_truncate_inode(&ref, new_size);
    } else if (new_size > old_size) {
        /* Growing leaves a hole: no blocks are allocated, and the region
         * reads back as zeroes. */
        ext4_inode_set_size(ref.inode, new_size);
        ref.dirty = true;
    }

    if (r == EOK && new_size != old_size)
        touch(fs, &ref, TOUCH_MTIME | TOUCH_CTIME);

    ext4_fs_put_inode_ref(&ref);
    return txn_finish(dev, fs, r);
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

    r = ext4_xattr_remove(&ref, name_index, short_name, short_len);
    if (r == EOK)
        touch(fs, &ref, TOUCH_CTIME);

    ext4_fs_put_inode_ref(&ref);
    return txn_finish(dev, fs, r);
}
