/*
 * ext4dump — exercise the ext4 core against a plain image file.
 *
 * Deliberately independent of FSKit: no entitlement, no signing, no mounting.
 * This is the harness the correctness suite is built on.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "ext4_bridge.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <inttypes.h>

typedef struct {
    int fd;
} file_ctx;

static int file_read(void *ctx, void *buf, uint64_t off, size_t len)
{
    file_ctx *c = ctx;
    ssize_t n = pread(c->fd, buf, len, (off_t)off);
    return (n == (ssize_t)len) ? 0 : EIO;
}

static int file_write(void *ctx, const void *buf, uint64_t off, size_t len)
{
    file_ctx *c = ctx;
    ssize_t n = pwrite(c->fd, buf, len, (off_t)off);
    return (n == (ssize_t)len) ? 0 : EIO;
}

static int file_flush(void *ctx)
{
    file_ctx *c = ctx;
    return fsync(c->fd) == 0 ? 0 : EIO;
}

static void logger(void *ctx, int level, const char *msg)
{
    (void)ctx;
    fprintf(stderr, "[core:%d] %s\n", level, msg);
}

static const char *type_name(ext4b_item_type t)
{
    switch (t) {
    case EXT4B_TYPE_FILE:     return "file";
    case EXT4B_TYPE_DIR:      return "dir";
    case EXT4B_TYPE_SYMLINK:  return "symlink";
    case EXT4B_TYPE_FIFO:     return "fifo";
    case EXT4B_TYPE_CHARDEV:  return "chardev";
    case EXT4B_TYPE_BLOCKDEV: return "blockdev";
    case EXT4B_TYPE_SOCKET:   return "socket";
    default:                  return "unknown";
    }
}

static bool on_xattr(void *ctx, const char *name, size_t name_len)
{
    (void)ctx;
    printf("  %.*s\n", (int)name_len, name);
    return true;
}

/* ------------------------------------------------------------ traversal -- */

typedef struct {
    ext4b_device *dev;
    int depth;
    int max_depth;
    unsigned long files;
    unsigned long dirs;
    unsigned long links;
    unsigned long long bytes;
    bool verbose;
} walk_ctx;

static void walk_dir(walk_ctx *w, uint32_t ino, const char *path);

typedef struct {
    walk_ctx *w;
    const char *path;
} dirent_ctx;

static bool on_dirent(void *ctx, const char *name, size_t name_len,
                      uint32_t ino, ext4b_item_type type, uint64_t next_cookie)
{
    (void)next_cookie;
    dirent_ctx *dc = ctx;
    walk_ctx *w = dc->w;

    if ((name_len == 1 && name[0] == '.') ||
        (name_len == 2 && name[0] == '.' && name[1] == '.'))
        return true;

    char child[4096];
    snprintf(child, sizeof(child), "%s%s%.*s",
             dc->path, strcmp(dc->path, "/") == 0 ? "" : "/",
             (int)name_len, name);

    ext4b_attrs a;
    int r = ext4b_getattr(w->dev, ino, &a);
    if (r != 0) {
        fprintf(stderr, "  !! getattr(%u) for %s failed: %s\n",
                ino, child, ext4b_strerror(r));
        return true;
    }

    if (w->verbose) {
        printf("%-8s %7" PRIu64 "  %04o %5u:%-5u ino=%-8u %s",
               type_name(type), a.size, a.mode, a.uid, a.gid, ino, child);
        if (type == EXT4B_TYPE_SYMLINK) {
            char target[1024];
            size_t tlen = 0;
            if (ext4b_readlink(w->dev, ino, target, sizeof(target), &tlen) == 0)
                printf(" -> %s", target);
        }
        printf("\n");
    }

    switch (type) {
    case EXT4B_TYPE_DIR:
        w->dirs++;
        if (w->depth < w->max_depth) {
            w->depth++;
            walk_dir(w, ino, child);
            w->depth--;
        }
        break;
    case EXT4B_TYPE_SYMLINK:
        w->links++;
        break;
    case EXT4B_TYPE_FILE:
        w->files++;
        w->bytes += a.size;
        break;
    default:
        break;
    }
    return true;
}

static void walk_dir(walk_ctx *w, uint32_t ino, const char *path)
{
    dirent_ctx dc = { .w = w, .path = path };
    int r = ext4b_readdir(w->dev, ino, 0, on_dirent, &dc);
    if (r != 0 && r != ENOENT)
        fprintf(stderr, "  !! readdir(%s) failed: %s\n", path, ext4b_strerror(r));
}

/* ----------------------------------------------------------------- main -- */

