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
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <sys/stat.h>
#include <sys/ioctl.h>
#include <inttypes.h>

/*
 * Three things this tool needs are spelled differently on the two systems it
 * has to build on, and only three. It runs on macOS because that is where the
 * driver ships, and on Linux because that is where the oracle suites can be
 * run without a virtual machine -- the Linux kernel's own ext4 is the second
 * opinion on everything this writes, and a CI runner cannot give us that on
 * macOS at all.
 *
 * The differences are: how you ask a block device its size, how you ask a
 * drive to actually commit its cache, and how you preallocate. Everything
 * else in this file is POSIX.
 */
#ifdef __APPLE__
#include <sys/disk.h>   /* DKIOCGETBLOCKCOUNT */
#else
#include <linux/fs.h>   /* BLKGETSIZE64, BLKSSZGET */
#endif

/* One write held in the modelled drive's volatile cache; see below. */
typedef struct {
    uint64_t seq;               /* issue index; names this write in the trace */
    uint64_t off;
    size_t   len;
    uint8_t *data;
} pending_write;

typedef struct {
    int fd;

    /* Sector size the medium insists on, or 0 when it does not care.
     *
     * A raw character device (/dev/rdiskN) accepts only transfers that start
     * on a sector boundary and are a whole number of sectors; the buffered
     * node (/dev/diskN) accepts anything and pays for it. Formatting an 8 GB
     * volume on a USB stick through the buffered node ran at 0.4 MB/s -- five
     * minutes for 129 MB that the raw node moves in seconds -- because every
     * transfer goes through the block layer a sector at a time. So the tool
     * aligns its own I/O and uses the fast node: whole-sector transfers pass
     * straight through, and the few that are not (the superblock lives at
     * offset 1024) become a read-modify-write of the sectors they touch. */
    uint32_t align;
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

    /*
     * Media model and meter, for measuring I/O shape rather than bytes.
     *
     * A disk image reaches APFS through the page cache, where a 4 KiB read
     * costs about the same as a 512 KiB one -- which hides exactly the
     * pathology that matters on a USB stick, where every command has a fixed
     * setup cost and the transfer itself is comparatively cheap. The journal
     * replay hang was invisible on images for this reason.
     *
     * EXT4DUMP_IO_LATENCY_US charges that fixed cost per read/write call, and
     * EXT4DUMP_IO_BW_MBS charges for the bytes, so a file behaves like the
     * medium that produced the incident. EXT4DUMP_IO_STATS=1 prints op and
     * byte counts at exit; the counters tell the suite whether an access
     * pattern changed, with no timing flakiness involved.
     */
    uint64_t reads, read_bytes;
    uint64_t write_ops, write_bytes;
    uint64_t flushes;
    uint32_t latency_us;             /* per-op fixed cost; 0 disables */
    uint32_t bw_mbs;                 /* transfer rate; 0 means infinite */

    /*
     * EIO injection: the opposite failure model from fail_after. That one is
     * a power cut -- writes vanish while reporting success, because a real
     * cut hands the filesystem no errno. This one is a *failing* medium: the
     * N-th read or write call answers EIO, once, or forever after with
     * `sticky` (a stick that died mid-session). Both are needed: the journal
     * protects against the first, and the error-propagation paths -- the ones
     * that historically returned success over a failed write -- are only
     * testable with the second.
     *
     * Ordinals are 1-based counts of read/write calls (the same counters the
     * meter reports). ext4dump is single-threaded, so for a fixed fixture and
     * command the N-th call is always the same block: run once with
     * EXT4DUMP_TRACE to map ordinal to offset, then aim. Every injection
     * prints an EIO-INJECT line so a suite can assert the fault actually
     * fired -- a red test whose fault was never reached proves nothing.
     */
    uint64_t eio_read_at;            /* 0 disables */
    uint64_t eio_write_at;           /* 0 disables */
    bool     eio_sticky;

    /*
     * The bad-sector model: every I/O covering this byte offset fails, other
     * I/O succeeds. Ordinal injection cannot express this -- the block cache
     * legitimately *retries* a failed write-back from a later flush point, so
     * a once-only fault at the right ordinal is healed by the very next
     * attempt, and what a dying medium actually serves is a region that
     * fails every time. 1-based-ish: UINT64_MAX disables (offset 0 is real).
     */
    uint64_t eio_read_off;
    uint64_t eio_write_off;
    uint32_t       reorder_seed;
    uint32_t       rng;             /* seeded; drives eviction and the crash */
    int            reorder_drop;     /* percent of the pending queue lost */
    bool           ignore_barriers;  /* a drive that lies about flushing */
    FILE          *trace;            /* EXT4DUMP_TRACE; NULL means silent */

    /*
     * Progress, for the one operation slow enough to need it.
     *
     * Formatting a 16 GB volume writes about 260 MB of inode tables, bitmaps
     * and journal. On an SSD that is under a second and nobody notices; on a
     * USB stick it is minutes of silence, which is indistinguishable from a
     * hang -- and was mistaken for one.
     *
     * `progress_total` is an estimate, not a measurement, and it had to be
     * re-derived once the format stopped zeroing every inode table: the old
     * figure assumed that work and so read a finished format as 5% done,
     * which is worse than no bar at all. What a format writes now is mostly
     * fixed -- the two block groups that cannot be left uninitialised -- plus
     * the descriptors, which scale with the group count. Measured across
     * sizes: 4.3 MB at 1 GB, 4.4 at 2, 7.0 at 8, 11.3 at 32.
     *
     * The bar is still capped at 99% until the format returns, because an
     * estimate that reaches 100% early is a bar that lies twice.
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

/*
 * The trace: one line per cache-model event, to wherever EXT4DUMP_TRACE
 * points ("-" or "1" for stderr, anything else a path).
 *
 * What it is for: when a cut leaves a filesystem the kernel cannot recover,
 * the damage says almost nothing about the cause. The trace says which writes
 * landed and which were dropped, relative to which barriers -- and
 * Tests/classify_trace.sh turns the offsets into write classes (journal
 * superblock, log, home metadata), which is the difference between a
 * diagnosis and a guess.
 */
static void trace_ev(file_ctx *c, const char *fmt, ...)
{
    if (!c->trace)
        return;
    va_list ap;
    va_start(ap, fmt);
    vfprintf(c->trace, fmt, ap);
    va_end(ap);
    fputc('\n', c->trace);
}

/* Grow the pending queue by one entry, taking a copy of the caller's bytes. */
static int cache_append(file_ctx *c, uint64_t seq, uint64_t off, const void *buf,
                        size_t len)
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

    c->pending[c->pending_count].seq  = seq;
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
    trace_ev(c, "TRC BARRIER pend=%zu", c->pending_count);
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
        trace_ev(c, "TRC EVICT seq=%llu off=%llu len=%zu",
                 (unsigned long long)c->pending[i].seq,
                 (unsigned long long)c->pending[i].off, c->pending[i].len);
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
    trace_ev(c, "TRC CRASH seed=%u pend=%zu keep=%zu",
             c->reorder_seed, n, keep);
    for (size_t k = 0; k < keep; k++) {
        (void)cache_apply(c, order[k]);
        trace_ev(c, "TRC CRASH-APPLY seq=%llu off=%llu len=%zu",
                 (unsigned long long)c->pending[order[k]].seq,
                 (unsigned long long)c->pending[order[k]].off,
                 c->pending[order[k]].len);
    }
    for (size_t k = keep; k < n; k++)
        trace_ev(c, "TRC CRASH-DROP seq=%llu off=%llu len=%zu",
                 (unsigned long long)c->pending[order[k]].seq,
                 (unsigned long long)c->pending[order[k]].off,
                 c->pending[order[k]].len);

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

/* Charge one command's worth of media time: the fixed per-command cost plus
 * the transfer. usleep() has ~1 ms granularity jitter, so accumulate the debt
 * and sleep only when it is big enough to be paid accurately. */
static void media_charge(file_ctx *c, size_t len)
{
    static uint64_t debt_us;
    if (c->latency_us)
        debt_us += c->latency_us;
    if (c->bw_mbs)
        debt_us += (uint64_t)len / c->bw_mbs;   /* bytes / (MB/s) == us */
    if (debt_us >= 2000) {
        usleep((useconds_t)debt_us);
        debt_us = 0;
    }
}

/* pread/pwrite that respect the medium's transfer rules. With align == 0, or
 * a request that already lands on sector boundaries, these are the bare
 * syscalls. Otherwise the surrounding sectors are read, patched and written
 * back -- correct on any device, and only reached by the handful of
 * sub-sector writes a format performs. */
static int aligned_pread(file_ctx *c, void *buf, uint64_t off, size_t len)
{
    uint32_t a = c->align;
    if (a <= 1 || ((off % a) == 0 && (len % a) == 0))
        return pread(c->fd, buf, len, (off_t)off) == (ssize_t)len ? 0 : EIO;

    uint64_t first = off - (off % a);
    uint64_t last  = ((off + len + a - 1) / a) * a;
    size_t   span  = (size_t)(last - first);

    uint8_t *tmp = malloc(span);
    if (!tmp)
        return ENOMEM;

    int rc = 0;
    if (pread(c->fd, tmp, span, (off_t)first) != (ssize_t)span)
        rc = EIO;
    else
        memcpy(buf, tmp + (off - first), len);

    free(tmp);
    return rc;
}

static int aligned_pwrite(file_ctx *c, const void *buf, uint64_t off, size_t len)
{
    uint32_t a = c->align;
    if (a <= 1 || ((off % a) == 0 && (len % a) == 0))
        return pwrite(c->fd, buf, len, (off_t)off) == (ssize_t)len ? 0 : EIO;

    uint64_t first = off - (off % a);
    uint64_t last  = ((off + len + a - 1) / a) * a;
    size_t   span  = (size_t)(last - first);

    uint8_t *tmp = malloc(span);
    if (!tmp)
        return ENOMEM;

    int rc = 0;
    /* Read first: the sectors at the edges carry bytes this write does not
     * own, and writing them back as anything else would corrupt them. */
    if (pread(c->fd, tmp, span, (off_t)first) != (ssize_t)span) {
        rc = EIO;
    } else {
        memcpy(tmp + (off - first), buf, len);
        if (pwrite(c->fd, tmp, span, (off_t)first) != (ssize_t)span)
            rc = EIO;
    }

    free(tmp);
    return rc;
}

static int file_read(void *ctx, void *buf, uint64_t off, size_t len)
{
    file_ctx *c = ctx;
    c->reads++;
    c->read_bytes += len;
    trace_ev(c, "TRC R seq=%llu off=%llu len=%zu",
             (unsigned long long)(c->reads - 1), (unsigned long long)off, len);
    if (c->eio_read_at &&
        (c->reads == c->eio_read_at ||
         (c->eio_sticky && c->reads >= c->eio_read_at))) {
        fprintf(stderr, "EIO-INJECT read #%llu off=%llu len=%zu\n",
                (unsigned long long)c->reads, (unsigned long long)off, len);
        return EIO;
    }
    if (c->eio_read_off != UINT64_MAX &&
        off <= c->eio_read_off && c->eio_read_off < off + len) {
        fprintf(stderr, "EIO-INJECT read #%llu off=%llu len=%zu\n",
                (unsigned long long)c->reads, (unsigned long long)off, len);
        return EIO;
    }
    media_charge(c, len);
    int rrc = aligned_pread(c, buf, off, len);
    if (rrc != 0)
        return rrc;

    if (c->cache_bytes)
        cache_overlay(c, buf, off, len);
    return 0;
}

static int file_write(void *ctx, const void *buf, uint64_t off, size_t len)
{
    file_ctx *c = ctx;
    c->write_ops++;
    c->write_bytes += len;
    /* Before the power-cut and cache models: a write the medium refused
     * never entered anyone's queue. */
    if (c->eio_write_at &&
        (c->write_ops == c->eio_write_at ||
         (c->eio_sticky && c->write_ops >= c->eio_write_at))) {
        fprintf(stderr, "EIO-INJECT write #%llu off=%llu len=%zu\n",
                (unsigned long long)c->write_ops, (unsigned long long)off, len);
        return EIO;
    }
    if (c->eio_write_off != UINT64_MAX &&
        off <= c->eio_write_off && c->eio_write_off < off + len) {
        fprintf(stderr, "EIO-INJECT write #%llu off=%llu len=%zu\n",
                (unsigned long long)c->write_ops, (unsigned long long)off, len);
        return EIO;
    }
    media_charge(c, len);

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
    trace_ev(c, "TRC W seq=%ld off=%llu len=%zu",
             c->writes, (unsigned long long)off, len);
    long seq = c->writes;
    c->writes++;

    /* Into the cache, not onto the medium. Only a barrier puts it there. */
    if (c->cache_bytes) {
        if (c->pending_bytes + len > c->cache_bytes && cache_evict(c) != 0)
            return EIO;
        return cache_append(c, (uint64_t)seq, off, buf, len);
    }

    return aligned_pwrite(c, buf, off, len);
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
    /* Counted and priced like any command: on a real stick the cache flush is
     * one of the most expensive things a driver can ask for, and a change
     * that trades writes for barriers must not read as an improvement. */
    c->flushes++;
    media_charge(c, 0);
    if (c->crashed)
        return 0;           /* a flush after the cut reaches nothing */

    if (c->cache_bytes) {
        /* A drive that reports cache-flush support and does not honour it is
         * a real and depressingly common thing. Modelling one is also the
         * negative control: with barriers ignored the suite must fail, and a
         * crash-consistency test that cannot be made to fail proves nothing. */
        if (c->ignore_barriers) {
            trace_ev(c, "TRC BARRIER-IGNORED pend=%zu", c->pending_count);
            return 0;
        }
        return cache_commit(c);
    }

    /*
     * F_FULLFSYNC is the macOS call that asks the drive to commit its cache,
     * as against fsync, which only gets the data out of the kernel. Linux has
     * no equivalent for a file descriptor -- fdatasync is the closest, and on
     * a real drive it is a weaker promise. That matters for the crash suites'
     * meaning, not for their mechanics: they run against image files, where
     * both calls reach the host filesystem's page cache and no further.
     */
#ifdef __APPLE__
    if (fcntl(c->fd, F_FULLFSYNC) == 0)
        return 0;
    if (errno != ENOTSUP && errno != ENOTTY && errno != EINVAL)
        return EIO;
#else
    if (fdatasync(c->fd) == 0)
        return 0;
    if (errno != EINVAL && errno != ENOTSUP)
        return EIO;
#endif

    return fsync(c->fd) == 0 ? 0 : EIO;
}

/* EXT4DUMP_IO_STATS: one machine-readable line on exit, whatever the path out.
 * atexit() because the command handlers return through several doors. */
static file_ctx *io_stats_ctx;
static void io_stats_report(void)
{
    file_ctx *c = io_stats_ctx;
    if (!c)
        return;
    fprintf(stderr,
            "IOSTATS reads=%" PRIu64 " read_bytes=%" PRIu64
            " writes=%" PRIu64 " write_bytes=%" PRIu64
            " flushes=%" PRIu64 "\n",
            c->reads, c->read_bytes, c->write_ops, c->write_bytes,
            c->flushes);
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

/* ------------------------------------------------------------ xattrwalk -- */
/*
 * Attributes of EVERY inode reachable from a directory, not one named file.
 *
 * `xattr <path>` needs a path, and a path needs the tree to be walkable to
 * that point. The in-process fuzzer does not: it lists attributes on every
 * inode a directory hands it, which is how it reached a heap-buffer-overflow
 * in ext4_xattr_is_ibody_valid on an image where the named file could not be
 * resolved at all. A finding the release tool cannot reproduce is a finding
 * nobody else can confirm, so the tool grew the same walk.
 *
 * Both halves, because they are different parsers: listing walks the entry
 * headers, and getxattr is what reads a value offset.
 */
typedef struct {
    ext4b_device *dev;
    uint32_t      inode;
    unsigned long inodes;
    unsigned long attrs;
    unsigned long lookups;
    char          names[32][256];
    size_t        nnames;
} xwalk_ctx;

static bool xwalk_name(void *ctx, const char *name, size_t name_len)
{
    xwalk_ctx *x = (xwalk_ctx *)ctx;
    if (x->nnames >= 32)
        return false;
    if (name_len > 255)
        name_len = 255;
    memcpy(x->names[x->nnames], name, name_len);
    x->names[x->nnames][name_len] = '\0';
    x->nnames++;
    x->attrs++;
    return true;
}

static void xwalk_inode(xwalk_ctx *x, uint32_t ino)
{
    static uint8_t value[65536];
    x->inodes++;
    x->nnames = 0;
    if (ext4b_listxattr(x->dev, ino, xwalk_name, x) != 0)
        return;
    for (size_t i = 0; i < x->nnames; i++) {
        size_t vlen = 0;
        (void)ext4b_getxattr(x->dev, ino, x->names[i], value, sizeof value, &vlen);
    }
}

/*
 * A lookup is not a slower readdir.
 *
 * readdir walks a directory's leaves linearly; ext4b_lookup enters the dx
 * index and descends it, which is different code and the code an indexed
 * directory's corruption lives in. One lookup of a name that cannot be there
 * forces a full descent to a leaf whatever the entries say -- and a fixture
 * whose finding is in that descent cannot be reproduced by `ls` at all, which
 * is how one of them arrived here reproducible only from the fuzzer.
 */
static void xwalk_lookups(xwalk_ctx *x, uint32_t dir,
                          const char (*names)[256], size_t n)
{
    uint32_t out = 0;
    ext4b_item_type t = EXT4B_TYPE_UNKNOWN;
    for (size_t i = 0; i < n; i++)
        (void)ext4b_lookup(x->dev, dir, names[i], strlen(names[i]), &out, &t);

    static const char absent[] = ".no-such-name-0e5a1f";
    (void)ext4b_lookup(x->dev, dir, absent, sizeof(absent) - 1, &out, &t);
}

static bool xwalk_dirent(void *ctx, const char *name, size_t name_len,
                         uint32_t ino, ext4b_item_type type,
                         uint64_t next_cookie);

/* Names seen in one directory, for the lookup pass over it. */
typedef struct { char names[64][256]; size_t n; } xwalk_names;

static bool xwalk_collect(void *ctx, const char *name, size_t name_len,
                          uint32_t ino, ext4b_item_type type,
                          uint64_t next_cookie)
{
    (void)ino; (void)type; (void)next_cookie;
    xwalk_names *c = (xwalk_names *)ctx;
    if (c->n >= 64) return false;
    if (name_len > 255) name_len = 255;
    memcpy(c->names[c->n], name, name_len);
    c->names[c->n][name_len] = '\0';
    c->n++;
    return true;
}

static void xwalk_dir(xwalk_ctx *x, uint32_t ino, unsigned depth)
{
    if (depth > 32)
        return;
    xwalk_inode(x, ino);

    /* Collect first, then look the names up: the lookup path and the readdir
     * path must not be interleaved, because one of them holds a block. */
    {
        static xwalk_names collected;
        collected.n = 0;
        (void)ext4b_readdir(x->dev, ino, 0, xwalk_collect, &collected);
        xwalk_lookups(x, ino, (const char (*)[256])collected.names, collected.n);
        x->lookups += collected.n + 1;
    }

    uint32_t saved = x->inode;
    x->inode = depth;
    (void)ext4b_readdir(x->dev, ino, 0, xwalk_dirent, x);
    x->inode = saved;
}

static bool xwalk_dirent(void *ctx, const char *name, size_t name_len,
                         uint32_t ino, ext4b_item_type type,
                         uint64_t next_cookie)
{
    (void)next_cookie;
    xwalk_ctx *x = (xwalk_ctx *)ctx;
    if ((name_len == 1 && name[0] == '.') ||
        (name_len == 2 && name[0] == '.' && name[1] == '.'))
        return true;
    if (x->inodes > 4096)
        return false;
    if (type == EXT4B_TYPE_DIR)
        xwalk_dir(x, ino, (unsigned)x->inode + 1);
    else
        xwalk_inode(x, ino);
    return true;
}

/* ----------------------------------------------------------------- main -- */

static int cmd_cat(ext4b_device *dev, const char *path);
static int cmd_extents(ext4b_device *dev, const char *path);
static int cmd_fragstat(ext4b_device *dev, const char *path);

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
    static const char *w[] = { "prealloc", "trim",
                               "mkdir", "create", "write", "append", "put", "interleave", "rm",
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
 *
 * EXT4DUMP_SCRIPT_CONTINUE=1 keeps going after a failing command instead of
 * stopping at the first one, and reports how many failed. Stopping is the
 * right default for a script that describes a filesystem to build, but it
 * cannot model the workload that matters most: an application that keeps
 * writing to a volume that has started refusing -- a full one above all,
 * where every later call exercises an error path with a live journal behind
 * it. The mounted driver serves hundreds of those; the offline tool stopped
 * at the first, so the whole class was untested.
 */
static int run_script(ext4b_device *dev, const char *path)
{
    FILE *f = (strcmp(path, "-") == 0) ? stdin : fopen(path, "r");
    if (!f) { perror(path); return 1; }

    const char *cont = getenv("EXT4DUMP_SCRIPT_CONTINUE");
    bool keep_going = cont && *cont && strcmp(cont, "0") != 0;
    unsigned long failed = 0;
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
            if (!keep_going)
                break;
            failed++;
            rc = 0;
        }
    }

    if (keep_going && failed)
        fprintf(stderr, "script: %lu command(s) failed, kept going\n", failed);

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
        if (argc < 5) { fprintf(stderr, "%s needs <path> <text> [offset]\n", cmd); rc = 2; return rc; }
        uint32_t ino = resolve(dev, argv[3], NULL);
        if (!ino) { rc = 1; return rc; }
        uint64_t off = 0;
        if (strcmp(cmd, "append") == 0) {
            ext4b_attrs a;
            if (ext4b_getattr(dev, ino, &a) == 0) off = a.size;
        } else if (argc >= 6) {
            /* Explicit offset -- the only way to reach the far end of the
             * address space from a test (a huge sparse write). */
            off = strtoull(argv[5], NULL, 10);
        }
        size_t written = 0;
        r = ext4b_write(dev, ino, off, argv[4], strlen(argv[4]), &written);
        if (r != 0) { fprintf(stderr, "write: %s\n", ext4b_strerror(r)); rc = 1; }
        else printf("wrote %zu bytes at %llu\n", written, (unsigned long long)off);

    } else if (strcmp(cmd, "put") == 0) {
        /* Bulk data, which `write` cannot express: it takes its payload from
         * the command line. Copying a real file in is the only way to measure
         * what the data path costs per megabyte -- the thing a USB stick
         * charges for and a page-cached disk image hides. Writes go in
         * `chunk` pieces so the size of the caller's buffer is a dimension
         * too: FSKit hands us up to a megabyte at a time, and the shim's
         * behaviour differs by how much it is given at once. */
        if (argc < 5) {
            fprintf(stderr, "put needs <path> <host-file> [chunk-bytes]\n");
            rc = 2; return rc;
        }
        FILE *in = fopen(argv[4], "rb");
        if (!in) { perror(argv[4]); rc = 1; return rc; }

        size_t chunk = (argc >= 6) ? (size_t)strtoull(argv[5], NULL, 10)
                                   : (1u << 20);
        if (chunk == 0) chunk = 1u << 20;
        void *buf = malloc(chunk);
        if (!buf) { fclose(in); fprintf(stderr, "put: out of memory\n"); rc = 1; return rc; }

        uint32_t ino = resolve(dev, argv[3], NULL);
        if (!ino) {
            uint32_t parent = resolve_parent(dev, argv[3], &name, &name_len);
            if (!parent) { free(buf); fclose(in); rc = 1; return rc; }
            r = ext4b_create(dev, parent, name, name_len, EXT4B_TYPE_FILE,
                             0644, (uint32_t)getuid(), (uint32_t)getgid(), &ino);
            if (r != 0) {
                fprintf(stderr, "put: %s\n", ext4b_strerror(r));
                free(buf); fclose(in); rc = 1; return rc;
            }
        }

        uint64_t off = 0;
        size_t got;
        while ((got = fread(buf, 1, chunk, in)) > 0) {
            size_t written = 0;
            r = ext4b_write(dev, ino, off, buf, got, &written);
            if (r != 0) {
                fprintf(stderr, "put: %s\n", ext4b_strerror(r));
                rc = 1; break;
            }
            off += written;
            if (written != got) {
                fprintf(stderr, "put: short write (%zu of %zu)\n", written, got);
                rc = 1; break;
            }
        }
        free(buf); fclose(in);
        if (rc == 0) printf("put %llu bytes\n", (unsigned long long)off);

    } else if (strcmp(cmd, "interleave") == 0) {
        /* Does interleaved allocation fragment files?
         *
         * A Finder copy onto a stick came back 89% non-contiguous while the
         * same corpus onto an image was 2.4%. The mechanism proposed for that
         * is locality: ext4_ext_find_goal returns the end of an inode's last
         * extent, the append path asks for a run sized to the current write,
         * and consecutive writes to one file stay contiguous only while
         * nothing else allocates at that goal in between. Seven worker threads
         * and a slow medium widening the gap between write calls is exactly
         * the "in between" the hypothesis needs.
         *
         * This models it with no threads and no timing at all, which is the
         * point. `round` walks the files a chunk at a time; `serial` finishes
         * each file before starting the next; everything else -- byte count,
         * chunk size, volume, single mount -- is identical. If the mechanism
         * is real the two orders give different fragmentation, and the problem
         * is reproducible on an image in seconds. If they give the same
         * figure, interleaving is not what fragments and the hypothesis is
         * wrong: say so rather than fitting a fix to it.
         */
        if (argc < 5) {
            fprintf(stderr,
                    "interleave needs <count> <MiB-each> [chunk-KiB] [round|serial]\n");
            rc = 2; return rc;
        }
        long count = strtol(argv[3], NULL, 10);
        long mib   = strtol(argv[4], NULL, 10);
        size_t chunk = (argc >= 6) ? (size_t)strtoull(argv[5], NULL, 10) * 1024
                                   : 64u * 1024;
        bool serial = (argc >= 7 && strcmp(argv[6], "serial") == 0);
        if (count < 1 || count > 512 || mib < 1 || chunk == 0) {
            fprintf(stderr, "interleave: implausible arguments\n");
            rc = 2; return rc;
        }

        uint64_t bytes_each = (uint64_t)mib << 20;
        uint32_t *inos = calloc((size_t)count, sizeof *inos);
        void *pattern = malloc(chunk);
        if (!inos || !pattern) {
            free(inos); free(pattern);
            fprintf(stderr, "interleave: out of memory\n"); rc = 1; return rc;
        }
        /* Filled per file rather than once: one repeated byte, distinct per
         * file, so a suite can read each one back and see that it is whole
         * and entirely its own. Counting extents without checking the bytes
         * would measure the wrong half of an allocator change. */

        for (long i = 0; i < count && rc == 0; i++) {
            char path[64];
            snprintf(path, sizeof path, "/il-%03ld.bin", i);
            uint32_t parent = resolve_parent(dev, path, &name, &name_len);
            if (!parent) { rc = 1; break; }
            r = ext4b_create(dev, parent, name, name_len, EXT4B_TYPE_FILE,
                             0644, (uint32_t)getuid(), (uint32_t)getgid(),
                             &inos[i]);
            if (r != 0) {
                fprintf(stderr, "interleave: %s\n", ext4b_strerror(r));
                rc = 1;
            }
        }

        /* One nest for both orders: serial runs `count` passes over one file
         * each, round-robin runs a single pass over all of them. */
        uint64_t total = 0;
        for (long pass = 0; pass < (serial ? count : 1) && rc == 0; pass++) {
            long first = serial ? pass : 0;
            long last  = serial ? pass + 1 : count;
            for (uint64_t off = 0; off < bytes_each && rc == 0; off += chunk) {
                size_t n = (bytes_each - off < chunk)
                         ? (size_t)(bytes_each - off) : chunk;
                for (long i = first; i < last && rc == 0; i++) {
                    size_t w = 0;
                    memset(pattern, 'A' + (int)(i % 26), n);
                    r = ext4b_write(dev, inos[i], off, pattern, n, &w);
                    if (r != 0) {
                        fprintf(stderr, "interleave: %s\n", ext4b_strerror(r));
                        rc = 1; break;
                    }
                    if (w != n) {
                        fprintf(stderr, "interleave: short write (%zu of %zu)\n",
                                w, n);
                        rc = 1; break;
                    }
                    total += w;
                }
            }
        }
        free(inos); free(pattern);
        if (rc == 0) {
            printf("interleave %s: %ld file(s), %llu bytes each, "
                   "%zu-byte writes, %llu bytes total\n",
                   serial ? "serial" : "round", count,
                   (unsigned long long)bytes_each, chunk,
                   (unsigned long long)total);
        } else {
            /* What the volume still thinks it has, reported from INSIDE the
             * mount. A driver that reserves space ahead of a write is holding
             * blocks no file is using; unmounting returns them, so a free
             * count read afterwards cannot see the stranding and would report
             * a volume that filled up perfectly. This is the only place the
             * question can be asked. */
            uint64_t fb = 0, tb = 0;
            if (ext4b_free_blocks_raw(dev, &fb, &tb) == 0)
                printf("interleave stopped after %llu bytes with %llu of %llu "
                       "block(s) free\n",
                       (unsigned long long)total,
                       (unsigned long long)fb, (unsigned long long)tb);
        }

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

    } else if (strcmp(cmd, "prealloc") == 0) {
        if (argc < 6) { fprintf(stderr, "prealloc needs <path> <offset> <bytes>\n"); rc = 2; return rc; }
        uint32_t ino = resolve(dev, argv[3], NULL);
        if (!ino) { rc = 1; return rc; }
        uint64_t off = strtoull(argv[4], NULL, 10);
        uint64_t len = strtoull(argv[5], NULL, 10);
        uint64_t got = 0;
        r = ext4b_preallocate(dev, ino, off, len, &got);
        if (r != 0) { fprintf(stderr, "prealloc: %s\n", ext4b_strerror(r)); rc = 1; }
        else printf("preallocated %llu bytes\n", (unsigned long long)got);

    } else if (strcmp(cmd, "trim") == 0) {
        /*
         * Release the tail of a preallocation, which is what the mounted
         * driver does at the end of every Finder copy. It had no verb here,
         * so no offline suite had ever driven it -- and the field volume
         * failed with "trim preallocation 791: I/O error" while its free
         * count climbed by a whole block group at a time.
         */
        if (argc < 4) { fprintf(stderr, "trim needs <path>\n"); rc = 2; return rc; }
        uint32_t ino = resolve(dev, argv[3], NULL);
        if (!ino) { rc = 1; return rc; }
        r = ext4b_trim_preallocation(dev, ino);
        if (r != 0) { fprintf(stderr, "trim: %s\n", ext4b_strerror(r)); rc = 1; }

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
    /*
     * Which build this is, answered without a volume.
     *
     * The app reports its revision from a plist the Makefile re-stamps on
     * every commit; this one is compiled into the core, and the two are only
     * the same fact if the core was rebuilt. When they drift, a hardware
     * session reads as fresh while the code under it is not -- so preflight
     * checks this against the working tree before anything is measured.
     */
    if (argc == 2 && (strcmp(argv[1], "version") == 0 ||
                      strcmp(argv[1], "--version") == 0)) {
        printf("%s\n", EXT4B_BUILD_ID);
        return 0;
    }

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
        "  fragstat [path]    how fragmented everything under path is:\n"
        "                     extents per file and bytes per extent, which\n"
        "                     is what e2fsck's %% non-contiguous cannot say\n"
            "  xattr <path>       list extended attributes\n"
            "  walk [path]        the whole read-only walk the fuzzer does:\n"
            "                     readdir, a lookup of every name AND of one\n"
            "                     that cannot be there (which is what enters\n"
            "                     the htree index), and every inode's\n"
            "                     attributes listed and read back. Reaches\n"
            "                     what a named-file verb cannot on a damaged\n"
            "                     tree.  ('xattrwalk' is the old spelling.)\n"
            "  df                 free/available space as the OS is told it\n"
            "  groups [bad]       per-group free counts the allocator uses\n"
            "                     ('bad' lists only the groups that differ)\n"
            "  version            the build this tool was compiled at\n"
            "                     (used alone, without an image)\n"
            "  orphans            show the head of the orphan list\n"
            "  check              walk the tree and cross-check what it says\n"
            "                     (not e2fsck: no repair, no allocation data)\n"
            "  decrypt <out>      write the decrypted payload to a file\n"
            "                     (needs EXT4DUMP_LUKS_KEYFILE)\n"
            "\nwrite commands (open the image read-write):\n"
            "  mkdir <path>            create a directory\n"
            "  create <path> [mode]    create an empty file\n"
            "  write <path> <text>     write text at offset 0\n"
            "  put <path> <file> [n]   copy a host file in, n bytes per write\n"
            "  append <path> <text>    append text at end of file\n"
            "  interleave <n> <MiB> [chunk-KiB] [round|serial]\n"
            "                          write n files of MiB each, either a\n"
            "                          chunk at a time round-robin or one\n"
            "                          file after another -- the same bytes\n"
            "                          in two allocation orders, to measure\n"
            "                          what interleaving costs in extents\n"
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

    /* Prove the assertion failure path reports through the logger (stderr
     * here, os_log in the appex) rather than printing to a stdout no sandboxed
     * extension can be heard on. Aborts; needs no image. */
    if (strcmp(cmd, "__assert_selftest") == 0) {
        ext4b_trip_assert();
        return 0;   /* unreached: ext4b_trip_assert aborts */
    }

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

    /* Media model and meter; see file_ctx. */
    const char *lat_env = getenv("EXT4DUMP_IO_LATENCY_US");
    if (lat_env)
        fc.latency_us = (uint32_t)strtoul(lat_env, NULL, 10);
    const char *bw_env = getenv("EXT4DUMP_IO_BW_MBS");
    if (bw_env)
        fc.bw_mbs = (uint32_t)strtoul(bw_env, NULL, 10);
    if (getenv("EXT4DUMP_IO_STATS")) {
        io_stats_ctx = &fc;
        atexit(io_stats_report);
    }

    /* Alignment, forced. The aligned read/write path exists for raw
     * character devices, which means it runs only on real hardware and never
     * in a suite -- the exact shape of code that is wrong for a week without
     * anyone noticing. This makes a plain file demand the same alignment, so
     * the path can be tested where testing is cheap. */
    const char *align_env = getenv("EXT4DUMP_FORCE_ALIGN");
    if (align_env)
        fc.align = (uint32_t)strtoul(align_env, NULL, 10);

    /* EIO injection; see file_ctx. */
    const char *eio_r = getenv("EXT4DUMP_EIO_READ_AT");
    if (eio_r)
        fc.eio_read_at = strtoull(eio_r, NULL, 10);
    const char *eio_w = getenv("EXT4DUMP_EIO_WRITE_AT");
    if (eio_w)
        fc.eio_write_at = strtoull(eio_w, NULL, 10);
    fc.eio_sticky = getenv("EXT4DUMP_EIO_STICKY") != NULL;
    fc.eio_read_off = fc.eio_write_off = UINT64_MAX;
    const char *eio_ro = getenv("EXT4DUMP_EIO_READ_OFF");
    if (eio_ro)
        fc.eio_read_off = strtoull(eio_ro, NULL, 10);
    const char *eio_wo = getenv("EXT4DUMP_EIO_WRITE_OFF");
    if (eio_wo)
        fc.eio_write_off = strtoull(eio_wo, NULL, 10);

    /* EXT4DUMP_TRACE_WRITES was the old name for the stderr form. */
    const char *trace_env = getenv("EXT4DUMP_TRACE");
    if (!trace_env && getenv("EXT4DUMP_TRACE_WRITES"))
        trace_env = "-";
    if (trace_env) {
        fc.trace = (!strcmp(trace_env, "-") || !strcmp(trace_env, "1"))
                 ? stderr : fopen(trace_env, "w");
        if (!fc.trace) { perror(trace_env); return 1; }
    }

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
        bool got = false;
#ifdef __APPLE__
        uint64_t sectors = 0;
        if (ioctl(fd, DKIOCGETBLOCKSIZE, &sector) == 0 &&
            ioctl(fd, DKIOCGETBLOCKCOUNT, &sectors) == 0) {
            dev_bytes = sectors * (uint64_t)sector;
            got = true;
        }
#else
        /* Linux gives the size in bytes directly, and the sector size
         * separately. There is no character-device node for a disk to
         * address, so the alignment below never applies -- but the block
         * device does have a sector size and it is worth having. */
        {
            uint64_t bytes = 0;
            int ssz = 0;
            if (ioctl(fd, BLKGETSIZE64, &bytes) == 0 && bytes > 0) {
                dev_bytes = bytes;
                got = true;
                if (ioctl(fd, BLKSSZGET, &ssz) == 0 && ssz > 0)
                    sector = (uint32_t)ssz;
            }
        }
#endif
        if (got) {
            /* A raw character device transfers whole sectors only. Recording
             * the size here is what lets the tool address /dev/rdiskN, which
             * is the difference between a format that streams and one that
             * crawls through the buffered node a sector at a time. */
            if (S_ISCHR(st.st_mode) && sector > 1)
                fc.align = sector;
        } else {
            perror("could not read the device size");
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

    /*
     * Device block size. The default has always been 512, but the appex
     * passes the device's real sector size -- commonly 4096 -- and that is a
     * geometry the suites must be able to exercise: the byte-offset
     * arithmetic in the block callbacks, the alignment windows, and
     * ext4b_format's refusal to build a filesystem with blocks smaller than
     * the device's are all invisible at 512.
     */
    uint32_t bs = 512;
    const char *bs_env = getenv("EXT4DUMP_DEVICE_BSIZE");
    if (bs_env) {
        unsigned long v = strtoul(bs_env, NULL, 10);
        if (v < 512 || v > 65536 || (v & (v - 1)) != 0) {
            fprintf(stderr, "EXT4DUMP_DEVICE_BSIZE must be a power of two in [512, 65536]\n");
            rc = 1;
            goto out;
        }
        bs = (uint32_t)v;
    }
    if (dev_bytes % bs != 0) {
        fprintf(stderr, "device size %llu is not a multiple of block size %u\n",
                (unsigned long long)dev_bytes, bs);
        rc = 1;
        goto out;
    }
    dev = ext4b_device_create(io_ctx, bs, dev_bytes / bs,
                              !writable, io_read, io_write, io_flush);
    if (!dev) {
        fprintf(stderr, "failed to create device\n");
        rc = 1;
        goto out;
    }

    /* The batching knob lives here now, not in the shipping core. The suites
     * set EXT4B_TXN_BATCH to force batch=1 (transaction-per-operation) so a
     * crash cut lands mid-history; the appex uses the compiled-in default. */
    const char *batch_env = getenv("EXT4B_TXN_BATCH");
    if (batch_env) {
        unsigned long v = strtoul(batch_env, NULL, 10);
        if (v >= 1 && v <= 1024)
            ext4b_set_txn_batch(dev, (uint32_t)v);
    }

    if (strcmp(cmd, "format") == 0) {
        /* Only this command is slow enough to be worth a bar. See file_ctx. */
        {
            /* ~4 MiB fixed, plus ~32 KiB per 128 MiB block group. */
            uint64_t groups = dev_bytes / (128ull << 20);
            fc.progress_total = (4ull << 20) + groups * (32ull << 10);
        }
        fc.progress_started = fc.progress_last = time(NULL);

        ext4b_format_options opts;
        memset(&opts, 0, sizeof(opts));
        opts.generation = (argc > 3) ? atoi(argv[3]) : 4;
        opts.block_size = (argc > 4) ? (uint32_t)strtoul(argv[4], NULL, 10) : 0;
        opts.label      = (argc > 5) ? argv[5] : NULL;
        opts.journal    = (opts.generation != 2);

        /* The journal is sized from the volume by default, and the sizing is
         * what hides a whole class of bug: a log that never wraps during a
         * test cannot exercise what wrapping does. The reorder suite formats
         * with EXT4DUMP_JOURNAL_BLOCKS=1024 to make a big fixture carry the
         * minimum journal. */
        const char *jblocks_env = getenv("EXT4DUMP_JOURNAL_BLOCKS");
        if (jblocks_env)
            opts.journal_blocks = (uint32_t)strtoul(jblocks_env, NULL, 10);

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

    /*
     * Deliberate failures, for the mutation campaign's own red-first cells.
     *
     * Tests/run_fuzz_tests.sh classifies every mutant by what the tool did:
     * 134 is a crash, 137 is a hang, and a changed md5 on a read-only verb is
     * a write. Those three classifications are the whole product of the
     * suite, and a classifier that has never been shown to fire is a
     * classifier nobody has tested -- the campaign would report "300 mutants,
     * all clean" just as cheerfully if it were broken.
     *
     * EXT4DUMP_PLANT=abort trips a real lwext4 assertion, =spin never
     * returns, =write modifies the image through a second descriptor. Read
     * here in the tool, so scripts/check_ship_surface.sh is unaffected: the
     * shipping core still reads no environment.
     */
    const char *plant = getenv("EXT4DUMP_PLANT");
    if (plant) {
        if (strcmp(plant, "abort") == 0) {
            fprintf(stderr, "plant: tripping an lwext4 assertion\n");
            ext4b_trip_assert();
        } else if (strcmp(plant, "spin") == 0) {
            fprintf(stderr, "plant: spinning\n");
            fflush(stderr);
            for (;;) { }
        } else if (strcmp(plant, "write") == 0) {
            fprintf(stderr, "plant: writing one byte behind the driver's back\n");
            int fd = open(image, O_RDWR);
            if (fd >= 0) {
                unsigned char byte = 0xA5;
                (void)!pwrite(fd, &byte, 1, 0);
                close(fd);
            }
        } else {
            fprintf(stderr, "EXT4DUMP_PLANT must be abort, spin or write\n");
            rc = 2;
            goto unmount;
        }
    }

    ext4b_statfs_info sfs;
    if (ext4b_statfs(dev, &sfs) == 0 && strcmp(cmd, "ls") == 0) {
        printf("# %" PRIu64 "/%" PRIu64 " blocks free, avail=%" PRIu64
               ", %u/%u inodes free, bs=%u\n",
               sfs.free_blocks, sfs.total_blocks, sfs.avail_blocks,
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
        printf("mtime:      %lld.%09u\n", (long long)a.mtime, a.mtime_ns);
        printf("crtime:     %lld.%09u\n", (long long)a.crtime, a.crtime_ns);

    } else if (strcmp(cmd, "cat") == 0) {
        if (argc < 4) { fprintf(stderr, "cat needs a path\n"); rc = 2; goto unmount; }
        rc = cmd_cat(dev, argv[3]);

    } else if (strcmp(cmd, "extents") == 0) {
        if (argc < 4) { fprintf(stderr, "extents needs a path\n"); rc = 2; goto unmount; }
        rc = cmd_extents(dev, argv[3]);

    } else if (strcmp(cmd, "fragstat") == 0) {
        rc = cmd_fragstat(dev, argc >= 4 ? argv[3] : "/");

    } else if (strcmp(cmd, "xattr") == 0) {
        if (argc < 4) { fprintf(stderr, "xattr needs a path\n"); rc = 2; goto unmount; }
        uint32_t ino = resolve(dev, argv[3], NULL);
        if (!ino) { rc = 1; goto unmount; }
        r = ext4b_listxattr(dev, ino, on_xattr, NULL);
        if (r != 0)
            fprintf(stderr, "listxattr: %s\n", ext4b_strerror(r));

    } else if (strcmp(cmd, "walk") == 0 || strcmp(cmd, "xattrwalk") == 0) {
        const char *path = (argc > 3) ? argv[3] : "/";
        uint32_t ino = resolve(dev, path, NULL);
        if (!ino) { rc = 1; goto unmount; }
        xwalk_ctx x;
        memset(&x, 0, sizeof x);
        x.dev = dev;
        xwalk_dir(&x, ino, 0);
        printf("%lu inode(s), %lu attribute(s), %lu lookup(s)\n",
               x.inodes, x.attrs, x.lookups);

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

    } else if (strcmp(cmd, "check") == 0) {
        ext4b_check_result res;
        r = ext4b_check_tree(dev, &res);
        if (r != 0) {
            fprintf(stderr, "check: %s\n", ext4b_strerror(r));
            rc = 1;
        } else {
            printf("directories: %llu\n", (unsigned long long)res.directories);
            printf("files:       %llu\n", (unsigned long long)res.files);
            printf("problems:    %llu\n", (unsigned long long)res.problems);
            if (res.problems)
                printf("first:       %s\n", res.first_problem);
            rc = res.problems ? 1 : 0;
        }

    } else if (strcmp(cmd, "df") == 0) {
        /*
         * What the volume tells the OS about its own free space, straight
         * from the same call FSKit makes. A stick reported more available
         * space than the volume has size, which df rendered as a negative
         * block count -- and the reason the clamp on `free` looked
         * ineffective was that `available` is a separate number that was
         * not going through it. Both are printed here, with the impossible
         * ones named, so a bad accounting state is visible without root
         * and without unmounting.
         */
        ext4b_statfs_info st;
        r = ext4b_statfs(dev, &st);
        if (r != 0) { fprintf(stderr, "df: %s\n", ext4b_strerror(r)); rc = 1; }
        else {
            printf("block size:  %u\n", st.block_size);
            printf("total:       %llu blocks\n",
                   (unsigned long long)st.total_blocks);
            printf("free:        %llu blocks%s\n",
                   (unsigned long long)st.free_blocks,
                   st.free_blocks > st.total_blocks ? "  IMPOSSIBLE" : "");
            printf("available:   %llu blocks%s\n",
                   (unsigned long long)st.avail_blocks,
                   st.avail_blocks > st.total_blocks ? "  IMPOSSIBLE" :
                   (st.avail_blocks > st.free_blocks ? "  IMPOSSIBLE" : ""));
            printf("inodes:      %u total, %u free%s\n",
                   st.total_inodes, st.free_inodes,
                   st.free_inodes > st.total_inodes ? "  IMPOSSIBLE" : "");
            rc = (st.free_blocks > st.total_blocks ||
                  st.avail_blocks > st.total_blocks ||
                  st.avail_blocks > st.free_blocks ||
                  st.free_inodes > st.total_inodes) ? 1 : 0;
        }

    } else if (strcmp(cmd, "groups") == 0) {
        /*
         * The per-group free counts, which are the record the allocator works
         * from. `df` reports the superblock's cached total; the two are one
         * fact kept twice, and when a volume reports more free space than it
         * has, only this breakdown says which of them is wrong and where.
         *
         * The flags matter to that question: a lazy format leaves most groups
         * BLOCK_UNINIT, and whether the damaged groups are the lazily
         * initialised ones is the difference between a bug in that series and
         * a bug in ordinary allocation.
         */
        bool only_bad = (argc > 3 && strcmp(argv[3], "bad") == 0);
        uint32_t groups = 0;
        r = ext4b_group_count(dev, &groups);
        if (r != 0) {
            fprintf(stderr, "groups: %s\n", ext4b_strerror(r));
            rc = 1;
        } else {
            ext4b_group_info *g = calloc(groups ? groups : 1, sizeof(*g));
            uint32_t filled = 0;
            if (!g) {
                fprintf(stderr, "groups: out of memory\n");
                rc = 1;
            } else if ((r = ext4b_group_stats(dev, 0, g, groups, &filled)) != 0) {
                fprintf(stderr, "groups: %s\n", ext4b_strerror(r));
                rc = 1;
                free(g);
            } else {
                ext4b_statfs_info st;
                uint64_t sum = 0, blocks = 0;
                uint32_t impossible = 0, uninit = 0;

                printf("%6s %10s %10s %10s  %s\n",
                       "group", "blocks", "free", "used", "flags");
                for (uint32_t i = 0; i < filled; i++) {
                    bool bad = g[i].free_blocks > g[i].blocks;
                    sum    += g[i].free_blocks;
                    blocks += g[i].blocks;
                    if (bad) impossible++;
                    if (g[i].block_uninit) uninit++;
                    if (only_bad && !bad)
                        continue;
                    printf("%6u %10u %10u %10lld  %s%s%s\n",
                           g[i].index, g[i].blocks, g[i].free_blocks,
                           (long long)g[i].blocks - (long long)g[i].free_blocks,
                           g[i].block_uninit ? "BLOCK_UNINIT " : "",
                           g[i].inode_uninit ? "INODE_UNINIT" : "",
                           bad ? "  IMPOSSIBLE" : "");
                }

                printf("\n%u group(s), %u still BLOCK_UNINIT\n",
                       filled, uninit);
                printf("descriptors sum to: %llu free of %llu blocks%s\n",
                       (unsigned long long)sum, (unsigned long long)blocks,
                       sum > blocks ? "  IMPOSSIBLE" : "");

                /*
                 * The raw counter, not the one statfs reports: statfs clamps
                 * free to the volume size so the OS is never handed an
                 * impossible number, which would hide exactly the value this
                 * command exists to show.
                 */
                uint64_t sb_free = 0, sb_total = 0;
                if (ext4b_free_blocks_raw(dev, &sb_free, &sb_total) == 0) {
                    printf("superblock says:    %llu free of %llu blocks%s\n",
                           (unsigned long long)sb_free,
                           (unsigned long long)sb_total,
                           sb_free > sb_total ? "  IMPOSSIBLE" : "");
                    if (sb_free != sum) {
                        printf("the two disagree by %lld block(s)\n",
                               (long long)sb_free - (long long)sum);
                        rc = 1;
                    } else {
                        printf("the two agree\n");
                    }
                    if (ext4b_statfs(dev, &st) == 0 &&
                        st.free_blocks != sb_free)
                        printf("(df reports %llu, clamped to the volume "
                               "size)\n",
                               (unsigned long long)st.free_blocks);
                }
                if (impossible || sum > blocks) {
                    printf("%u group(s) claim more free blocks than they "
                           "hold\n", impossible);
                    rc = 1;
                }
                free(g);
            }
        }

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
    /* An unmount that failed to persist something is the command failing,
     * however well the operations before it went. The suites lean on this:
     * a write-back error surfaced here is the difference between a red test
     * and a silently damaged image with exit code 0. */
    {
        /* What the unmount itself costs, separated from the workload that
         * preceded it. The block cache flushes one buffer per command, so
         * whether that matters is a question about how much is still dirty
         * when the volume closes -- and that is measurable rather than
         * arguable. */
        if (getenv("EXT4DUMP_IO_STATS"))
            fprintf(stderr, "PRE-UNMOUNT writes=%llu write_bytes=%llu\n",
                    (unsigned long long)fc.writes,
                    (unsigned long long)fc.write_bytes);
        int ur = ext4b_unmount(dev);
        if (ur != 0 && rc == 0) {
            fprintf(stderr, "unmount: %s\n", ext4b_strerror(ur));
            rc = 1;
        }
    }
out:
    ext4b_device_destroy(dev);
    luks_device_close(luks);
    close(fd);
    if (getenv("EXT4DUMP_REPORT_WRITES"))
        fprintf(stderr, "writes=%ld\n", fc.writes);
    if (fc.trace && fc.trace != stderr)
        fclose(fc.trace);
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

/* ------------------------------------------------- fragmentation survey -- */
/*
 * How fragmented is everything on this volume, really?
 *
 * e2fsck reports a "% non-contiguous", and that number is a file COUNT: any
 * file with more than one extent is in it. A corpus where every file arrived
 * as two clean halves reports 100%, and so does one where every file arrived
 * as two hundred pieces. It cannot tell an allocator that has been fixed from
 * one that has not -- which is exactly what it failed to do here: a field
 * corpus read 89.2% before the allocator reserved space ahead of writes and
 * 89.3% after, while the same workload offline went from 34 extents per file
 * to 3.
 *
 * So measure the thing that moves. Average bytes per extent says how long a
 * run the medium actually gets to read; the distribution says whether a few
 * bad files or all of them; and the worst file is where to look next.
 */
typedef struct {
    ext4b_device      *dev;
    unsigned long      files;        /* regular files with at least one block */
    unsigned long long bytes;
    unsigned long long extents;
    unsigned long      hist[5];      /* 1, 2-4, 5-16, 17-64, 65+ */
    unsigned long      worst;
    unsigned long long worst_bytes;
    char               worst_path[512];
    int                depth;
} frag_ctx;

/* Every mapped extent of one inode, holes excluded.
 *
 * Mapped in windows rather than one call: a badly fragmented file can have
 * more extents than any fixed buffer, and silently counting the first 256 of
 * them would understate precisely the files this exists to find. */
static unsigned long count_extents(ext4b_device *dev, uint32_t ino,
                                   uint64_t span)
{
    ext4b_extent ext[256];
    unsigned long total = 0;
    uint64_t at = 0;

    while (at < span) {
        size_t n = 0;
        if (ext4b_map_extents(dev, ino, at, span - at, ext,
                              sizeof ext / sizeof ext[0], &n) != 0 || n == 0)
            break;
        uint64_t end = at;
        for (size_t i = 0; i < n; i++) {
            if (!ext[i].is_hole)
                total++;
            uint64_t e = ext[i].logical_offset + ext[i].length;
            if (e > end)
                end = e;
        }
        if (end <= at)          /* no progress: stop rather than spin */
            break;
        at = end;
    }
    return total;
}

static void frag_walk(frag_ctx *f, uint32_t ino, const char *path);

static bool on_frag_dirent(void *ctx, const char *name, size_t name_len,
                           uint32_t ino, ext4b_item_type type,
                           uint64_t next_cookie)
{
    (void)next_cookie;
    frag_ctx *f = ctx;

    if ((name_len == 1 && name[0] == '.') ||
        (name_len == 2 && name[0] == '.' && name[1] == '.'))
        return true;

    char child[4096];
    /* The parent path is not carried down: only the worst file's name is
     * printed, and one name is worth the copy. */
    snprintf(child, sizeof child, "%.*s", (int)name_len, name);

    if (type == EXT4B_TYPE_DIR) {
        if (f->depth < 64) {
            f->depth++;
            frag_walk(f, ino, child);
            f->depth--;
        }
        return true;
    }
    if (type != EXT4B_TYPE_FILE)
        return true;

    ext4b_attrs a;
    if (ext4b_getattr(f->dev, ino, &a) != 0)
        return true;

    uint64_t span = a.size > a.alloc_size ? a.size : a.alloc_size;
    if (span == 0)
        return true;

    unsigned long n = count_extents(f->dev, ino, span);
    if (n == 0)
        return true;

    f->files++;
    f->bytes   += a.size;
    f->extents += n;
    f->hist[n == 1 ? 0 : n <= 4 ? 1 : n <= 16 ? 2 : n <= 64 ? 3 : 4]++;
    if (n > f->worst) {
        f->worst = n;
        f->worst_bytes = a.size;
        snprintf(f->worst_path, sizeof f->worst_path, "%s", child);
    }
    return true;
}

static void frag_walk(frag_ctx *f, uint32_t ino, const char *path)
{
    (void)path;
    int r = ext4b_readdir(f->dev, ino, 0, on_frag_dirent, f);
    if (r != 0 && r != ENOENT)
        fprintf(stderr, "  !! readdir failed: %s\n", ext4b_strerror(r));
}

static int cmd_fragstat(ext4b_device *dev, const char *path)
{
    uint32_t ino = resolve(dev, path ? path : "/", NULL);
    if (!ino) return 1;

    frag_ctx f;
    memset(&f, 0, sizeof f);
    f.dev = dev;
    frag_walk(&f, ino, path ? path : "/");

    if (f.files == 0) {
        printf("fragstat: no files with data under %s\n", path ? path : "/");
        return 0;
    }

    printf("fragstat: %lu file(s), %.1f MB, %llu extent(s)\n",
           f.files, (double)f.bytes / 1048576.0,
           (unsigned long long)f.extents);
    printf("  %.1f extent(s) per file, %.0f KB per extent\n",
           (double)f.extents / (double)f.files,
           (double)f.bytes / (double)f.extents / 1024.0);
    printf("  1: %lu   2-4: %lu   5-16: %lu   17-64: %lu   65+: %lu\n",
           f.hist[0], f.hist[1], f.hist[2], f.hist[3], f.hist[4]);
    printf("  worst: %s, %lu extent(s) for %.1f MB\n",
           f.worst_path, f.worst, (double)f.worst_bytes / 1048576.0);
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
    /* Map the allocation, not the size: preallocated blocks live past EOF
     * and are precisely what someone running this command wants to see. */
    uint64_t span = a.size > a.alloc_size ? a.size : a.alloc_size;
    if (span == 0)
        span = 1;
    int r = ext4b_map_extents(dev, ino, 0, span, ext, 256, &n);
    if (r != 0) {
        fprintf(stderr, "map_extents: %s\n", ext4b_strerror(r));
        return 1;
    }

    printf("%s: size=%" PRIu64 " alloc=%" PRIu64 " layout=%s, %zu extent(s)\n",
           path, a.size, a.alloc_size,
           a.uses_extents ? "extents" : "indirect", n);
    for (size_t i = 0; i < n; i++) {
        printf("  [%2zu] logical %10" PRIu64 "  physical %12" PRIu64
               "  len %8" PRIu64 "%s%s\n",
               i, ext[i].logical_offset, ext[i].physical_offset,
               ext[i].length, ext[i].is_hole ? "  (hole)" : "",
               ext[i].is_unwritten ? "  (unwritten)" : "");
    }
    return 0;
}
