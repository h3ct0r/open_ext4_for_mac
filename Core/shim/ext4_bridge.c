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
    if (info.needs_recovery && !read_only) {
        bridge_log(3, "volume needs journal recovery; refusing read-write "
                      "mount until ext4b_journal_recover() succeeds");
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
    bool    found      = false;
    const char *short_name =
        ext4_extract_xattr_name(name, strlen(name), &name_index, &name_len, &found);
    if (!found) {
        ext4_fs_put_inode_ref(&ref);
        return ENODATA;
    }

    r = ext4_xattr_get(&ref, name_index, short_name, name_len,
                       buf, buf_size, out_len);
    ext4_fs_put_inode_ref(&ref);
    return r;
}
