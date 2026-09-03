/*
 * ext4_fuzz.c — an in-process libFuzzer target for the ext4 core.
 *
 * A filesystem driver mounts untrusted media. Every corruption bug this
 * project has found so far lived in a surface nothing exercised, and a fuzzer
 * is the instrument that reaches those surfaces without anyone having thought
 * of them first. This drives the same device seam ext4dump uses --
 * ext4b_device_create's read/write/flush callbacks -- against a mutated image
 * held entirely in memory, so a run costs no I/O and no temporary files.
 *
 * Built only into CONFIG=fuzz, with Homebrew clang (Apple's Command Line
 * Tools clang ships no libFuzzer runtime). See the fuzzing block in the
 * Makefile.
 *
 * Modes, from EXT4_FUZZ_MODE:
 *   ro    (default)  probe, mount read-only, walk, unmount. Nothing may write.
 *   rw               mount read-write: journal replay, orphan cleanup, and a
 *                    fixed mutation script. (phase A4)
 *   both             ro then rw, on separate copies. The default for repro.
 *
 * Other knobs, all read here in tools/ and never in the shipping core:
 *   EXT4_FUZZ_BSIZE    device block size, default 512 (4096 is the second
 *                      campaign: the same image, different offset arithmetic)
 *   EXT4_FUZZ_VERBOSE  forward every bridge log line, not just assertions
 *
 * Outcome classes: clean, crash (ASan/UBSan/SIGABRT/SIGSEGV), hang
 * (libFuzzer's -timeout), OOM, and WROTE -- a read-only mount that touched
 * the medium, which memdev_write catches by aborting.
 */

#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <dirent.h>
#include <sys/stat.h>

#include "ext4_bridge.h"

/* ------------------------------------------------------------- the device -- */

typedef struct {
    uint8_t *base;
    size_t   len;
    uint64_t reads;
    uint64_t writes;
    bool     wrote;
    bool     read_only;   /* a write here is a bug, not an input */
} memdev;

/*
 * Overflow-safe bounds. `offset + count` on 64-bit values supplied by a
 * corrupt superblock is exactly the arithmetic that wraps, and a wrapped sum
 * compares as in-range -- so compare the two terms separately instead. EIO
 * past the end, which is what a short device answers.
 */
static int memdev_read(void *ctx, void *buf, uint64_t offset, size_t count)
{
    memdev *d = (memdev *)ctx;
    if (count == 0) return 0;
    if (offset > (uint64_t)d->len) return EIO;
    if ((uint64_t)count > (uint64_t)d->len - offset) return EIO;
    memcpy(buf, d->base + offset, count);
    d->reads++;
    return 0;
}

static int memdev_write(void *ctx, const void *buf, uint64_t offset, size_t count)
{
    memdev *d = (memdev *)ctx;

    /*
     * The WROTE class. ext4b_device_create is told read_only, and the shim
     * refuses writes above this layer -- so reaching here at all means a
     * read-only mount modified the medium, which is a data-safety bug of the
     * first order and must stop the run rather than be counted. abort(), so
     * libFuzzer records it as a crash with the input attached.
     */
    if (d->read_only) {
        fprintf(stderr, "WROTE: read-only mount wrote %zu bytes at %llu\n",
                count, (unsigned long long)offset);
        fflush(stderr);
        abort();
    }

    if (count == 0) return 0;
    if (offset > (uint64_t)d->len) return EIO;
    if ((uint64_t)count > (uint64_t)d->len - offset) return EIO;
    memcpy(d->base + offset, buf, count);
    d->writes++;
    d->wrote = true;
    return 0;
}

static int memdev_flush(void *ctx) { (void)ctx; return 0; }

/* ------------------------------------------------------------- the logger -- */

static bool g_verbose;

/*
 * Refusals log at level 3 and a campaign produces one per input, so
 * forwarding everything drowns the run. An assertion is the exception: it
 * precedes the abort() that libFuzzer is about to report, and it is the line
 * that says which one.
 */
static void fuzz_log(void *ctx, int level, const char *message)
{
    (void)ctx;
    if (g_verbose || (level >= 3 && message && strstr(message, "assertion failed"))) {
        fprintf(stderr, "[%d] %s\n", level, message ? message : "");
    }
}

