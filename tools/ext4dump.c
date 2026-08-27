/*
 * ext4dump — exercise the ext4 core against a plain image file.
 *
 * Deliberately independent of FSKit: no entitlement, no signing, no mounting.
 * This is the harness the correctness suite is built on.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "ext4_bridge.h"
#include "luks.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <sys/stat.h>
#include <sys/disk.h>   /* DKIOCGETBLOCKCOUNT */
#include <sys/ioctl.h>
#include <inttypes.h>

/* One write held in the modelled drive's volatile cache; see below. */
typedef struct {
    uint64_t off;
    size_t   len;
    uint8_t *data;
} pending_write;

typedef struct {
    int fd;
    /*
     * Power-failure simulation. After `fail_after` successful writes, every
     * later write is silently discarded while still reporting success.
     *
     * Discarding rather than returning an error is the point: a real power cut
     * does not hand the filesystem an errno it can react to, it simply stops
     * persisting. Returning EIO would exercise error handling instead, which is
     * a different (and much easier) test.
     */
    long fail_after;
    long writes;
    bool crashed;

    /*
     * The volatile write cache. Off unless EXT4DUMP_WRITE_CACHE is set, in
     * which case this file behaves like a drive rather than like a file: see
     * the model above.
     */
    pending_write *pending;
    size_t         pending_count;
    size_t         pending_cap;
    size_t         pending_bytes;
    size_t         cache_bytes;      /* 0 disables the model entirely */
    uint32_t       reorder_seed;
    uint32_t       rng;             /* seeded; drives eviction and the crash */
    int            reorder_drop;     /* percent of the pending queue lost */
    bool           ignore_barriers;  /* a drive that lies about flushing */

    /*
     * Progress, for the one operation slow enough to need it.
     *
     * Formatting a 16 GB volume writes about 260 MB of inode tables, bitmaps
     * and journal. On an SSD that is under a second and nobody notices; on a
     * USB stick it is minutes of silence, which is indistinguishable from a
     * hang -- and was mistaken for one.
     *
     * `progress_total` is an estimate, not a measurement: ext4's defaults put
     * one inode per 16 KiB at 256 bytes each, so the inode tables alone come
     * to about a sixty-fourth of the volume, and the rest is journal and
     * bitmaps. Close enough to be useful, so the bar is capped at 99% until
     * the format actually returns rather than pretending otherwise.
     */
    uint64_t written;
    uint64_t progress_total;
    time_t   progress_started;
    time_t   progress_last;
} file_ctx;

/* Draw the bar, or print a line if this is not a terminal -- a suite capturing
 * output wants milestones, not carriage returns. */
static void progress_tick(file_ctx *c, bool final)
{
    if (!c->progress_total)
        return;

    time_t now = time(NULL);
    if (!final && now == c->progress_last)
        return;                     /* at most once a second */
    c->progress_last = now;

    double frac = (double)c->written / (double)c->progress_total;
    if (frac > 0.99) frac = 0.99;
    if (final) frac = 1.0;

    unsigned long elapsed = (unsigned long)(now - c->progress_started);
    double mb = (double)c->written / (1024.0 * 1024.0);
    double rate = elapsed ? mb / (double)elapsed : 0.0;

    if (isatty(STDERR_FILENO)) {
        int width = 32, filled = (int)(frac * width);
        fprintf(stderr, "\r  formatting [");
        for (int i = 0; i < width; i++) fputc(i < filled ? '=' : ' ', stderr);
        fprintf(stderr, "] %3d%%  %.0f MB", (int)(frac * 100), mb);
        if (rate > 0) fprintf(stderr, "  %.1f MB/s", rate);
        fputs("   ", stderr);
        if (final) fputc('\n', stderr);
        fflush(stderr);
    } else if (final) {
        fprintf(stderr, "  formatting: %.0f MB in %lus\n", mb, elapsed);
    } else {
        static int last_decile = -1;
        int decile = (int)(frac * 10);
        if (decile != last_decile) {
            last_decile = decile;
            fprintf(stderr, "  formatting: %d%%  %.0f MB\n", (int)(frac * 100), mb);
        }
    }
}

/* ======================================================= volatile cache == */
/*
 * A drive with a write cache, modelled honestly.
 *
 * This exists because a disk image cannot fail the test that matters. An
 * image's writes reach the host filesystem in issue order and stay there, so
 * every crash-consistency sweep over one passes trivially -- not because the
 * filesystem is correct, but because the medium is incapable of the failure.
 * A USB stick is capable of it, and duly produced a damaged volume five times
 * out of five where an image produced none in forty-two. Chasing that with
 * real hardware cost a day: device names change between replugs, the target
 * degrades as it is abused, and each run takes minutes and destroys its own
 * evidence.
 *
 * So the medium is modelled instead. A real drive does three things this file
 * did not:
 *
 *   - it serves reads from cache, so the filesystem sees its own writes
 *     whether or not they have reached the platter;
 *   - it commits to media in whatever order suits it;
 *   - on power loss it keeps an arbitrary subset of what it was holding.
 *
 * The only thing that makes a write durable is a barrier. Everything issued
 * since the last one is a pool that may land in any order, or not at all --
 * which is exactly the property a journal is supposed to be robust against,
 * and exactly what could not be tested here before.
 */

