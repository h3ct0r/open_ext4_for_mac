/*
 * Write and verify a file whose contents are derived from a seed.
 *
 * Nothing in this tree issues a real fcntl(F_PREALLOCATE) against a mounted
 * volume, which is the path every Finder copy takes: macOS reserves the space
 * first, and the driver answers with UNWRITTEN extents that are converted as
 * the data arrives. The offline suites drive that conversion through
 * ext4dump's own preallocate call, which is a different entry point; the one
 * the field uses had no test at all.
 *
 * Contents come from a seeded generator rather than a source file so that
 * verification needs nothing but the seed -- no second copy to compare
 * against, no checksum manifest to keep in step. That also makes the failure
 * report specific: a checksum says "this file is wrong", while this says which
 * byte first went wrong, how far the damage runs, and whether the bad bytes are
 * zeros (a conversion that zeroed live data), a repeat of another region (a
 * mapping pointing at the wrong blocks), or noise.
 *
 * That distinction is the whole diagnostic. A file that is wrong from offset
 * 4096 for exactly 4096 bytes is a different bug from one that is wrong from a
 * random offset by a few bytes, and a checksum cannot tell them apart.
 */
/* fallocate(2) on glibc. Harmless on macOS, which never sees it. */
#ifndef __APPLE__
#define _GNU_SOURCE
#endif

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>

#define CHUNK (1u << 20)

/* splitmix64: tiny, well-distributed, and identical on both sides of the
 * write/verify pair. The stream is a pure function of (seed, offset), so any
 * region can be regenerated without replaying what came before it. */
static uint64_t mix(uint64_t x)
{
    x += 0x9E3779B97F4A7C15ULL;
    x = (x ^ (x >> 30)) * 0xBF58476D1CE4E5B9ULL;
    x = (x ^ (x >> 27)) * 0x94D049BB133111EBULL;
    return x ^ (x >> 31);
}

/* Fill `buf` with the bytes belonging at byte offset `off`. Generated in
 * 8-byte words keyed by their own index, so a partial chunk at any alignment
 * still produces the same bytes as a full one. */
static void gen(uint8_t *buf, size_t len, uint64_t off, uint64_t seed)
{
    for (size_t i = 0; i < len; i++) {
        uint64_t pos = off + i;
        uint64_t w = mix(seed ^ (pos >> 3));
        buf[i] = (uint8_t)(w >> ((pos & 7) * 8));
    }
}

static int usage(void)
{
    fprintf(stderr,
        "usage:\n"
        "  datafile write  <path> <bytes> <seed> [--prealloc] [--trim-to N]\n"
        "                  write a seeded file; --prealloc reserves the full\n"
        "                  size with fcntl(F_PREALLOCATE) first, as macOS does\n"
        "                  before a large copy; --trim-to truncates afterwards,\n"
        "                  which is how Finder releases what it over-reserved\n"
        "  datafile verify <path> <bytes> <seed>\n"
        "                  compare against the same stream and report the first\n"
        "                  differing byte, the length of the damage, and what\n"
        "                  the wrong bytes look like\n"
        "  datafile verify-range <path> <bytes> <seed> <offset> <length>\n"
        "                  the same comparison over one window. <bytes> is\n"
        "                  still the whole file's size and is still checked,\n"
        "                  because a file that came back the wrong length is\n"
        "                  broken however well a sampled window reads\n");
    return 2;
}