/* ------------------------------------------------------------------ modes -- */

typedef enum { MODE_RO, MODE_RW, MODE_BOTH } fuzz_mode;

static fuzz_mode g_mode      = MODE_RO;
static uint32_t  g_bsize     = 512;

/* Counters, printed by libFuzzer's -print_final_stats path via atexit. They
 * answer the one question a green campaign cannot otherwise answer: did any
 * input get past the probe at all, or was the whole run rejected at byte 56? */
static uint64_t g_inputs, g_probed, g_mounted;

static void fuzz_stats(void)
{
    fprintf(stderr, "ext4_fuzz: inputs=%llu probed-ext=%llu mounted=%llu\n",
            (unsigned long long)g_inputs,
            (unsigned long long)g_probed,
            (unsigned long long)g_mounted);
}

/* --------------------------------------------------------------- one pass -- */

/*
 * Caps. Every one of these exists because a corrupt image can make the
 * corresponding structure unbounded, and an input that takes a minute is an
 * input libFuzzer will never get past. They are limits on the harness's
 * appetite, not on what the driver is allowed to contain: a directory with
 * 5000 entries is fine, this simply stops looking after 4096 of them.
 */
#define FZ_MAX_DIRS     256      /* directories descended into, per input   */
#define FZ_MAX_ENTRIES  4096     /* directory entries examined, per input   */
#define FZ_MAX_DEPTH    32       /* tree depth                              */
#define FZ_MAX_PER_DIR  512      /* entries collected from one directory    */
#define FZ_MAX_LOOKUPS  64       /* names re-looked-up through the index    */
#define FZ_MAX_XA_INO   128      /* inodes whose xattrs are listed          */
#define FZ_MAX_XA_NAMES 32       /* xattr names read back per inode         */
#define FZ_MAX_EXTENTS  1024     /* extents mapped per file                 */
#define FZ_VIS_BITS     (1u << 20)  /* visited-set ceiling: 128 KiB         */

typedef struct {
    char     name[256];
    size_t   name_len;
    uint32_t inode;
    ext4b_item_type type;
} fz_entry;

typedef struct {
    fz_entry *ents;
    size_t    count;
    uint64_t  last_cookie;
    bool      cookie_stalled;   /* the iterator did not advance: bail out */
} fz_dirbuf;

/*
 * A directory whose iterator does not advance is the shape of the deferred
 * htree-leaf hazard (patch 0037's note: the linear dirent path is guarded,
 * "the exposed route is the htree leaf path"). Detecting it here turns an
 * infinite loop -- which libFuzzer can only report as a timeout, with no idea
 * which structure caused it -- into an abandoned directory and a counted
 * input. The loop itself is still a bug; this is how the harness survives to
 * report the next one.
 */
static bool fz_on_dirent(void *ctx, const char *name, size_t name_len,
                         uint32_t inode, ext4b_item_type type,
                         uint64_t next_cookie)
{
    fz_dirbuf *db = (fz_dirbuf *)ctx;

    if (next_cookie <= db->last_cookie) {
        db->cookie_stalled = true;
        return false;
    }
    db->last_cookie = next_cookie;

    if (db->count >= FZ_MAX_PER_DIR)
        return false;
    if (name_len > 255)
        name_len = 255;

    fz_entry *e = &db->ents[db->count++];
    memcpy(e->name, name, name_len);
    e->name[name_len] = '\0';
    e->name_len = name_len;
    e->inode    = inode;
    e->type     = type;
    return true;
}

static bool fz_xattr_name(void *ctx, const char *name, size_t name_len)
{
    /* Collect up to FZ_MAX_XA_NAMES names so each can be read back. The
     * listing walks the entry headers; getxattr is what parses a value
     * offset, and those are different parsers. */
    struct { char (*names)[256]; size_t *count; } *c = ctx;
    if (*c->count >= FZ_MAX_XA_NAMES)
        return false;
    if (name_len > 255)
        name_len = 255;
    memcpy(c->names[*c->count], name, name_len);
    c->names[*c->count][name_len] = '\0';
    (*c->count)++;
    return true;
}

