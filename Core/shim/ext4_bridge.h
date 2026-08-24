/*
 * ext4_bridge.h — thin C bridge between lwext4 and the Swift FSKit module.
 *
 * Copyright (C) 2026 open_ext4_for_mac contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Design notes
 * ------------
 * 1. INODE-ORIENTED, NOT PATH-ORIENTED.
 *    FSKit addresses objects by inode ("look up name N in directory item D"),
 *    while lwext4's *public* API (ext4_fopen etc.) is path-oriented. Building on
 *    the path API would force us to cache a full path per FSItem, which breaks on
 *    hard links (an inode has many paths) and on directory rename (every
 *    descendant path silently goes stale). We therefore build on lwext4's
 *    inode-reference layer (ext4_fs_get_inode_ref, ext4_dir_find_entry, ...),
 *    which maps 1:1 onto FSKit's model.
 *
 * 2. CALLBACK-DRIVEN BLOCK I/O.
 *    The caller supplies read/write callbacks rather than us calling FSKit
 *    directly. In production Swift routes them to FSBlockDeviceResource; in tests
 *    they are backed by a plain file. This lets the entire ext4 core be validated
 *    with no code signing, no entitlement, and no mounting.
 *
 * 3. NOT THREAD SAFE.
 *    lwext4 keeps global mount-point state and its block cache has no internal
 *    locking. Every entry point here must be called from a single serial
 *    execution context. Swift enforces this via Ext4Executor.
 */

#ifndef EXT4_BRIDGE_H
#define EXT4_BRIDGE_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---------------------------------------------------------------- errors -- */

/* Bridge calls return 0 on success, or a positive errno value. lwext4 already
 * speaks errno, so these pass through largely unchanged. */
#define EXT4B_OK 0

/* ----------------------------------------------------------------- device -- */

/* Read `count` bytes at byte `offset`. Return 0 on success or an errno. */
typedef int (*ext4b_read_fn)(void *ctx, void *buf, uint64_t offset, size_t count);

/* Write `count` bytes at byte `offset`. Return 0 on success or an errno. */
typedef int (*ext4b_write_fn)(void *ctx, const void *buf, uint64_t offset, size_t count);

/* Flush any buffered writes to stable storage. Return 0 or an errno.
 * This is the journal barrier; correctness of the write path depends on it
 * genuinely reaching the medium. */
typedef int (*ext4b_flush_fn)(void *ctx);

typedef struct ext4b_device ext4b_device;

/*
 * Create a block device backed by the supplied callbacks.
 *
 *  ctx          opaque pointer handed back to every callback
 *  block_size   physical block size in bytes (512, 4096, ...)
 *  block_count  number of physical blocks
 *  read_only    if true, write callbacks are never invoked
 *
 * Returns NULL on allocation failure.
 */
ext4b_device *ext4b_device_create(void *ctx,
                                  uint32_t block_size,
                                  uint64_t block_count,
                                  bool read_only,
                                  ext4b_read_fn read_fn,
                                  ext4b_write_fn write_fn,
                                  ext4b_flush_fn flush_fn);

void ext4b_device_destroy(ext4b_device *dev);

/* ------------------------------------------------------------------ probe -- */

/* Feature-support verdict for a candidate volume. */
typedef enum {
    EXT4B_PROBE_NOT_EXT = 0,   /* not an ext2/3/4 superblock            */
    EXT4B_PROBE_USABLE,        /* fully supported                       */
    EXT4B_PROBE_READ_ONLY,     /* mountable, but must not be written    */
    EXT4B_PROBE_UNSUPPORTED,   /* recognised as ext, but cannot be used */
} ext4b_probe_verdict;

typedef struct {
    ext4b_probe_verdict verdict;
    char     label[17];        /* NUL-terminated volume label            */
    uint8_t  uuid[16];
    uint32_t block_size;
    uint64_t block_count;
    uint64_t free_blocks;
    uint32_t inode_count;
    uint32_t free_inodes;
    uint32_t feature_incompat;
    uint32_t feature_ro_compat;
    uint32_t feature_compat;
    bool     has_journal;
    bool     needs_recovery;
    int      generation;       /* 2, 3 or 4 — which ext generation       */
    char     unsupported[128]; /* human-readable reason, when applicable */
} ext4b_probe_info;

/*
 * Inspect the superblock without mounting. Safe on untrusted media: performs
 * bounds and sanity checks and never writes.
 */
int ext4b_probe(ext4b_device *dev, ext4b_probe_info *out);

/* ------------------------------------------------------------------ mount -- */

int  ext4b_mount(ext4b_device *dev, bool read_only);
int  ext4b_unmount(ext4b_device *dev);

/* Replay the JBD2 journal. Must be called before a read-write mount of a
 * volume whose superblock has needs_recovery set. */
int  ext4b_journal_recover(ext4b_device *dev);

/* Bracket a set of metadata mutations in a journal transaction. */
int  ext4b_journal_start(ext4b_device *dev);
int  ext4b_journal_stop(ext4b_device *dev);

/* Flush the block cache and issue the device-level barrier. */
int  ext4b_sync(ext4b_device *dev);