static int do_write(const char *path, uint64_t bytes, uint64_t seed,
                    int prealloc, int64_t trim_to)
{
    int fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) { perror("open"); return 1; }

    if (prealloc) {
        /*
         * F_ALLOCATEALL asks for the whole request or nothing, which is what
         * macOS uses ahead of a copy. F_PEOFPOSMODE places the allocation
         * past the current end of file. A failure is reported rather than
         * ignored: silently falling back to an ordinary write would make this
         * tool measure the very path it exists to avoid.
         *
         * Linux spells it fallocate(2), and it is the real thing rather than
         * a stand-in: the driver's ext4b_preallocate answers both, and this
         * tool exists to drive them through a MOUNTED volume rather than
         * through our own core. On Linux it drives the kernel's ext4, which
         * is the point of running it there at all.
         */
#ifdef __APPLE__
        fstore_t st = { .fst_flags = F_ALLOCATEALL,
                        .fst_posmode = F_PEOFPOSMODE,
                        .fst_offset = 0,
                        .fst_length = (off_t)bytes,
                        .fst_bytesalloc = 0 };
        if (fcntl(fd, F_PREALLOCATE, &st) < 0) {
            fprintf(stderr, "F_PREALLOCATE(%llu): %s\n",
                    (unsigned long long)bytes, strerror(errno));
            close(fd);
            return 1;
        }
        printf("preallocated %lld bytes\n", (long long)st.fst_bytesalloc);
#else
        if (fallocate(fd, 0, 0, (off_t)bytes) < 0) {
            fprintf(stderr, "fallocate(%llu): %s\n",
                    (unsigned long long)bytes, strerror(errno));
            close(fd);
            return 1;
        }
        printf("preallocated %llu bytes\n", (unsigned long long)bytes);
#endif
    }

    uint8_t *buf = malloc(CHUNK);
    if (!buf) { fprintf(stderr, "out of memory\n"); close(fd); return 1; }

    for (uint64_t off = 0; off < bytes; ) {
        size_t n = (size_t)((bytes - off < CHUNK) ? (bytes - off) : CHUNK);
        gen(buf, n, off, seed);
        ssize_t w = write(fd, buf, n);
        if (w < 0 || (size_t)w != n) {
            fprintf(stderr, "write at %llu: %s\n",
                    (unsigned long long)off,
                    w < 0 ? strerror(errno) : "short write");
            free(buf); close(fd); return 1;
        }
        off += n;
    }
    free(buf);

    if (trim_to >= 0 && ftruncate(fd, (off_t)trim_to) < 0) {
        fprintf(stderr, "ftruncate(%lld): %s\n",
                (long long)trim_to, strerror(errno));
        close(fd); return 1;
    }

    /* Durability is the point of the exercise, so the data has to be on the
     * medium before this claims success -- close() alone promises nothing. */
    if (fsync(fd) < 0) { perror("fsync"); close(fd); return 1; }
    if (close(fd) < 0) { perror("close"); return 1; }
    return 0;
}

/* What the wrong bytes are, which is what separates one bug from another. */
static const char *shape(const uint8_t *got, size_t n)
{
    int all_zero = 1;
    for (size_t i = 0; i < n; i++)
        if (got[i]) { all_zero = 0; break; }
    return all_zero ? "zeros (a conversion or hole where data should be)"
                    : "non-zero (stale contents, or the wrong blocks)";
}

/* Compare the file against the stream over [from, from+len).
 *
 * A whole-file check is just the window [0, bytes), so there is one
 * implementation rather than two that can drift apart. The window exists for
 * files too large to read in full inside a suite that has to stay runnable: a
 * 5 GiB file is where i_size_high, the large_file feature and every remaining
 * 32-bit block index live, and reading all of it back to learn that costs
 * minutes. Because the stream is a pure function of (seed, offset), a sampled
 * window is generated exactly as it would be in a full pass -- the head, the
 * tail and the 4 GiB boundary can be checked for what they cost.
 *
 * <bytes> is still the whole file's size and is still checked. A file that
 * came back the wrong length is broken however well a sampled window reads,
 * and that is the failure a partial verify would otherwise be blind to. */