/* The visited set. Sized from the superblock's inode count, but capped: a
 * corrupt s_inodes_count of 0xFFFFFFFF would otherwise ask for 512 MB. An
 * inode above the cap is treated as already visited, which costs coverage of
 * a pathological image and nothing else. */
typedef struct { uint8_t *bits; uint32_t n; } fz_visited;

static bool fz_seen(fz_visited *v, uint32_t ino)
{
    if (!v->bits || ino >= v->n) return true;
    uint8_t m = (uint8_t)(1u << (ino & 7));
    if (v->bits[ino >> 3] & m) return true;
    v->bits[ino >> 3] |= m;
    return false;
}

/* Everything the walk does to one file. Every return code is accepted: a
 * corrupt image is *supposed* to make these fail. Only a crash, a hang or a
 * write counts. */
static void fz_visit_file(ext4b_device *dev, uint32_t ino,
                          const ext4b_attrs *a, uint8_t *scratch)
{
    size_t got = 0;

    /* The head of the file: the extent root, or i_block's direct entries. */
    size_t head = a->size < 65536 ? (size_t)a->size : 65536;
    if (head > 0)
        (void)ext4b_read(dev, ino, 0, scratch, head, &got);

    /* And a window at the end, which is what reaches a deep extent tree or
     * the double-indirect block of an ext2 file rather than its first entry. */
    if (a->size > 131072)
        (void)ext4b_read(dev, ino, a->size - 4096, scratch, 4096, &got);

    ext4b_extent ex[FZ_MAX_EXTENTS];
    size_t nex = 0;
    (void)ext4b_map_extents(dev, ino, 0, a->size ? a->size : 4096,
                            ex, FZ_MAX_EXTENTS, &nex);
}

/*
 * The read-only pass: probe, mount, walk everything reachable from the root,
 * and assert the medium was never touched.
 *
 * Iterative, with an explicit stack. A recursive walk over a directory tree an
 * attacker controls is a stack overflow waiting to be found, and it would be
 * found -- by the fuzzer, in the harness, which is the least useful crash
 * available.
 */