/* Grow the pending queue by one entry, taking a copy of the caller's bytes. */
static int cache_append(file_ctx *c, uint64_t off, const void *buf, size_t len)
{
    if (c->pending_count == c->pending_cap) {
        size_t cap = c->pending_cap ? c->pending_cap * 2 : 256;
        pending_write *p = realloc(c->pending, cap * sizeof *p);
        if (!p)
            return EIO;
        c->pending = p;
        c->pending_cap = cap;
    }

    uint8_t *copy = malloc(len);
    if (!copy)
        return EIO;
    memcpy(copy, buf, len);

    c->pending[c->pending_count].off  = off;
    c->pending[c->pending_count].len  = len;
    c->pending[c->pending_count].data = copy;
    c->pending_count++;
    c->pending_bytes += len;
    return 0;
}

static int cache_apply(file_ctx *c, size_t i)
{
    ssize_t n = pwrite(c->fd, c->pending[i].data, c->pending[i].len,
                       (off_t)c->pending[i].off);
    return (n == (ssize_t)c->pending[i].len) ? 0 : EIO;
}

static void cache_forget(file_ctx *c, size_t from)
{
    for (size_t i = from; i < c->pending_count; i++)
        free(c->pending[i].data);
    if (from == 0) {
        c->pending_count = 0;
        c->pending_bytes = 0;
    }
}

/* The barrier: everything issued so far reaches the medium, in order. */
static int cache_commit(file_ctx *c)
{
    int rc = 0;
    for (size_t i = 0; i < c->pending_count; i++)
        if (cache_apply(c, i) != 0)
            rc = EIO;
    cache_forget(c, 0);
    return rc;
}

/*
 * A cache is finite. When it fills, some of it is written out to make room.
 *
 * *Which* part, and in what order, is the drive's business and not the
 * filesystem's -- and that matters more than it looks. An earlier version of
 * this evicted the oldest entries in issue order, which is a tidy thing to do
 * and completely defeats the model: the medium then always holds a prefix of
 * the issue stream, which is exactly the state that is safe by construction.
 * With barriers disabled the suite still passed, because nothing had ever
 * actually been reordered.
 *
 * So eviction picks its victims by the same seeded permutation the crash uses.
 * Reordering happens throughout the run, not only at the end.
 */
static uint32_t cache_rand(file_ctx *c)
{
    c->rng = c->rng * 1103515245u + 12345u;
    return c->rng >> 16;
}

static int cache_evict(file_ctx *c)
{
    size_t n = c->pending_count;
    if (n == 0)
        return 0;

    size_t want = n / 2;
    if (want == 0)
        want = n;

    /* Mark a seeded-random half for eviction, then apply the marked ones in
     * the order they were marked -- not the order they were issued. */
    bool *evict = calloc(n, sizeof *evict);
    if (!evict)
        return EIO;

    size_t marked = 0;
    while (marked < want) {
        size_t i = (size_t)(cache_rand(c) % n);
        if (!evict[i]) { evict[i] = true; marked++; }
    }

    for (size_t i = 0; i < n; i++) {
        if (!evict[i])
            continue;
        if (cache_apply(c, i) != 0) { free(evict); return EIO; }
    }

    /* Compact, keeping the survivors in issue order. */
    size_t w = 0;
    for (size_t i = 0; i < n; i++) {
        if (evict[i]) {
            c->pending_bytes -= c->pending[i].len;
            free(c->pending[i].data);
        } else {
            c->pending[w++] = c->pending[i];
        }
    }
    c->pending_count = w;
    free(evict);
    return 0;
}

/*
 * Power loss.
 *
 * The drive was holding a queue and had its own opinion about the order to
 * commit it in. It got partway through that order and then stopped. So:
 * permute what is pending, apply a prefix of the permutation, discard the
 * rest.
 *
 * The permutation is seeded, and the seed is the whole reproduction recipe --
 * a failure found at seed 7 is a failure anyone can look at again.
 */
static void cache_crash(file_ctx *c)
{
    size_t n = c->pending_count;
    if (n == 0)
        return;

    size_t *order = malloc(n * sizeof *order);
    if (!order) { cache_forget(c, 0); return; }
    for (size_t i = 0; i < n; i++)
        order[i] = i;

    for (size_t i = n; i > 1; i--) {
        size_t j = (size_t)(cache_rand(c) % i);
        size_t t = order[i - 1]; order[i - 1] = order[j]; order[j] = t;
    }

    size_t keep = n - (n * (size_t)c->reorder_drop) / 100;
    for (size_t k = 0; k < keep; k++)
        (void)cache_apply(c, order[k]);

    if (getenv("EXT4DUMP_TRACE_WRITES"))
        fprintf(stderr, "CRASH seed=%u: %zu pending, %zu committed reordered\n",
                c->reorder_seed, n, keep);

    free(order);
    cache_forget(c, 0);
}