static int do_verify(const char *path, uint64_t bytes, uint64_t seed,
                     uint64_t from, uint64_t len)
{
    int fd = open(path, O_RDONLY);
    if (fd < 0) { perror("open"); return 1; }

    struct stat st;
    if (fstat(fd, &st) < 0) { perror("fstat"); close(fd); return 1; }
    if ((uint64_t)st.st_size != bytes) {
        printf("SIZE MISMATCH: %lld bytes on disk, expected %llu\n",
               (long long)st.st_size, (unsigned long long)bytes);
        close(fd);
        return 1;
    }

    if (from > bytes || len > bytes - from) {
        printf("WINDOW OUT OF RANGE: %llu+%llu in a %llu-byte file\n",
               (unsigned long long)from, (unsigned long long)len,
               (unsigned long long)bytes);
        close(fd);
        return 1;
    }

    uint8_t *want = malloc(CHUNK), *got = malloc(CHUNK);
    if (!want || !got) {
        fprintf(stderr, "out of memory\n");
        free(want); free(got); close(fd); return 1;
    }

    uint64_t bad_first = 0, bad_bytes = 0;
    int found = 0;
    const uint64_t end = from + len;

    for (uint64_t off = from; off < end; ) {
        size_t n = (size_t)((end - off < CHUNK) ? (end - off) : CHUNK);
        ssize_t r = pread(fd, got, n, (off_t)off);
        if (r < 0 || (size_t)r != n) {
            printf("READ FAILED at %llu: %s\n", (unsigned long long)off,
                   r < 0 ? strerror(errno) : "short read");
            free(want); free(got); close(fd); return 1;
        }
        gen(want, n, off, seed);
        if (memcmp(want, got, n) != 0) {
            for (size_t i = 0; i < n; i++) {
                if (want[i] != got[i]) {
                    if (!found) { bad_first = off + i; found = 1; }
                    bad_bytes++;
                }
            }
        }
        off += n;
    }

    if (!found) {
        if (from == 0 && len == bytes)
            printf("OK %llu bytes match\n", (unsigned long long)bytes);
        else
            printf("OK %llu bytes match at %llu (of %llu)\n",
                   (unsigned long long)len, (unsigned long long)from,
                   (unsigned long long)bytes);
        free(want); free(got); close(fd);
        return 0;
    }

    /* Re-read a window at the first bad byte to describe it. The alignment is
     * reported because block-aligned damage and byte-ragged damage come from
     * different layers. */
    size_t win = 64;
    if (bad_first + win > bytes) win = (size_t)(bytes - bad_first);
    if (pread(fd, got, win, (off_t)bad_first) == (ssize_t)win) {
        printf("MISMATCH at offset %llu (block %llu, %s)\n",
               (unsigned long long)bad_first,
               (unsigned long long)(bad_first / 4096),
               (bad_first % 4096) == 0 ? "4096-aligned" : "not block-aligned");
        printf("  %llu of %llu bytes differ\n",
               (unsigned long long)bad_bytes, (unsigned long long)len);
        printf("  the wrong bytes look like: %s\n", shape(got, win));
    }
    free(want); free(got); close(fd);
    return 1;
}

int main(int argc, char **argv)
{
    if (argc < 5) return usage();

    const char *cmd  = argv[1];
    const char *path = argv[2];
    uint64_t bytes   = strtoull(argv[3], NULL, 10);
    uint64_t seed    = strtoull(argv[4], NULL, 10);

    if (strcmp(cmd, "verify") == 0)
        return do_verify(path, bytes, seed, 0, bytes);

    if (strcmp(cmd, "verify-range") == 0) {
        if (argc < 7) return usage();
        uint64_t from = strtoull(argv[5], NULL, 10);
        uint64_t len  = strtoull(argv[6], NULL, 10);
        return do_verify(path, bytes, seed, from, len);
    }

    if (strcmp(cmd, "write") == 0) {
        int prealloc = 0;
        int64_t trim_to = -1;
        for (int i = 5; i < argc; i++) {
            if (strcmp(argv[i], "--prealloc") == 0) prealloc = 1;
            else if (strcmp(argv[i], "--trim-to") == 0 && i + 1 < argc)
                trim_to = strtoll(argv[++i], NULL, 10);
            else return usage();
        }
        return do_write(path, bytes, seed, prealloc, trim_to);
    }

    return usage();
}