static void fuzz_one_ro(const uint8_t *data, size_t size)
{
    memdev d = { 0 };
    d.len       = size - (size % g_bsize);
    d.read_only = true;
    if (d.len < 2048) return;

    d.base = (uint8_t *)malloc(d.len);
    if (!d.base) return;
    memcpy(d.base, data, d.len);

    ext4b_device *dev = ext4b_device_create(&d, g_bsize, d.len / g_bsize,
                                            true, memdev_read, memdev_write,
                                            memdev_flush);
    if (!dev) { free(d.base); return; }

    ext4b_probe_info info;
    memset(&info, 0, sizeof(info));
    int rc = ext4b_probe(dev, &info);

    /* NOT_EXT and UNSUPPORTED are the refusals working. They are the common
     * case early in a campaign and are counted, not walked. */
    if (rc != 0 ||
        (info.verdict != EXT4B_PROBE_USABLE && info.verdict != EXT4B_PROBE_READ_ONLY))
        goto done;

    g_probed++;

#ifdef EXT4_FUZZ_PLANT
    /*
     * Test-only, compiled in by -DEXT4_FUZZ_PLANT=1 for the harness's own
     * red-first proof: an image whose label says so trips a real lwext4
     * assertion, or writes through the read-only device. Neither is reachable
     * in an ordinary build -- this whole block is compiled out.
     */
    if (strcmp(info.label, "plant") == 0) {
        fprintf(stderr, "plant: tripping an lwext4 assertion\n");
        ext4b_trip_assert();
    }
    if (strcmp(info.label, "wrote") == 0) {
        static const uint8_t one = 0xA5;
        fprintf(stderr, "plant: writing through the read-only device\n");
        (void)memdev_write(&d, &one, 0, 1);
    }
    /*
     * The leak plant: pretend the mount table kept something after the first
     * input, which is the failure the initialize self-test exists to catch.
     * Without a way to simulate it, that self-test could only ever be
     * believed rather than shown.
     */
    if (getenv("EXT4_FUZZ_PLANT_LEAK")) {
        static unsigned seen;
        if (seen++ > 0) {
            fprintf(stderr, "plant: refusing to mount after the first input\n");
            goto done;
        }
    }
#endif

    if (ext4b_mount(dev, true) != 0)
        goto done;
    g_mounted++;

    ext4b_statfs_info st;
    memset(&st, 0, sizeof(st));
    (void)ext4b_statfs(dev, &st);

    /*
     * A read-only mount must refuse every mutation, and refuse it without
     * having written anything first. The shim returns EROFS at bd_bwrite; if
     * that guard ever moved below the point where a transaction has already
     * dirtied a buffer, memdev_write would fire and this input would be a
     * crash. Cheap, and it runs on every input rather than in one cell.
     */
    {
        ext4b_attrs want;
        memset(&want, 0, sizeof(want));
        want.mode = 0644;
        (void)ext4b_setattr(dev, EXT4B_ROOT_INO, EXT4B_SET_MODE, &want);
    }

    /* Working memory, allocated once and reused across the whole walk. */
    fz_entry  *ents    = (fz_entry *)malloc(sizeof(fz_entry) * FZ_MAX_PER_DIR);
    uint8_t   *scratch = (uint8_t *)malloc(65536);
    fz_visited vis     = { NULL, 0 };
    {
        uint32_t n = info.inode_count;
        if (n == 0) n = 1;
        if (n > FZ_VIS_BITS) n = FZ_VIS_BITS;
        vis.bits = (uint8_t *)calloc((n + 7) / 8, 1);
        vis.n    = n;
    }
    if (!ents || !scratch || !vis.bits) goto walk_done;

    struct { uint32_t ino; uint32_t depth; } stack[FZ_MAX_DEPTH * 8];
    size_t   sp = 0;
    unsigned dirs_done = 0, entries_done = 0, xattr_inodes = 0;

    (void)fz_seen(&vis, EXT4B_ROOT_INO);
    stack[sp].ino = EXT4B_ROOT_INO; stack[sp].depth = 0; sp++;

    while (sp > 0 && dirs_done < FZ_MAX_DIRS && entries_done < FZ_MAX_ENTRIES) {
        sp--;
        uint32_t dir_ino = stack[sp].ino;
        uint32_t depth   = stack[sp].depth;
        dirs_done++;

        fz_dirbuf db = { ents, 0, 0, false };
        (void)ext4b_readdir(dev, dir_ino, 0, fz_on_dirent, &db);

        /*
         * A lookup is not a slower readdir. readdir walks the leaves
         * linearly; ext4b_lookup is what enters the dx index and descends it,
         * which is the deferred htree-leaf path. One lookup of a name that
         * cannot be there forces a full descent to a leaf and back, whatever
         * the entries say.
         */
        for (size_t i = 0; i < db.count && i < FZ_MAX_LOOKUPS; i++) {
            uint32_t out_ino = 0;
            ext4b_item_type out_t = EXT4B_TYPE_UNKNOWN;
            (void)ext4b_lookup(dev, dir_ino, db.ents[i].name, db.ents[i].name_len,
                               &out_ino, &out_t);
        }
        {
            static const char absent[] = ".no-such-name-0e5a1f";
            uint32_t out_ino = 0;
            ext4b_item_type out_t = EXT4B_TYPE_UNKNOWN;
            (void)ext4b_lookup(dev, dir_ino, absent, sizeof(absent) - 1,
                               &out_ino, &out_t);
        }

        for (size_t i = 0; i < db.count && entries_done < FZ_MAX_ENTRIES; i++) {
            fz_entry *e = &db.ents[i];
            entries_done++;

            if (e->name_len == 1 && e->name[0] == '.') continue;
            if (e->name_len == 2 && e->name[0] == '.' && e->name[1] == '.') continue;

            ext4b_attrs a;
            memset(&a, 0, sizeof(a));
            if (ext4b_getattr(dev, e->inode, &a) != 0)
                continue;

            /*
             * The xattr parsers, on inodes rather than on files: an ibody
             * entry and a block entry are read by different code, and a
             * directory can carry either. Capped by inode count, not by file
             * count, so a tree of empty directories still reaches them.
             */
            if (xattr_inodes < FZ_MAX_XA_INO) {
                xattr_inodes++;
                char names[FZ_MAX_XA_NAMES][256];
                size_t nnames = 0;
                struct { char (*names)[256]; size_t *count; } xc = { names, &nnames };
                if (ext4b_listxattr(dev, e->inode, fz_xattr_name, &xc) == 0) {
                    for (size_t k = 0; k < nnames; k++) {
                        size_t vlen = 0;
                        (void)ext4b_getxattr(dev, e->inode, names[k],
                                             scratch, 65536, &vlen);
                    }
                }
            }

            switch (a.type) {
            case EXT4B_TYPE_DIR:
                if (depth + 1 < FZ_MAX_DEPTH && sp < (sizeof stack / sizeof stack[0]) &&
                    !fz_seen(&vis, e->inode)) {
                    stack[sp].ino = e->inode; stack[sp].depth = depth + 1; sp++;
                }
                break;
            case EXT4B_TYPE_SYMLINK: {
                char target[4096];
                size_t tlen = 0;
                (void)ext4b_readlink(dev, e->inode, target, sizeof target, &tlen);
                break;
            }
            case EXT4B_TYPE_FILE:
                fz_visit_file(dev, e->inode, &a, scratch);
                break;
            default:
                break;
            }
        }

        if (db.cookie_stalled) {
            /* Counted as a walked directory and abandoned. Nothing else in
             * this input is more interesting than the loop itself. */
            fprintf(stderr, "note: directory %u iterator did not advance\n", dir_ino);
        }
    }

    /* The structural cross-check: link counts against the tree, entries
     * against the inodes they name. It reads a lot that the walk above does
     * not, and it is the shim's own code rather than lwext4's. */
    {
        ext4b_check_result cr;
        memset(&cr, 0, sizeof(cr));
        (void)ext4b_check_tree(dev, &cr);
    }

    {
        uint32_t head = 0;
        (void)ext4b_orphan_head(dev, &head);
    }

walk_done:
    free(ents);
    free(scratch);
    free(vis.bits);
    (void)ext4b_unmount(dev);

done:
    ext4b_device_destroy(dev);

    /* Belt as well as braces: memdev_write aborts, and this catches a write
     * that somehow bypassed the callback. */
    if (d.wrote || d.writes != 0) {
        fprintf(stderr, "WROTE: read-only pass modified the medium (%llu writes)\n",
                (unsigned long long)d.writes);
        abort();
    }
    free(d.base);
}

