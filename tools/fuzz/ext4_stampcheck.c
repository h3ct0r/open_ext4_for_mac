/*
 * ext4_stampcheck — does tools/fuzz/ext4_csum.c compute the checksums that
 * e2fsprogs actually wrote?
 *
 * The mutator re-stamps checksums so an edit reaches the parser it was aimed
 * at rather than being refused at the gate. If the stamper is wrong, every
 * mutant is refused, the campaign covers nothing past ext4b_probe, and it all
 * looks exactly like a driver with very good validation. That failure is
 * silent and it would waste the whole of Part A.
 *
 * So: take a pristine mke2fs image, recompute every checksum in it, and
 * compare against what mke2fs stored. Agreement everywhere is the claim.
 *
 *   ext4_stampcheck <image>...          verify; exit 1 on any mismatch
 *   ext4_stampcheck -v <image>...       and say what matched
 *
 * The negative control is a build with a wrong polynomial:
 *
 *   cc -DEXT4_CSUM_POLY=0x82F63B79 ...
 *
 * which must disagree with every structure on every image. A checker that
 * passes with the wrong polynomial is not checking anything.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>

#include "ext4_csum.h"

static int verbose;

typedef struct { unsigned checked, bad; } tally;

static void report(tally *t, const char *what, bool okmatch,
                   uint32_t stored, uint32_t want)
{
    t->checked++;
    if (okmatch) {
        if (verbose) printf("    ok   %-28s 0x%08x\n", what, stored);
        return;
    }
    t->bad++;
    printf("    BAD  %-28s stored 0x%08x, computed 0x%08x\n", what, stored, want);
}

static int check_image(const char *path)
{
    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "%s: %s\n", path, strerror(errno)); return 2; }
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return 2; }
    long n = ftell(f);
    if (n <= 0) { fclose(f); fprintf(stderr, "%s: empty\n", path); return 2; }
    rewind(f);
    uint8_t *buf = malloc((size_t)n);
    if (!buf) { fclose(f); return 2; }
    if (fread(buf, 1, (size_t)n, f) != (size_t)n) {
        fclose(f); free(buf); fprintf(stderr, "%s: short read\n", path); return 2;
    }
    fclose(f);

    fz_layout L;
    if (!fz_layout_parse(&L, buf, (size_t)n)) {
        printf("  %s: not an ext image this resolver understands\n", path);
        free(buf);
        return 0;                    /* not a failure: not every file is one */
    }

    printf("  %s: %u-byte blocks, %u group(s), %u-byte inodes, "
           "desc %u, metadata_csum %s\n",
           path, L.block_size, L.group_count, L.inode_size, L.desc_size,
           L.has_metadata_csum ? "on" : (L.has_gdt_csum ? "gdt_csum" : "off"));

    tally t = { 0, 0 };
    uint32_t stored, want;

    if (fz_check_superblock(&L, &stored, &want))
        report(&t, "superblock", stored == want, stored, want);

    for (uint32_t g = 0; g < L.group_count; g++) {
        char label[64];
        if (fz_check_desc(&L, g, &stored, &want)) {
            snprintf(label, sizeof label, "group %u descriptor", g);
            report(&t, label, stored == want, stored, want);
        }
        if (fz_check_bbitmap(&L, g, &stored, &want)) {
            snprintf(label, sizeof label, "group %u block bitmap", g);
            report(&t, label, stored == want, stored, want);
        }
        if (fz_check_ibitmap(&L, g, &stored, &want)) {
            snprintf(label, sizeof label, "group %u inode bitmap", g);
            report(&t, label, stored == want, stored, want);
        }
    }

    /*
     * Inodes that are actually in use. An unused inode is all zeroes and
     * carries no checksum; counting those as matches would let a broken
     * stamper pass on a mostly-empty volume.
     */
    unsigned inodes_seen = 0;
    uint32_t limit = L.inodes_count;
    if (limit > 4096) limit = 4096;
    for (uint32_t ino = 1; ino <= limit; ino++) {
        uint64_t off;
        if (!fz_inode_offset(&L, ino, &off)) continue;
        const uint8_t *p = L.base + off;
        /* links_count at 0x1A, mode at 0x00: in use if either is set. */
        if (fz_rd16(p) == 0 && fz_rd16(p + 0x1A) == 0) continue;
        if (!fz_check_inode(&L, ino, &stored, &want)) continue;
        char label[64];
        snprintf(label, sizeof label, "inode %u", ino);
        report(&t, label, stored == want, stored, want);
        inodes_seen++;
    }

    printf("    %u checked, %u mismatched (%u live inode(s))\n",
           t.checked, t.bad, inodes_seen);

    /* A volume with metadata_csum on and nothing to check is a resolver
     * failure wearing a pass. */
    if (L.has_metadata_csum && t.checked == 0) {
        printf("    BAD  metadata_csum is on and nothing was checked\n");
        free(buf);
        return 1;
    }
    if (L.has_metadata_csum && inodes_seen == 0) {
        printf("    BAD  metadata_csum is on and no live inode was found\n");
        free(buf);
        return 1;
    }

    free(buf);
    return t.bad ? 1 : 0;
}

int main(int argc, char **argv)
{
    int i = 1, rc = 0, images = 0;
    if (i < argc && strcmp(argv[i], "-v") == 0) { verbose = 1; i++; }
    if (i >= argc) {
        fprintf(stderr, "usage: ext4_stampcheck [-v] <image>...\n");
        return 2;
    }
    printf("ext4_stampcheck: polynomial 0x%08x\n", (unsigned)EXT4_CSUM_POLY);
    for (; i < argc; i++) {
        int r = check_image(argv[i]);
        images++;
        if (r > rc) rc = r;
    }
    printf("%s (%d image(s))\n", rc ? "MISMATCHES PRESENT" : "all checksums agree",
           images);
    return rc;
}