static int cmd_cat(ext4b_device *dev, const char *path);
static int cmd_extents(ext4b_device *dev, const char *path);

static uint32_t resolve(ext4b_device *dev, const char *path, ext4b_item_type *t)
{
    uint32_t ino = EXT4B_ROOT_INO;
    ext4b_item_type type = EXT4B_TYPE_DIR;

    const char *p = path;
    while (*p == '/') p++;

    while (*p) {
        const char *slash = strchr(p, '/');
        size_t len = slash ? (size_t)(slash - p) : strlen(p);
        uint32_t next = 0;
        int r = ext4b_lookup(dev, ino, p, len, &next, &type);
        if (r != 0) {
            fprintf(stderr, "lookup failed at '%.*s': %s\n",
                    (int)len, p, ext4b_strerror(r));
            return 0;
        }
        ino = next;
        p = slash ? slash + 1 : p + len;
        while (*p == '/') p++;
    }
    if (t) *t = type;
    return ino;
}

int main(int argc, char **argv)
{
    if (argc < 3) {
        fprintf(stderr,
            "usage: %s <image> <command> [args]\n"
            "\ncommands:\n"
            "  probe              inspect the superblock without mounting\n"
            "  ls [path]          recursive listing (default /)\n"
            "  stat <path>        show inode attributes\n"
            "  cat <path>         write file contents to stdout\n"
            "  extents <path>     show the logical->physical extent map\n"
            "  xattr <path>       list extended attributes\n",
            argv[0]);
        return 2;
    }

    const char *image = argv[1];
    const char *cmd   = argv[2];

    ext4b_set_logger(logger, NULL);

    int fd = open(image, O_RDONLY);
    if (fd < 0) {
        perror("open");
        return 1;
    }
    struct stat st;
    if (fstat(fd, &st) != 0) {
        perror("fstat");
        return 1;
    }

    file_ctx fc = { .fd = fd };
    const uint32_t bs = 512;
    ext4b_device *dev = ext4b_device_create(&fc, bs, (uint64_t)st.st_size / bs,
                                            true, file_read, file_write, file_flush);
    if (!dev) {
        fprintf(stderr, "failed to create device\n");
        return 1;
    }

    int rc = 0;

    if (strcmp(cmd, "probe") == 0) {
        ext4b_probe_info info;
        int r = ext4b_probe(dev, &info);
        if (r != 0) { fprintf(stderr, "probe error: %s\n", ext4b_strerror(r)); rc = 1; goto out; }

        static const char *verdicts[] = { "NOT_EXT", "USABLE", "READ_ONLY", "UNSUPPORTED" };
        printf("verdict:       %s\n", verdicts[info.verdict]);
        if (info.verdict == EXT4B_PROBE_NOT_EXT) goto out;

        printf("generation:    ext%d\n", info.generation);
        printf("label:         %s\n", info.label[0] ? info.label : "(none)");
        printf("uuid:          ");
        for (int i = 0; i < 16; i++) {
            printf("%02x", info.uuid[i]);
            if (i==3||i==5||i==7||i==9) printf("-");
        }
        printf("\n");
        printf("block size:    %u\n", info.block_size);
        printf("blocks:        %" PRIu64 " (%" PRIu64 " free)\n",
               info.block_count, info.free_blocks);
        printf("inodes:        %u (%u free)\n", info.inode_count, info.free_inodes);
        printf("size:          %.2f MiB\n",
               (double)(info.block_count * (uint64_t)info.block_size) / (1024*1024));
        printf("journal:       %s%s\n", info.has_journal ? "yes" : "no",
               info.needs_recovery ? " (NEEDS RECOVERY)" : "");
        printf("features:      compat=0x%08x incompat=0x%08x ro_compat=0x%08x\n",
               info.feature_compat, info.feature_incompat, info.feature_ro_compat);
        if (info.unsupported[0])
            printf("note:          %s\n", info.unsupported);
        goto out;
    }

    int r = ext4b_mount(dev, true);
    if (r != 0) {
        fprintf(stderr, "mount failed: %s\n", ext4b_strerror(r));
        rc = 1;
        goto out;
    }

    ext4b_statfs_info sfs;
    if (ext4b_statfs(dev, &sfs) == 0 && strcmp(cmd, "ls") == 0) {
        printf("# %" PRIu64 "/%" PRIu64 " blocks free, %u/%u inodes free, bs=%u\n",
               sfs.free_blocks, sfs.total_blocks,
               sfs.free_inodes, sfs.total_inodes, sfs.block_size);
    }

    if (strcmp(cmd, "ls") == 0) {
        const char *path = (argc > 3) ? argv[3] : "/";
        uint32_t ino = resolve(dev, path, NULL);
        if (!ino) { rc = 1; goto unmount; }

        walk_ctx w = { .dev = dev, .max_depth = 64, .verbose = true };
        walk_dir(&w, ino, strcmp(path, "/") == 0 ? "" : path);
        printf("\n# %lu dirs, %lu files, %lu symlinks, %llu bytes\n",
               w.dirs, w.files, w.links, w.bytes);

    } else if (strcmp(cmd, "stat") == 0) {
        if (argc < 4) { fprintf(stderr, "stat needs a path\n"); rc = 2; goto unmount; }
        uint32_t ino = resolve(dev, argv[3], NULL);
        if (!ino) { rc = 1; goto unmount; }
        ext4b_attrs a;
        if ((r = ext4b_getattr(dev, ino, &a)) != 0) {
            fprintf(stderr, "getattr: %s\n", ext4b_strerror(r)); rc = 1; goto unmount;
        }
        printf("inode:      %u\n", a.inode);
        printf("type:       %s\n", type_name(a.type));
        printf("mode:       %04o\n", a.mode);
        printf("uid/gid:    %u/%u\n", a.uid, a.gid);
        printf("links:      %u\n", a.link_count);
        printf("size:       %" PRIu64 "\n", a.size);
        printf("alloc:      %" PRIu64 "\n", a.alloc_size);
        printf("layout:     %s%s\n", a.uses_extents ? "extents" : "indirect blocks",
               a.inline_data ? " + inline data" : "");
        printf("mtime:      %lld.%09u\n", a.mtime, a.mtime_ns);
        printf("crtime:     %lld.%09u\n", a.crtime, a.crtime_ns);

    } else if (strcmp(cmd, "cat") == 0) {
        if (argc < 4) { fprintf(stderr, "cat needs a path\n"); rc = 2; goto unmount; }
        rc = cmd_cat(dev, argv[3]);

    } else if (strcmp(cmd, "extents") == 0) {
        if (argc < 4) { fprintf(stderr, "extents needs a path\n"); rc = 2; goto unmount; }
        rc = cmd_extents(dev, argv[3]);

    } else if (strcmp(cmd, "xattr") == 0) {
        if (argc < 4) { fprintf(stderr, "xattr needs a path\n"); rc = 2; goto unmount; }
        uint32_t ino = resolve(dev, argv[3], NULL);
        if (!ino) { rc = 1; goto unmount; }
        r = ext4b_listxattr(dev, ino, on_xattr, NULL);
        if (r != 0)
            fprintf(stderr, "listxattr: %s\n", ext4b_strerror(r));

    } else {
        fprintf(stderr, "unknown command: %s\n", cmd);
        rc = 2;
    }

unmount:
    ext4b_unmount(dev);
out:
    ext4b_device_destroy(dev);
    close(fd);
    return rc;
}