typedef struct {
    uint64_t total_blocks;
    uint64_t free_blocks;
    uint64_t avail_blocks;
    uint32_t block_size;
    uint32_t total_inodes;
    uint32_t free_inodes;
} ext4b_statfs_info;

int ext4b_statfs(ext4b_device *dev, ext4b_statfs_info *out);

/* ------------------------------------------------------------------ inode -- */

#define EXT4B_ROOT_INO 2

typedef enum {
    EXT4B_TYPE_UNKNOWN = 0,
    EXT4B_TYPE_FILE,
    EXT4B_TYPE_DIR,
    EXT4B_TYPE_SYMLINK,
    EXT4B_TYPE_FIFO,
    EXT4B_TYPE_CHARDEV,
    EXT4B_TYPE_BLOCKDEV,
    EXT4B_TYPE_SOCKET,
} ext4b_item_type;

typedef struct {
    uint32_t inode;
    ext4b_item_type type;
    uint32_t mode;          /* POSIX permission bits only               */
    uint32_t uid;
    uint32_t gid;
    uint32_t link_count;
    uint64_t size;
    uint64_t alloc_size;    /* bytes actually allocated on disk         */
    uint32_t flags;         /* ext4 inode flags (EXT4_INODE_FLAG_*)     */
    int64_t  atime, mtime, ctime, crtime;   /* seconds since epoch      */
    uint32_t atime_ns, mtime_ns, ctime_ns, crtime_ns;
    bool     uses_extents;  /* false ⇒ indirect blocks (ext2/3 layout)  */
    bool     inline_data;   /* data stored inside the inode itself      */
} ext4b_attrs;

int ext4b_getattr(ext4b_device *dev, uint32_t inode, ext4b_attrs *out);

/* -------------------------------------------------------------- directory -- */

/* Look up `name` inside directory inode `dir_inode`.
 * Returns ENOENT when absent. `name` need not be NUL-terminated; `name_len`
 * is authoritative. */
int ext4b_lookup(ext4b_device *dev,
                 uint32_t dir_inode,
                 const char *name, size_t name_len,
                 uint32_t *out_inode,
                 ext4b_item_type *out_type);

/* Directory enumeration. `cookie` is an opaque resume position; pass 0 to
 * start. On return `*cookie` is the position to resume from.
 * The callback returns true to continue, false to stop early. */
typedef bool (*ext4b_dirent_fn)(void *ctx,
                                const char *name, size_t name_len,
                                uint32_t inode,
                                ext4b_item_type type,
                                uint64_t next_cookie);

int ext4b_readdir(ext4b_device *dev,
                  uint32_t dir_inode,
                  uint64_t cookie,
                  ext4b_dirent_fn cb,
                  void *cb_ctx);

/* ------------------------------------------------------------------- data -- */

/* Read file data. Reads past EOF are not an error; *out_read is set to 0. */
int ext4b_read(ext4b_device *dev,
               uint32_t inode,
               uint64_t offset,
               void *buf,
               size_t count,
               size_t *out_read);

/* Read a symlink target into `buf`. */
int ext4b_readlink(ext4b_device *dev,
                   uint32_t inode,
                   char *buf, size_t buf_size,
                   size_t *out_len);

/* ---------------------------------------------------------------- extents -- */

/*
 * Logical→physical mapping, the primitive behind FSKit's kernel-offloaded I/O
 * (FSVolumeKernelOffloadedIOOperations.blockmapFile). Filling FSExtentPacker
 * from these lets the kernel move file data with no XPC round-trip.
 */
typedef struct {
    uint64_t logical_offset;   /* byte offset within the file  */
    uint64_t physical_offset;  /* byte offset on the device    */
    uint64_t length;           /* bytes                        */
    bool     is_hole;          /* sparse — kernel substitutes zeroes */
} ext4b_extent;

/*
 * Map the byte range [offset, offset+length) of `inode` into at most
 * `max_extents` entries. *out_count receives the number filled.
 * Adjacent physical runs are coalesced.
 */
int ext4b_map_extents(ext4b_device *dev,
                      uint32_t inode,
                      uint64_t offset,
                      uint64_t length,
                      ext4b_extent *out,
                      size_t max_extents,
                      size_t *out_count);

/* ------------------------------------------------------------------ xattr -- */

typedef bool (*ext4b_xattr_fn)(void *ctx, const char *name, size_t name_len);

int ext4b_listxattr(ext4b_device *dev, uint32_t inode,
                    ext4b_xattr_fn cb, void *cb_ctx);

int ext4b_getxattr(ext4b_device *dev, uint32_t inode,
                   const char *name,
                   void *buf, size_t buf_size, size_t *out_len);

/* --------------------------------------------------------------- logging -- */

typedef void (*ext4b_log_fn)(void *ctx, int level, const char *message);

/* Route lwext4's internal diagnostics to os_log instead of stdout. */
void ext4b_set_logger(ext4b_log_fn fn, void *ctx);

/* Human-readable description of a bridge/errno code. */
const char *ext4b_strerror(int err);

#ifdef __cplusplus
}
#endif

#endif /* EXT4_BRIDGE_H */
