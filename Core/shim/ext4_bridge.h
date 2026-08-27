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

/* ----------------------------------------------------------------- format -- */

/*
 * Options for ext4b_format. Zero means "choose a sensible default" for every
 * numeric field, matching what mke2fs would pick.
 */
typedef struct {
    int      generation;      /* 2, 3 or 4 */
    uint32_t block_size;      /* 1024, 2048 or 4096; 0 = 4096 */
    uint32_t inode_size;      /* 0 = 256 */
    uint32_t inode_count;     /* 0 = computed from volume size */
    uint32_t journal_blocks;  /* 0 = computed; ignored when journal is false */
    bool     journal;         /* ext3/ext4 default true, ext2 must be false */
    const char *label;        /* volume name, may be NULL */
    /*
     * Volume UUID. Required: lwext4's mkfs copies this into the superblock
     * verbatim and never generates one, so leaving it zeroed would give every
     * formatted volume the same all-zero UUID -- which is what FSKit hands
     * back as the container identifier.
     */
    uint8_t  uuid[16];
} ext4b_format_options;

/*
 * Write a fresh filesystem over the device, destroying whatever was there.
 *
 * The device must not be mounted. On success the volume is left consistent and
 * unmounted; the caller is responsible for having established that overwriting
 * this device is what the user asked for.
 */
int ext4b_format(ext4b_device *dev, const ext4b_format_options *opts);

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

/*
 * Set the volume label. `label` is a NUL-terminated UTF-8 string of at most 16
 * bytes; ext4's field is fixed-width and zero-padded, with no terminator when
 * the name fills it. Requires a read-write mount.
 */
int  ext4b_set_label(ext4b_device *dev, const char *label);

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

/* The two ext4 inode flags this driver enforces, from `chattr +i` and
 * `chattr +a`. Named here because callers need to recognise them; the rest of
 * the flags word is passed through untouched. */
#define EXT4B_INODE_IMMUTABLE   0x00000010u
#define EXT4B_INODE_APPEND_ONLY 0x00000020u