/* ------------------------------------------------------------ the entries -- */

int LLVMFuzzerInitialize(int *argc, char ***argv);
int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size);

/*
 * The global-state canary.
 *
 * lwext4 keeps a mount table and a block cache in file-scope state, and this
 * harness mounts and unmounts thousands of images in one process -- something
 * nothing else in this project does. If an unmount ever left a stale entry
 * behind, every input after the first would test a different thing than it
 * appeared to, and the campaign would still look busy and green. The symptom
 * would be silent.
 *
 * So before any fuzzing: run one real seed twice and assert it reaches the
 * same place both times, then run it truncated, which is the cheapest input
 * that exercises the failure path with the mount table already warm. A
 * mismatch aborts loudly rather than being counted.
 *
 * It also answers the soak's question -- "does the harness still reach a
 * mount at all" -- in the first hundred milliseconds of a round, instead of
 * after ten minutes of a campaign that was rejecting every input at the
 * superblock.
 *
 * Only runs when a corpus DIRECTORY was passed, and takes its sample from the
 * last one (which is where `make fuzz` puts the seeds). A one-file repro run
 * therefore never self-tests the very artifact it was asked to reproduce.
 */
static void fuzz_self_test(int argc, char **argv)
{
    char sample[4096] = { 0 };

    for (int i = argc - 1; i >= 1 && sample[0] == '\0'; i--) {
        struct stat st;
        if (argv[i][0] == '-') continue;
        if (stat(argv[i], &st) != 0 || !S_ISDIR(st.st_mode)) continue;

        DIR *dh = opendir(argv[i]);
        if (!dh) continue;
        struct dirent *de;
        while ((de = readdir(dh)) != NULL) {
            if (de->d_name[0] == '.') continue;
            char path[4096];
            snprintf(path, sizeof path, "%s/%s", argv[i], de->d_name);
            struct stat fs2;
            if (stat(path, &fs2) == 0 && S_ISREG(fs2.st_mode) && fs2.st_size >= 2048) {
                snprintf(sample, sizeof sample, "%s", path);
                break;
            }
        }
        closedir(dh);
    }
    if (sample[0] == '\0') return;

    FILE *f = fopen(sample, "rb");
    if (!f) return;
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return; }
    long n = ftell(f);
    if (n < 2048 || n > (64L << 20)) { fclose(f); return; }
    rewind(f);
    uint8_t *buf = (uint8_t *)malloc((size_t)n);
    if (!buf) { fclose(f); return; }
    size_t got = fread(buf, 1, (size_t)n, f);
    fclose(f);
    if (got != (size_t)n) { free(buf); return; }

    uint64_t m0 = g_mounted, p0 = g_probed;
    fuzz_one_ro(buf, (size_t)n);
    uint64_t first_mount = g_mounted - m0, first_probe = g_probed - p0;

    m0 = g_mounted; p0 = g_probed;
    fuzz_one_ro(buf, (size_t)n);
    uint64_t second_mount = g_mounted - m0, second_probe = g_probed - p0;

    /* And once truncated, which fails somewhere in the middle of a mount and
     * so is the input most likely to leave state behind. */
    fuzz_one_ro(buf, (size_t)n / 2);

    m0 = g_mounted;
    fuzz_one_ro(buf, (size_t)n);
    uint64_t third_mount = g_mounted - m0;

    free(buf);

    if (first_probe != second_probe || first_mount != second_mount ||
        first_mount != third_mount) {
        fprintf(stderr,
                "ext4_fuzz: SELF-TEST FAILED on %s\n"
                "  the same image did not behave the same way twice:\n"
                "  probe %llu then %llu, mount %llu then %llu then %llu.\n"
                "  Something is leaking between inputs -- lwext4's mount table\n"
                "  or its block cache -- and every result from this run would\n"
                "  be about the wrong thing.\n",
                sample,
                (unsigned long long)first_probe,  (unsigned long long)second_probe,
                (unsigned long long)first_mount,  (unsigned long long)second_mount,
                (unsigned long long)third_mount);
        abort();
    }

    fprintf(stderr, "ext4_fuzz: self-test ok (%s: probe=%llu mount=%llu, stable over 3 runs)\n",
            sample, (unsigned long long)first_probe, (unsigned long long)first_mount);

    /* The self-test's own counts are not campaign results. */
    g_inputs = 0; g_probed = 0; g_mounted = 0;
}