static int cmd_cat(ext4b_device *dev, const char *path)
{
    uint32_t ino = resolve(dev, path, NULL);
    if (!ino) return 1;

    ext4b_attrs a;
    if (ext4b_getattr(dev, ino, &a) != 0) return 1;

    char buf[65536];
    uint64_t off = 0;
    while (off < a.size) {
        size_t got = 0;
        int r = ext4b_read(dev, ino, off, buf, sizeof(buf), &got);
        if (r != 0 || got == 0) {
            if (r != 0) fprintf(stderr, "read: %s\n", ext4b_strerror(r));
            break;
        }
        fwrite(buf, 1, got, stdout);
        off += got;
    }
    return 0;
}

static int cmd_extents(ext4b_device *dev, const char *path)
{
    uint32_t ino = resolve(dev, path, NULL);
    if (!ino) return 1;

    ext4b_attrs a;
    if (ext4b_getattr(dev, ino, &a) != 0) return 1;

    ext4b_extent ext[256];
    size_t n = 0;
    int r = ext4b_map_extents(dev, ino, 0, a.size, ext, 256, &n);
    if (r != 0) {
        fprintf(stderr, "map_extents: %s\n", ext4b_strerror(r));
        return 1;
    }

    printf("%s: size=%" PRIu64 " layout=%s, %zu extent(s)\n",
           path, a.size, a.uses_extents ? "extents" : "indirect", n);
    for (size_t i = 0; i < n; i++) {
        printf("  [%2zu] logical %10" PRIu64 "  physical %12" PRIu64
               "  len %8" PRIu64 "%s\n",
               i, ext[i].logical_offset, ext[i].physical_offset,
               ext[i].length, ext[i].is_hole ? "  (hole)" : "");
    }
    return 0;
}