/* A read is served from the cache first: newest write to a range wins. */
static void cache_overlay(file_ctx *c, void *buf, uint64_t off, size_t len)
{
    uint8_t *out = buf;
    for (size_t i = 0; i < c->pending_count; i++) {
        uint64_t ps = c->pending[i].off;
        uint64_t pe = ps + c->pending[i].len;
        uint64_t rs = off, re = off + len;
        if (pe <= rs || ps >= re)
            continue;

        uint64_t s = ps > rs ? ps : rs;
        uint64_t e = pe < re ? pe : re;
        memcpy(out + (s - rs), c->pending[i].data + (s - ps), (size_t)(e - s));
    }
}

static int file_read(void *ctx, void *buf, uint64_t off, size_t len)
{
    file_ctx *c = ctx;
    ssize_t n = pread(c->fd, buf, len, (off_t)off);
    if (n != (ssize_t)len)
        return EIO;

    if (c->cache_bytes)
        cache_overlay(c, buf, off, len);
    return 0;
}

static int file_write(void *ctx, const void *buf, uint64_t off, size_t len)
{
    file_ctx *c = ctx;

    if (c->fail_after >= 0 && c->writes >= c->fail_after) {
        /* The instant of power loss, once. Whatever the drive was holding is
         * committed in its own order, partially, and the rest is gone. */
        if (!c->crashed) {
            c->crashed = true;
            if (c->cache_bytes)
                cache_crash(c);
        }
        c->writes++;
        return 0;           /* pretend it landed; the bytes are lost */
    }
    c->written += len;
    progress_tick(c, false);
    if (getenv("EXT4DUMP_TRACE_WRITES"))
        fprintf(stderr, "W%-3ld off=%-10llu blk=%-8llu len=%zu\n",
                c->writes, (unsigned long long)off,
                (unsigned long long)(off / 4096), len);
    c->writes++;

    /* Into the cache, not onto the medium. Only a barrier puts it there. */
    if (c->cache_bytes) {
        if (c->pending_bytes + len > c->cache_bytes && cache_evict(c) != 0)
            return EIO;
        return cache_append(c, off, buf, len);
    }

    ssize_t n = pwrite(c->fd, buf, len, (off_t)off);
    return (n == (ssize_t)len) ? 0 : EIO;
}

/* A real write barrier, which on macOS fsync() is not.
 *
 * fsync(2) here only guarantees the data has left the buffer cache for the
 * drive; the drive is free to hold it in volatile cache and commit it in
 * whatever order suits it. F_FULLFSYNC is the call that asks the drive to
 * commit, and it is what a journal needs between writing a transaction and
 * writing the commit block that claims the transaction is complete.
 *
 * Not every device supports it -- a plain file on some filesystems returns
 * ENOTSUP -- so fall back rather than failing the flush.
 */