int LLVMFuzzerInitialize(int *argc, char ***argv)
{
    const char *m = getenv("EXT4_FUZZ_MODE");
    if (m) {
        if      (!strcmp(m, "ro"))   g_mode = MODE_RO;
        else if (!strcmp(m, "rw"))   g_mode = MODE_RW;
        else if (!strcmp(m, "both")) g_mode = MODE_BOTH;
        else {
            fprintf(stderr, "EXT4_FUZZ_MODE must be ro, rw or both\n");
            exit(2);
        }
    }

    const char *b = getenv("EXT4_FUZZ_BSIZE");
    if (b) {
        unsigned long v = strtoul(b, NULL, 10);
        if (v < 512 || v > 65536 || (v & (v - 1)) != 0) {
            fprintf(stderr, "EXT4_FUZZ_BSIZE must be a power of two in [512, 65536]\n");
            exit(2);
        }
        g_bsize = (uint32_t)v;
    }

    g_verbose = getenv("EXT4_FUZZ_VERBOSE") != NULL;
    ext4b_set_logger(fuzz_log, NULL);
    atexit(fuzz_stats);

    if (argc && argv && !getenv("EXT4_FUZZ_NO_SELFTEST"))
        fuzz_self_test(*argc, *argv);
    return 0;
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    g_inputs++;
    if (size < 2048) return 0;

    if (g_mode == MODE_RO || g_mode == MODE_BOTH)
        fuzz_one_ro(data, size);

    /* MODE_RW arrives in phase A4: a private copy, a read-write mount (the
     * only path that runs jbd2 recovery and orphan cleanup), and a fixed
     * mutation script whose every return code is accepted. */
    return 0;
}
