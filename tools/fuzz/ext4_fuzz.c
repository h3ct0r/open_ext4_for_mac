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
 * Read-only pass. Phase A0 establishes the shape: probe, mount, statfs,
 * unmount, and assert the medium is untouched. Phase A1 grows the directory
 * walk, the lookups that enter the htree index, the extent mapping and the
 * xattr reads into the middle of it.
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
    if (ext4b_probe(dev, &info) == 0 &&
        (info.verdict == EXT4B_PROBE_USABLE || info.verdict == EXT4B_PROBE_READ_ONLY)) {
        g_probed++;
        if (ext4b_mount(dev, true) == 0) {
            g_mounted++;
            ext4b_statfs_info st;
            memset(&st, 0, sizeof(st));
            (void)ext4b_statfs(dev, &st);
            (void)ext4b_unmount(dev);
        }
    }

    ext4b_device_destroy(dev);

    /* Belt as well as braces: memdev_write aborts, and this catches a write
     * that somehow bypassed the callback. */
    if (d.wrote) {
        fprintf(stderr, "WROTE: read-only pass modified the medium\n");
        abort();
    }
    free(d.base);
}

/* ------------------------------------------------------------ the entries -- */

int LLVMFuzzerInitialize(int *argc, char ***argv);
int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size);

int LLVMFuzzerInitialize(int *argc, char ***argv)
{
    (void)argc; (void)argv;

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