typedef struct {
    uint32_t inode;
    ext4b_item_type type;
    uint32_t mode;          /* POSIX permission bits only               */
    uint32_t uid;
    uint32_t gid;
    uint32_t link_count;
    uint64_t size;
    uint64_t alloc_size;    /* bytes actually allocated on disk         */
    uint32_t flags;         /* ext4 inode flags (EXT4B_INODE_* below)   */
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


/* ============================================================== writing == */
/*
 * All mutations are inode-oriented: they take a parent directory inode plus a
 * name, which is exactly what FSKit provides. Each call is atomic -- it opens
 * a journal transaction, does its work, and commits, or aborts and leaves the
 * volume untouched.
 *
 * Every one of these returns EROFS unless the device was created writable AND
 * mounted read-write.
 *
 * A note on timestamps: lwext4 zeroes all inode times on allocation and leaves
 * updating them as a TODO ("when we have wall-clock time"), because it targets
 * microcontrollers. We do have a clock, so the bridge maintains atime/mtime/
 * ctime/crtime itself. Without this, Finder shows every file as created in
 * 1970 and never notices a directory changing.
 */

/// Attribute fields to change in ext4b_setattr.
typedef enum {
    EXT4B_SET_MODE  = 1 << 0,
    EXT4B_SET_UID   = 1 << 1,
    EXT4B_SET_GID   = 1 << 2,
    EXT4B_SET_SIZE  = 1 << 3,
    EXT4B_SET_ATIME = 1 << 4,
    EXT4B_SET_MTIME = 1 << 5,
} ext4b_setattr_mask;

/// Create a regular file, directory, FIFO or socket in `parent_inode`.
/// `mode` carries permission bits only; the type comes from `type`.
int ext4b_create(ext4b_device *dev,
                 uint32_t parent_inode,
                 const char *name, size_t name_len,
                 ext4b_item_type type,
                 uint32_t mode, uint32_t uid, uint32_t gid,
                 uint32_t *out_inode);

/// Create a symbolic link pointing at `target`.
int ext4b_symlink(ext4b_device *dev,
                  uint32_t parent_inode,
                  const char *name, size_t name_len,
                  const char *target, size_t target_len,
                  uint32_t uid, uint32_t gid,
                  uint32_t *out_inode);

/// Add another directory entry for an existing inode (a hard link).
int ext4b_hardlink(ext4b_device *dev,
                   uint32_t parent_inode,
                   const char *name, size_t name_len,
                   uint32_t target_inode);

/// Remove a name. Directories must already be empty; ENOTEMPTY otherwise.
/// The inode itself is freed once its last link goes away.
int ext4b_unlink(ext4b_device *dev,
                 uint32_t parent_inode,
                 const char *name, size_t name_len);

/*
 * Remove a name, optionally leaving the inode allocated.
 *
 * ext4 frees an inode as soon as its last link goes away, but a file can still
 * be open at that moment. Freeing it then means later writes through that
 * descriptor allocate blocks onto an inode nothing references, and those blocks
 * are never recovered: e2fsck reports "Block bitmap differences" once the
 * volume is unmounted.
 *
 * With `defer_release` the entry is removed and the link count drops, but the
 * inode and its blocks are left alone; `*out_unreferenced` is set when the link
 * count reached zero, and the caller owes a matching ext4b_release_inode() once
 * nothing holds the file open any more.
 *
 * The inode is recorded on the volume's orphan list for the duration, so an
 * unclean shutdown between the two calls is recoverable rather than a
 * permanent leak -- by ext4b_orphan_cleanup() at the next mount, and equally
 * by Linux or e2fsck, since the on-disk convention is the same one they use.
 */
int ext4b_unlink_ex(ext4b_device *dev,
                    uint32_t parent_inode,
                    const char *name, size_t name_len,
                    bool defer_release,
                    bool *out_unreferenced);

/// Truncate and free an inode left behind by ext4b_unlink_ex(), taking it off
/// the orphan list first.
/// Returns EBUSY if the inode still has links, rather than destroying a file
/// that is still reachable.
int ext4b_release_inode(ext4b_device *dev, uint32_t inode);

/*
 * Settle whatever an interrupted session left on the orphan list.
 *
 * Called automatically at the end of a read-write mount, after journal
 * recovery. Entries whose link count reached zero are finished off -- blocks
 * truncated, inode freed; entries that still have a name are dropped from the
 * list and left untouched, which is how an add that was cut short is undone.
 *
 * `*out_freed` and `*out_dropped` count each kind. Both may be NULL.
 */
int ext4b_orphan_cleanup(ext4b_device *dev,
                         uint32_t *out_freed,
                         uint32_t *out_dropped);

/// Turn the automatic mount-time orphan cleanup off. For tests that need to
/// look at what an interrupted session actually left on the medium, which an
/// ordinary read-write mount would have tidied away before they could see it.
/// On by default; must be called before ext4b_mount().
void ext4b_set_orphan_cleanup(ext4b_device *dev, bool enabled);

/// The head of the orphan list, or 0 when nothing is on it. For tests: a
/// deferred delete must show up here, and a clean unmount must leave it empty.
int ext4b_orphan_head(ext4b_device *dev, uint32_t *out_head);

/// Move/rename an entry, optionally between directories. If a plain file
/// already exists at the destination it is replaced.
int ext4b_rename(ext4b_device *dev,
                 uint32_t src_parent, const char *src_name, size_t src_len,
                 uint32_t dst_parent, const char *dst_name, size_t dst_len);

/// Write file data, allocating blocks as needed. Extends the file when the
/// write runs past the current end.
int ext4b_write(ext4b_device *dev,
                uint32_t inode,
                uint64_t offset,
                const void *buf,
                size_t count,
                size_t *out_written);

/// Grow or shrink a file. Growing creates a sparse region.
int ext4b_truncate(ext4b_device *dev, uint32_t inode, uint64_t new_size);

/// Change ownership, permissions, size or times.
int ext4b_setattr(ext4b_device *dev,
                  uint32_t inode,
                  ext4b_setattr_mask mask,
                  const ext4b_attrs *attrs);

int ext4b_setxattr(ext4b_device *dev, uint32_t inode,
                   const char *name,
                   const void *value, size_t value_len);

int ext4b_removexattr(ext4b_device *dev, uint32_t inode, const char *name);

/// True when the volume was mounted read-write.
bool ext4b_is_writable(ext4b_device *dev);

/* --------------------------------------------------------------- xattr -- */
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

/* How many times two threads have been inside lwext4 at once since this
 * process started. lwext4 has no internal locking, so any non-zero value is a
 * correctness bug upstream of the bridge, not a statistic. Always zero if the
 * caller is single-threaded, as the tools are. */
unsigned ext4b_core_collisions(void);

/* Ask the medium behind `fd` to commit everything it has been given, and not
 * to reorder across this point. Returns 0, or an errno if the descriptor
 * supports no barrier at all. See device_barrier.c for why this takes a raw
 * descriptor rather than going through the resource. */
int ext4b_barrier_fd(int fd);

/* What each of the three barrier calls said. Zero means that call worked. */
typedef struct {
    int sync_barrier;   /* DKIOCSYNCHRONIZE, DK_SYNCHRONIZE_OPTION_BARRIER */
    int sync_cache;     /* DKIOCSYNCHRONIZECACHE */
    int fullfsync;      /* F_FULLFSYNC */
} ext4b_barrier_report;

int ext4b_barrier_fd_verbose(int fd, ext4b_barrier_report *out);

/* Whether disk ioctls reach anything through `fd` at all, which is what tells
 * a medium that has no barrier apart from a descriptor that cannot ask for
 * one. Returns 0 and fills in the device's block size, or an errno. */
int ext4b_probe_disk_ioctl(int fd, uint32_t *block_size);

/* Human-readable description of a bridge/errno code. */
const char *ext4b_strerror(int err);

#ifdef __cplusplus
}
#endif

#endif /* EXT4_BRIDGE_H */