static int file_flush(void *ctx)
{
    file_ctx *c = ctx;
    if (c->crashed)
        return 0;           /* a flush after the cut reaches nothing */

    if (c->cache_bytes) {
        /* A drive that reports cache-flush support and does not honour it is
         * a real and depressingly common thing. Modelling one is also the
         * negative control: with barriers ignored the suite must fail, and a
         * crash-consistency test that cannot be made to fail proves nothing. */
        if (c->ignore_barriers)
            return 0;
        return cache_commit(c);
    }

    if (fcntl(c->fd, F_FULLFSYNC) == 0)
        return 0;
    if (errno != ENOTSUP && errno != ENOTTY && errno != EINVAL)
        return EIO;

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


/* Split "/a/b/c" into the inode of "/a/b" and the name "c". */
static uint32_t resolve_parent(ext4b_device *dev, const char *path,
                               const char **out_name, size_t *out_name_len)
{
    const char *last = strrchr(path, '/');
    if (!last) {
        *out_name = path;
        *out_name_len = strlen(path);
        return EXT4B_ROOT_INO;
    }
    *out_name = last + 1;
    *out_name_len = strlen(last + 1);
    if (*out_name_len == 0) {
        fprintf(stderr, "path must not end in '/': %s\n", path);
        return 0;
    }
    if (last == path)
        return EXT4B_ROOT_INO;

    char parent[4096];
    size_t plen = (size_t)(last - path);
    if (plen >= sizeof(parent)) return 0;
    memcpy(parent, path, plen);
    parent[plen] = '\0';
    return resolve(dev, parent, NULL);
}

/* Commands that mutate the image; these force an O_RDWR open and an rw mount. */
/*
 * Unlock a container and build the decrypting device.
 *
 * The passphrase comes from a file, never from a command line: argv is visible
 * to every process on the machine through ps(1).
 */
static luks_device *open_luks(file_ctx *fc, const char *keyfile, bool writable,
                              uint64_t *dev_bytes)
{
    FILE *f = fopen(keyfile, "rb");
    if (!f) { perror("luks key file"); return NULL; }

    uint8_t pass[1024];
    size_t pass_len = fread(pass, 1, sizeof(pass), f);
    fclose(f);
    /* A trailing newline is what every `echo -n`-less invocation leaves, and
     * cryptsetup's --key-file does not strip it either; match that. */

    luks_info info;
    luks_status s = luks_probe(fc, file_read, &info);
    if (s != LUKS_OK) {
        fprintf(stderr, "luks: %s%s%s\n", luks_strstatus(s),
                info.unsupported[0] ? ": " : "", info.unsupported);
        memset(pass, 0, sizeof(pass));
        return NULL;
    }

    uint8_t mk[LUKS_MAX_MASTER_KEY];
    size_t mk_len = 0;
    s = luks_unlock(fc, file_read, &info, pass, pass_len, mk, &mk_len);
    memset(pass, 0, sizeof(pass));
    if (s != LUKS_OK) {
        fprintf(stderr, "luks: %s\n", luks_strstatus(s));
        memset(mk, 0, sizeof(mk));
        return NULL;
    }

    luks_device *d = luks_device_open(fc, file_read,
                                      writable ? file_write : NULL,
                                      file_flush, &info, mk, mk_len);
    memset(mk, 0, sizeof(mk));
    if (!d) {
        fprintf(stderr, "luks: could not open the decrypting device\n");
        return NULL;
    }

    fprintf(stderr, "[luks%d] %s, %u-byte sectors, payload at %llu\n",
            info.version, info.uuid, info.sector_size,
            (unsigned long long)info.payload_offset);

    *dev_bytes = luks_payload_size(d, *dev_bytes);
    return d;
}

static bool is_write_cmd(const char *c)
{
    static const char *w[] = { "mkdir", "create", "write", "append", "rm",
                               "mv", "ln", "symlink", "truncate", "chmod",
                               "chown", "setxattr", "rmxattr", "script",
                               "format", "label", "rm-open", "rm-cycle",
                               "release", NULL };
    for (int i = 0; w[i]; i++)
        if (strcmp(c, w[i]) == 0) return true;
    return false;
}


/* One mutating command, shaped exactly as it arrives on the command line:
 * argv[2] is the verb, argv[3...] its arguments.
 *
 * Lifted out of main so that `script` can run a hundred of them inside a
 * single mount. Every other path through this tool mounts, performs one
 * operation and unmounts -- which checkpoints the journal and empties the
 * cache each time. So the crash sweep, thorough as it is about cut points,
 * has only ever tested a filesystem with a single transaction in flight. The
 * mounted driver keeps hundreds moving through one journal at once, and that
 * is the shape a USB stick found damage in.
 */
static int run_write_command(ext4b_device *dev, int argc, char **argv);

/* Run a file of mutating commands inside one mount.
 *
 * One command per line -- the verb and its arguments, whitespace separated,
 * exactly as they would be typed. Blank lines and lines beginning with # are
 * skipped. There is no quoting: an argument cannot contain a space.
 *
 * With EXT4DUMP_FAIL_AFTER set, writes past the cut report success and reach
 * nothing, so the script runs on to the end over a device that stopped
 * persisting -- which is what a crash looks like from inside the filesystem.
 */
static int run_script(ext4b_device *dev, const char *path)
{
    FILE *f = (strcmp(path, "-") == 0) ? stdin : fopen(path, "r");
    if (!f) { perror(path); return 1; }

    char line[4096];
    unsigned long lineno = 0;
    int rc = 0;

    while (fgets(line, sizeof line, f)) {
        char *argv[16];
        int argc = 2;                 /* argv[0] and argv[1] are never read */
        char *save = NULL;

        lineno++;
        argv[0] = argv[1] = (char *)"";
        for (char *tok = strtok_r(line, " \t\r\n", &save);
             tok && argc < 16;
             tok = strtok_r(NULL, " \t\r\n", &save))
            argv[argc++] = tok;

        if (argc == 2 || argv[2][0] == '#')
            continue;

        rc = run_write_command(dev, argc, argv);
        if (rc != 0) {
            fprintf(stderr, "%s:%lu: %s failed\n", path, lineno, argv[2]);
            break;
        }
    }

    if (f != stdin)
        fclose(f);
    return rc;
}

static int run_write_command(ext4b_device *dev, int argc, char **argv)
{
    const char *cmd = argv[2];
    const char *name = NULL;
    size_t name_len = 0;
    int r = 0;
    int rc = 0;

    if (strcmp(cmd, "script") == 0) {
        if (argc < 4) { fprintf(stderr, "script needs a file\n"); return 2; }
        return run_script(dev, argv[3]);
    }
    if (strcmp(cmd, "mkdir") == 0 || strcmp(cmd, "create") == 0) {
        if (argc < 4) { fprintf(stderr, "%s needs a path\n", cmd); rc = 2; return rc; }
        uint32_t parent = resolve_parent(dev, argv[3], &name, &name_len);
        if (!parent) { rc = 1; return rc; }
        bool is_dir = (strcmp(cmd, "mkdir") == 0);
        uint32_t mode = is_dir ? 0755 : 0644;
        if (argc > 4) mode = (uint32_t)strtol(argv[4], NULL, 8);
        uint32_t ino = 0;
        r = ext4b_create(dev, parent, name, name_len,
                         is_dir ? EXT4B_TYPE_DIR : EXT4B_TYPE_FILE,
                         mode, (uint32_t)getuid(), (uint32_t)getgid(), &ino);
        if (r != 0) { fprintf(stderr, "%s: %s\n", cmd, ext4b_strerror(r)); rc = 1; }
        else printf("created inode %u\n", ino);

    } else if (strcmp(cmd, "write") == 0 || strcmp(cmd, "append") == 0) {
        if (argc < 5) { fprintf(stderr, "%s needs <path> <text>\n", cmd); rc = 2; return rc; }
        uint32_t ino = resolve(dev, argv[3], NULL);
        if (!ino) { rc = 1; return rc; }
        uint64_t off = 0;
        if (strcmp(cmd, "append") == 0) {
            ext4b_attrs a;
            if (ext4b_getattr(dev, ino, &a) == 0) off = a.size;
        }
        size_t written = 0;
        r = ext4b_write(dev, ino, off, argv[4], strlen(argv[4]), &written);
        if (r != 0) { fprintf(stderr, "write: %s\n", ext4b_strerror(r)); rc = 1; }
        else printf("wrote %zu bytes at %llu\n", written, (unsigned long long)off);

    } else if (strcmp(cmd, "rm") == 0) {
        if (argc < 4) { fprintf(stderr, "rm needs a path\n"); rc = 2; return rc; }
        uint32_t parent = resolve_parent(dev, argv[3], &name, &name_len);
        if (!parent) { rc = 1; return rc; }
        r = ext4b_unlink(dev, parent, name, name_len);
        if (r != 0) { fprintf(stderr, "rm: %s\n", ext4b_strerror(r)); rc = 1; }

    } else if (strcmp(cmd, "rm-open") == 0 || strcmp(cmd, "rm-cycle") == 0) {
        /* Delete a name while pretending something still holds the file
         * open, which is what the mounted driver does for a file with a
         * live descriptor. The inode stays allocated and goes on the
         * orphan list; rm-cycle then completes the release, rm-open leaves
         * it there so a crash can be simulated mid-lifecycle. */
        if (argc < 4) { fprintf(stderr, "%s needs a path\n", cmd); rc = 2; return rc; }
        bool cycle = (strcmp(cmd, "rm-cycle") == 0);
        for (int i = 3; i < argc; i++) {
            uint32_t parent = resolve_parent(dev, argv[i], &name, &name_len);
            if (!parent) { rc = 1; return rc; }
            uint32_t victim = resolve(dev, argv[i], NULL);
            bool unreferenced = false;
            r = ext4b_unlink_ex(dev, parent, name, name_len, true, &unreferenced);
            if (r != 0) {
                fprintf(stderr, "%s: %s\n", cmd, ext4b_strerror(r));
                rc = 1;
                break;
            }
            printf("unlinked %s (inode %u%s)\n", argv[i], victim,
                   unreferenced ? ", deferred" : "");
            if (cycle && unreferenced) {
                r = ext4b_release_inode(dev, victim);
                if (r != 0) {
                    fprintf(stderr, "release: %s\n", ext4b_strerror(r));
                    rc = 1;
                    break;
                }
            }
        }

    } else if (strcmp(cmd, "release") == 0) {
        if (argc < 4) { fprintf(stderr, "release needs an inode number\n"); rc = 2; return rc; }
        for (int i = 3; i < argc; i++) {
            r = ext4b_release_inode(dev, (uint32_t)strtoul(argv[i], NULL, 10));
            if (r != 0) { fprintf(stderr, "release: %s\n", ext4b_strerror(r)); rc = 1; break; }
        }

    } else if (strcmp(cmd, "mv") == 0) {
        if (argc < 5) { fprintf(stderr, "mv needs <src> <dst>\n"); rc = 2; return rc; }
        const char *sname, *dname; size_t slen, dlen;
        uint32_t sp = resolve_parent(dev, argv[3], &sname, &slen);
        uint32_t dp = resolve_parent(dev, argv[4], &dname, &dlen);
        if (!sp || !dp) { rc = 1; return rc; }
        r = ext4b_rename(dev, sp, sname, slen, dp, dname, dlen);
        if (r != 0) { fprintf(stderr, "mv: %s\n", ext4b_strerror(r)); rc = 1; }

    } else if (strcmp(cmd, "ln") == 0) {
        if (argc < 5) { fprintf(stderr, "ln needs <target> <name>\n"); rc = 2; return rc; }
        uint32_t target = resolve(dev, argv[3], NULL);
        if (!target) { rc = 1; return rc; }
        uint32_t parent = resolve_parent(dev, argv[4], &name, &name_len);
        if (!parent) { rc = 1; return rc; }
        r = ext4b_hardlink(dev, parent, name, name_len, target);
        if (r != 0) { fprintf(stderr, "ln: %s\n", ext4b_strerror(r)); rc = 1; }

    } else if (strcmp(cmd, "symlink") == 0) {
        if (argc < 5) { fprintf(stderr, "symlink needs <target> <name>\n"); rc = 2; return rc; }
        uint32_t parent = resolve_parent(dev, argv[4], &name, &name_len);
        if (!parent) { rc = 1; return rc; }
        uint32_t ino = 0;
        r = ext4b_symlink(dev, parent, name, name_len, argv[3], strlen(argv[3]),
                          (uint32_t)getuid(), (uint32_t)getgid(), &ino);
        if (r != 0) { fprintf(stderr, "symlink: %s\n", ext4b_strerror(r)); rc = 1; }

    } else if (strcmp(cmd, "truncate") == 0) {
        if (argc < 5) { fprintf(stderr, "truncate needs <path> <size>\n"); rc = 2; return rc; }
        uint32_t ino = resolve(dev, argv[3], NULL);
        if (!ino) { rc = 1; return rc; }
        r = ext4b_truncate(dev, ino, strtoull(argv[4], NULL, 10));
        if (r != 0) { fprintf(stderr, "truncate: %s\n", ext4b_strerror(r)); rc = 1; }

    } else if (strcmp(cmd, "chmod") == 0) {
        if (argc < 5) { fprintf(stderr, "chmod needs <path> <mode>\n"); rc = 2; return rc; }
        uint32_t ino = resolve(dev, argv[3], NULL);
        if (!ino) { rc = 1; return rc; }
        ext4b_attrs a; memset(&a, 0, sizeof(a));
        a.mode = (uint32_t)strtol(argv[4], NULL, 8);
        r = ext4b_setattr(dev, ino, EXT4B_SET_MODE, &a);
        if (r != 0) { fprintf(stderr, "chmod: %s\n", ext4b_strerror(r)); rc = 1; }

    } else if (strcmp(cmd, "setxattr") == 0) {
        if (argc < 6) { fprintf(stderr, "setxattr needs <path> <name> <value>\n"); rc = 2; return rc; }
        uint32_t ino = resolve(dev, argv[3], NULL);
        if (!ino) { rc = 1; return rc; }
        r = ext4b_setxattr(dev, ino, argv[4], argv[5], strlen(argv[5]));
        if (r != 0) { fprintf(stderr, "setxattr: %s\n", ext4b_strerror(r)); rc = 1; }

    } else if (strcmp(cmd, "label") == 0) {
        if (argc < 4) { fprintf(stderr, "label needs a name\n"); rc = 2; return rc; }
        r = ext4b_set_label(dev, argv[3]);
        if (r != 0) { fprintf(stderr, "label: %s\n", ext4b_strerror(r)); rc = 1; }
    } else if (strcmp(cmd, "rmxattr") == 0) {
        if (argc < 5) { fprintf(stderr, "rmxattr needs <path> <name>\n"); rc = 2; return rc; }
        uint32_t ino = resolve(dev, argv[3], NULL);
        if (!ino) { rc = 1; return rc; }
        r = ext4b_removexattr(dev, ino, argv[4]);
        if (r != 0) { fprintf(stderr, "rmxattr: %s\n", ext4b_strerror(r)); rc = 1; }

    } else {
        fprintf(stderr, "unknown write command: %s\n", cmd);
        rc = 2;
    }

    return rc;
}

int main(int argc, char **argv)
{
    if (argc < 3) {
        fprintf(stderr,
            "usage: %s <image> <command> [args]\n"
            "\ncommands:\n"
            "  probe              inspect the superblock without mounting\n"
            "  format [gen] [bs] [label]\n"
            "                     write a fresh filesystem (gen 2/3/4, default 4)\n"
            "  ls [path]          recursive listing (default /)\n"
            "  stat <path>        show inode attributes\n"
            "  cat <path>         write file contents to stdout\n"
            "  extents <path>     show the logical->physical extent map\n"
            "  xattr <path>       list extended attributes\n"
            "  orphans            show the head of the orphan list\n"
            "  decrypt <out>      write the decrypted payload to a file\n"
            "                     (needs EXT4DUMP_LUKS_KEYFILE)\n"
            "\nwrite commands (open the image read-write):\n"
            "  mkdir <path>            create a directory\n"
            "  create <path> [mode]    create an empty file\n"
            "  write <path> <text>     write text at offset 0\n"
            "  append <path> <text>    append text at end of file\n"
            "  script <file>           run one command per line, all inside\n"
            "                          a single mount ('-' reads stdin)\n"
            "  rm <path>               remove a file or empty directory\n"
            "  rm-open <path>...       remove the name only, as if the file\n"
            "                          were still open: the inode stays\n"
            "                          allocated and joins the orphan list\n"
            "  rm-cycle <path>...      rm-open followed by the release, i.e.\n"
            "                          the whole open-unlink lifecycle\n"
            "  release <inode>...      free an inode left by rm-open\n"
            "  mv <src> <dst>          rename/move\n"
            "  ln <target> <name>      create a hard link\n"
            "  symlink <target> <name> create a symbolic link\n"
            "  truncate <path> <size>  set file size\n"
            "  chmod <path> <mode>     set permission bits\n"
            "  getxattr <path> <name>  read one, or report why there is none\n"
            "  setxattr <path> <n> <v> set an extended attribute\n"
            "  rmxattr <path> <name>   remove an extended attribute\n"
            "  label <name>            set the volume label\n",
            argv[0]);
        return 2;
    }

    const char *image = argv[1];
    const char *cmd   = argv[2];

    ext4b_set_logger(logger, NULL);

    bool writable = is_write_cmd(cmd);
    int fd = open(image, writable ? O_RDWR : O_RDONLY);
    if (fd < 0) {
        perror("open");
        return 1;
    }
    struct stat st;
    if (fstat(fd, &st) != 0) {
        perror("fstat");
        return 1;
    }

    file_ctx fc = { .fd = fd, .fail_after = -1 };
    const char *fail_env = getenv("EXT4DUMP_FAIL_AFTER");
    if (fail_env)
        fc.fail_after = strtol(fail_env, NULL, 10);

    /*
     * Make this file behave like a drive with a volatile write cache.
     *
     * Unset, everything below is inert and writes go straight to the file as
     * they always have. Set, only a barrier makes a write durable and a cut
     * loses a reordered subset of whatever was in flight -- which is the
     * failure a disk image cannot otherwise produce, and the one that matters.
     */
    const char *cache_env = getenv("EXT4DUMP_WRITE_CACHE");
    if (cache_env) {
        fc.cache_bytes = (size_t)strtoull(cache_env, NULL, 10);
        fc.reorder_drop = 50;          /* half the queue never lands */
        fc.reorder_seed = 1;
        fc.rng = 1;

        const char *seed_env = getenv("EXT4DUMP_REORDER_SEED");
        if (seed_env)
            fc.reorder_seed = (uint32_t)strtoul(seed_env, NULL, 10);
        fc.rng = fc.reorder_seed ? fc.reorder_seed : 1u;

        const char *drop_env = getenv("EXT4DUMP_REORDER_DROP");
        if (drop_env) {
            fc.reorder_drop = (int)strtol(drop_env, NULL, 10);
            if (fc.reorder_drop < 0)   fc.reorder_drop = 0;
            if (fc.reorder_drop > 100) fc.reorder_drop = 100;
        }

        fc.ignore_barriers = getenv("EXT4DUMP_IGNORE_BARRIERS") != NULL;
    }

    /*
     * Optional LUKS layer.
     *
     * Set EXT4DUMP_LUKS_KEYFILE to the file holding the passphrase and the
     * image is treated as a container: the payload is decrypted on the way
     * through and every command works exactly as it does on a plain image.
     * That is the point -- it means the whole existing suite can be pointed at
     * encrypted volumes without any of the suites knowing.
     */
    /*
     * How big is it?
     *
     * fstat() answers for a file and reports zero for a device node, where the
     * size lives behind an ioctl instead. Without this, pointing any of these
     * commands at a real disk silently operates on a zero-length volume --
     * which is what a `format` of a USB stick did: it reported nothing and
     * changed nothing.
     */
    uint64_t dev_bytes = (uint64_t)st.st_size;
    if (dev_bytes == 0 && (S_ISBLK(st.st_mode) || S_ISCHR(st.st_mode))) {
        uint32_t sector = 0;
        uint64_t sectors = 0;
        if (ioctl(fd, DKIOCGETBLOCKSIZE, &sector) == 0 &&
            ioctl(fd, DKIOCGETBLOCKCOUNT, &sectors) == 0) {
            dev_bytes = sectors * (uint64_t)sector;
        } else {
            perror("DKIOCGETBLOCKCOUNT");
            return 1;
        }
    }
    if (dev_bytes == 0) {
        fprintf(stderr, "%s: zero-length device or image\n", argv[1]);
        return 1;
    }
    /* Both declared before the first `goto out`, so the cleanup path never
     * sees an indeterminate pointer or an uninitialised status. */
    ext4b_device *dev = NULL;
    int rc = 0;
    void *io_ctx = &fc;
    ext4b_read_fn  io_read  = file_read;
    ext4b_write_fn io_write = file_write;
    ext4b_flush_fn io_flush = file_flush;
    luks_device *luks = NULL;

    const char *keyfile = getenv("EXT4DUMP_LUKS_KEYFILE");
    if (keyfile) {
        luks = open_luks(&fc, keyfile, writable, &dev_bytes);
        if (!luks) { rc = 1; goto out; }
        io_ctx   = luks;
        io_read  = luks_device_read;
        io_write = luks_device_write;
        io_flush = luks_device_flush;
    }

    const uint32_t bs = 512;
    dev = ext4b_device_create(io_ctx, bs, dev_bytes / bs,
                              !writable, io_read, io_write, io_flush);
    if (!dev) {
        fprintf(stderr, "failed to create device\n");
        rc = 1;
        goto out;
    }

    if (strcmp(cmd, "format") == 0) {
        /* Only this command is slow enough to be worth a bar. See file_ctx. */
        fc.progress_total = dev_bytes / 62;
        fc.progress_started = fc.progress_last = time(NULL);

        ext4b_format_options opts;
        memset(&opts, 0, sizeof(opts));
        opts.generation = (argc > 3) ? atoi(argv[3]) : 4;
        opts.block_size = (argc > 4) ? (uint32_t)strtoul(argv[4], NULL, 10) : 0;
        opts.label      = (argc > 5) ? argv[5] : NULL;
        opts.journal    = (opts.generation != 2);

        /* A real driver takes the UUID from the platform's RNG. Here it comes
         * from the environment when set, so tests can format reproducibly. */
        const char *uuid_env = getenv("EXT4DUMP_UUID");
        if (uuid_env && strlen(uuid_env) >= 32) {
            for (int i = 0; i < 16; i++) {
                char byte[3] = { uuid_env[i*2], uuid_env[i*2+1], 0 };
                opts.uuid[i] = (uint8_t)strtoul(byte, NULL, 16);
            }
        } else {
            FILE *rng = fopen("/dev/urandom", "rb");
            if (!rng || fread(opts.uuid, 1, sizeof(opts.uuid), rng) != sizeof(opts.uuid)) {
                fprintf(stderr, "could not read random bytes for the volume UUID\n");
                if (rng) fclose(rng);
                rc = 1; goto out;
            }
            fclose(rng);
            /* RFC 4122 version 4 */
            opts.uuid[6] = (opts.uuid[6] & 0x0F) | 0x40;
            opts.uuid[8] = (opts.uuid[8] & 0x3F) | 0x80;
        }

        int r = ext4b_format(dev, &opts);
        progress_tick(&fc, true);
        if (r != 0) {
            fprintf(stderr, "format failed: %s\n", ext4b_strerror(r));
            rc = 1;
        }
        goto out;
    }

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

    /* A read-write mount normally settles the orphan list before returning,
     * which is exactly what a test trying to inspect an interrupted delete
     * does not want. */
    if (getenv("EXT4DUMP_KEEP_ORPHANS"))
        ext4b_set_orphan_cleanup(dev, false);

    int r = ext4b_mount(dev, !writable);
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
        /* The two flags a Linux user sets with chattr to stop a file being
         * changed. Worth showing, because a write that returns EPERM is
         * otherwise indistinguishable from a permissions problem. */
        if (a.flags & (EXT4B_INODE_IMMUTABLE | EXT4B_INODE_APPEND_ONLY))
            printf("protected:  %s%s%s\n",
                   (a.flags & EXT4B_INODE_IMMUTABLE)   ? "immutable" : "",
                   ((a.flags & EXT4B_INODE_IMMUTABLE) &&
                    (a.flags & EXT4B_INODE_APPEND_ONLY)) ? " + " : "",
                   (a.flags & EXT4B_INODE_APPEND_ONLY) ? "append-only" : "");
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

    } else if (strcmp(cmd, "getxattr") == 0) {
        /* Reads one attribute by name, and -- the reason this exists -- prints
         * the errno when there is none. macOS requires ENOATTR there, and
         * getting that wrong is enough to stop Finder copying a file. */
        if (argc < 5) { fprintf(stderr, "getxattr needs a path and a name\n"); rc = 2; goto unmount; }
        uint32_t ino = resolve(dev, argv[3], NULL);
        if (!ino) { rc = 1; goto unmount; }
        uint8_t value[4096];
        size_t  value_len = 0;
        r = ext4b_getxattr(dev, ino, argv[4], value, sizeof value, &value_len);
        if (r != 0) {
            fprintf(stderr, "getxattr: %s\n", strerror(r));
            rc = 1;
        } else {
            fwrite(value, 1, value_len, stdout);
            fputc('\n', stdout);
        }

    } else if (strcmp(cmd, "decrypt") == 0) {
        /* Write the decrypted payload out, so that tools which know nothing
         * about LUKS -- e2fsck and debugfs above all -- can be pointed at it.
         * Without this the oracle the whole test suite rests on cannot see
         * inside a container. */
        if (!luks) { fprintf(stderr, "decrypt needs EXT4DUMP_LUKS_KEYFILE\n"); rc = 2; goto unmount; }
        if (argc < 4) { fprintf(stderr, "decrypt needs an output path\n"); rc = 2; goto unmount; }
        FILE *out = fopen(argv[3], "wb");
        if (!out) { perror("decrypt output"); rc = 1; goto unmount; }
        uint8_t chunk[64 * 1024];
        uint64_t done = 0;
        while (done < dev_bytes) {
            size_t want = dev_bytes - done < sizeof(chunk)
                        ? (size_t)(dev_bytes - done) : sizeof(chunk);
            if (luks_device_read(luks, chunk, done, want) != 0) {
                fprintf(stderr, "decrypt: read failed at %llu\n",
                        (unsigned long long)done);
                rc = 1; break;
            }
            if (fwrite(chunk, 1, want, out) != want) { perror("write"); rc = 1; break; }
            done += want;
        }
        fclose(out);
        if (rc == 0)
            fprintf(stderr, "decrypted %llu bytes\n", (unsigned long long)done);

    } else if (strcmp(cmd, "orphans") == 0) {
        uint32_t head = 0;
        r = ext4b_orphan_head(dev, &head);
        if (r != 0) { fprintf(stderr, "orphans: %s\n", ext4b_strerror(r)); rc = 1; }
        else printf("orphan head: %u\n", head);

    } else if (writable) {
        rc = run_write_command(dev, argc, argv);

    } else {
        fprintf(stderr, "unknown command: %s\n", cmd);
        rc = 2;
    }

unmount:
    ext4b_unmount(dev);
out:
    ext4b_device_destroy(dev);
    luks_device_close(luks);
    close(fd);
    if (getenv("EXT4DUMP_REPORT_WRITES"))
        fprintf(stderr, "writes=%ld\n", fc.writes);
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
