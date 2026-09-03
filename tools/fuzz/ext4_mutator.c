/* Structure-aware mutation of an ext4 image. See ext4_mutator.h. */

#include "ext4_mutator.h"
#include "ext4_csum.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* libFuzzer's own mutator, for the raw strategy. Declared rather than
 * included: this file is also linked into tools that have no libFuzzer, and
 * they provide a stub. */
size_t LLVMFuzzerMutate(uint8_t *Data, size_t Size, size_t MaxSize);

/* ------------------------------------------------------------- weights -- */

enum {
    S_RAW = 0, S_SUPERBLOCK, S_GROUP_DESC, S_INODE, S_EXTENT, S_INDIRECT,
    S_DIRENT, S_HTREE, S_XATTR, S_JBD2, S_BLOCK, S_COUNT
};

static const char *strategy_names[S_COUNT] = {
    "raw", "superblock", "group_desc", "inode", "extent", "indirect",
    "dirent", "htree", "xattr", "jbd2", "block"
};

/* The compiled-in fallback, and the shape mutweights.json overrides. */
static int weights[S_COUNT] = { 20, 12, 10, 12, 10, 5, 10, 10, 8, 8, 5 };
static int restamp_skip_percent = 5;
static unsigned long counts[S_COUNT];
static bool initialised;

const char *ext4_mutator_strategy_name(int i)
{
    return (i >= 0 && i < S_COUNT) ? strategy_names[i] : "?";
}
int ext4_mutator_strategy_count(void) { return S_COUNT; }

void ext4_mutator_dump_counts(void)
{
    fprintf(stderr, "ext4_fuzz: strategies");
    for (int i = 0; i < S_COUNT; i++)
        fprintf(stderr, " %s=%lu", strategy_names[i], counts[i]);
    fprintf(stderr, "\n");
}

/*
 * A three-line JSON reader, not a JSON parser. The file is ours, its shape is
 * fixed, and pulling in a parser to read eleven integers would be the larger
 * risk. It looks for "name": <int> and takes the last such pair, which is
 * enough because the keys are unique.
 */
static void load_weights(const char *path)
{
    FILE *f = fopen(path, "rb");
    if (!f) return;
    char buf[8192];
    size_t n = fread(buf, 1, sizeof buf - 1, f);
    fclose(f);
    buf[n] = '\0';

    for (int i = 0; i < S_COUNT; i++) {
        char key[64];
        snprintf(key, sizeof key, "\"%s\"", strategy_names[i]);
        const char *p = strstr(buf, key);
        if (!p) continue;
        p = strchr(p, ':');
        if (!p) continue;
        int v = atoi(p + 1);
        if (v >= 0 && v <= 1000) weights[i] = v;
    }
    const char *p = strstr(buf, "\"restamp_skip_percent\"");
    if (p && (p = strchr(p, ':')) != NULL) {
        int v = atoi(p + 1);
        if (v >= 0 && v <= 100) restamp_skip_percent = v;
    }
    fprintf(stderr, "ext4_fuzz: weights from %s\n", path);
}

void ext4_mutator_init(void)
{
    if (initialised) return;
    initialised = true;
    /* Both the place it lives in the tree and the place a campaign is run
     * from, because `make fuzz` runs from .fuzz/logs. */
    const char *env = getenv("EXT4_FUZZ_WEIGHTS");
    if (env) { load_weights(env); return; }
    static const char *tries[] = {
#ifdef EXT4_FUZZ_WEIGHTS_PATH
        /* Compiled in by the Makefile. The relative paths below only work
         * from the tree or from .fuzz/logs, and a campaign run from anywhere
         * else silently fell back to the built-in weights -- silently, which
         * is the problem: the two instruments would then be aiming
         * differently while claiming to share a table. */
        EXT4_FUZZ_WEIGHTS_PATH,
#endif
        "tools/fuzz/mutweights.json",
        "../../tools/fuzz/mutweights.json",
        "../tools/fuzz/mutweights.json",
    };
    for (unsigned i = 0; i < sizeof tries / sizeof tries[0]; i++) {
        FILE *f = fopen(tries[i], "rb");
        if (f) { fclose(f); load_weights(tries[i]); return; }
    }
    fprintf(stderr, "ext4_fuzz: mutweights.json not found; using built-in weights\n");
}

/* ----------------------------------------------------------------- rng -- */

/* xorshift64*, so a campaign is reproducible from its seed and the mutator
 * does not perturb any rand() the harness or the library might use. */
static uint64_t rng_state = 0x2545F4914F6CDD1Dull;

static uint64_t rnd(void)
{
    uint64_t x = rng_state;
    x ^= x >> 12; x ^= x << 25; x ^= x >> 27;
    rng_state = x;
    return x * 0x2545F4914F6CDD1Dull;
}
static uint32_t rnd_below(uint32_t n) { return n ? (uint32_t)(rnd() % n) : 0; }
static bool     rnd_pct(int pct) { return (int)rnd_below(100) < pct; }

/*
 * The values that break arithmetic, in the widths the fields come in. A
 * corrupt filesystem is not random bytes: it is a plausible structure with
 * one field that is zero, one past the end, or 0xFFFFFFFF.
 */
static uint64_t interesting(unsigned bytes)
{
    static const uint64_t v[] = {
        0, 1, 2, 3, 4, 7, 8, 12, 16, 32, 63, 64, 127, 128, 255, 256,
        0x7FFF, 0x8000, 0xFFFF, 0x10000, 0x7FFFFFFF, 0x80000000u, 0xFFFFFFFFu,
        0xFFFFFFFEu, 0x7FFFFFFFFFFFFFFFull, 0xFFFFFFFFFFFFFFFFull,
    };
    uint64_t x;
    if (rnd_pct(70)) x = v[rnd_below((uint32_t)(sizeof v / sizeof v[0]))];
    else             x = rnd();
    switch (bytes) {
    case 1: return x & 0xFF;
    case 2: return x & 0xFFFF;
    case 4: return x & 0xFFFFFFFFu;
    default: return x;
    }
}

static void poke(uint8_t *p, unsigned bytes, uint64_t v)
{
    for (unsigned i = 0; i < bytes; i++) p[i] = (uint8_t)(v >> (8 * i));
}

/* Same, big-endian: everything inside the journal is network order. */
static void poke_be(uint8_t *p, unsigned bytes, uint64_t v)
{
    for (unsigned i = 0; i < bytes; i++) p[i] = (uint8_t)(v >> (8 * (bytes - 1 - i)));
}
static uint32_t rd32_be(const uint8_t *p)
{
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8) | p[3];
}

/* ------------------------------------------------------- restamp policy -- */

/*
 * After an edit, put the checksums back -- most of the time. The gate is code
 * too: five per cent of edits are left with a wrong superblock checksum so
 * that ext4b_probe's refusal path keeps being exercised, and so that the
 * corpus does not drift into containing only well-formed volumes.
 */
static void restamp_sb(fz_layout *L)
{
    if (rnd_pct(restamp_skip_percent)) return;
    fz_stamp_superblock(L);
}

/* ---------------------------------------------------------- inode picks -- */

/* A live inode: one with a mode or a link count. Returns 0 when none. */
static uint32_t pick_live_inode(const fz_layout *L)
{
    uint32_t limit = L->inodes_count;
    if (limit == 0 || limit > 100000) limit = 100000;

    /* The four that always matter, then a random live one. */
    static const uint32_t special[] = { 2, 7, 8, 11 };
    if (rnd_pct(25)) {
        uint32_t ino = special[rnd_below(4)];
        uint64_t off;
        if (fz_inode_offset(L, ino, &off)) return ino;
    }
    for (int tries = 0; tries < 64; tries++) {
        uint32_t ino = 1 + rnd_below(limit);
        uint64_t off;
        if (!fz_inode_offset(L, ino, &off)) continue;
        const uint8_t *p = L->base + off;
        if (fz_rd16(p) != 0 || fz_rd16(p + 0x1A) != 0) return ino;
    }
    return 0;
}

#define INODE_MODE 0x00
#define INODE_SIZE_LO 0x04
#define INODE_LINKS 0x1A
#define INODE_BLOCKS_LO 0x1C
#define INODE_FLAGS 0x20
#define INODE_IBLOCK 0x28
#define INODE_GENERATION 0x64
#define INODE_FILE_ACL 0x68
#define INODE_SIZE_HI 0x6C
#define INODE_EXTRA 0x80

#define INODE_FLAG_EXTENTS 0x00080000u
#define INODE_FLAG_INDEX   0x00001000u

/* The first physical block an inode's extent root points at, if any. */
static bool inode_first_block(const fz_layout *L, uint32_t ino, uint64_t *blk)
{
    uint64_t off;
    if (!fz_inode_offset(L, ino, &off)) return false;
    const uint8_t *p = L->base + off;
    uint32_t flags = fz_rd32(p + INODE_FLAGS);

    if (flags & INODE_FLAG_EXTENTS) {
        const uint8_t *eh = p + INODE_IBLOCK;
        if (fz_rd16(eh) != 0xF30A) return false;
        uint16_t entries = fz_rd16(eh + 2);
        uint16_t depth   = fz_rd16(eh + 6);
        if (entries == 0 || entries > 4) return false;
        const uint8_t *e = eh + 12;
        if (depth == 0) {
            /* leaf: ee_start_lo at +8, ee_start_hi at +6 */
            *blk = (uint64_t)fz_rd32(e + 8) |
                   ((uint64_t)fz_rd16(e + 6) << 32);
        } else {
            /* index: ei_leaf_lo at +4, ei_leaf_hi at +8 */
            *blk = (uint64_t)fz_rd32(e + 4) |
                   ((uint64_t)fz_rd16(e + 8) << 32);
        }
        return *blk != 0;
    }
    /* ext2/3: i_block[0] is the first direct block. */
    *blk = fz_rd32(p + INODE_IBLOCK);
    return *blk != 0;
}

static bool inode_is_dir(const fz_layout *L, uint32_t ino)
{
    uint64_t off;
    if (!fz_inode_offset(L, ino, &off)) return false;
    return (fz_rd16(L->base + off + INODE_MODE) & 0xF000) == 0x4000;
}

/* ---------------------------------------------------------- strategies -- */

static void mut_superblock(fz_layout *L)
{
    /* offset, width. Every field that decides a geometry the driver then
     * computes addresses from -- which is the class that turns a bad value
     * into an out-of-bounds access rather than a wrong answer. */
    static const struct { uint32_t off; unsigned w; } f[] = {
        { 0x000, 4 },  /* s_inodes_count        */
        { 0x004, 4 },  /* s_blocks_count_lo     */
        { 0x014, 4 },  /* s_first_data_block    */
        { 0x018, 4 },  /* s_log_block_size      */
        { 0x01C, 4 },  /* s_log_cluster_size    */
        { 0x020, 4 },  /* s_blocks_per_group    */
        { 0x024, 4 },  /* s_clusters_per_group  */
        { 0x028, 4 },  /* s_inodes_per_group    */
        { 0x03A, 2 },  /* s_state               */
        { 0x04C, 4 },  /* s_rev_level           */
        { 0x054, 4 },  /* s_first_ino           */
        { 0x058, 2 },  /* s_inode_size          */
        { 0x05C, 4 },  /* s_feature_compat      */
        { 0x060, 4 },  /* s_feature_incompat    */
        { 0x064, 4 },  /* s_feature_ro_compat   */
        { 0x0E0, 4 },  /* s_journal_inum        */
        { 0x0EC, 4 },  /* s_hash_seed[0]        */
        { 0x0FC, 1 },  /* s_def_hash_version    */
        { 0x0FE, 2 },  /* s_desc_size           */
        { 0x150, 4 },  /* s_blocks_count_hi     */
        { 0x0CE, 2 },  /* s_reserved_gdt_blocks */
        { 0x174, 1 },  /* s_log_groups_per_flex */
        { 0x175, 1 },  /* s_checksum_type       */
        { 0x0E8, 4 },  /* s_last_orphan         */
        { 0x270, 4 },  /* s_checksum_seed       */
    };
    unsigned i = rnd_below((uint32_t)(sizeof f / sizeof f[0]));
    poke(L->base + EXT4_SB_OFFSET + f[i].off, f[i].w, interesting(f[i].w));
    restamp_sb(L);
}

static void mut_group_desc(fz_layout *L)
{
    uint32_t g = rnd_below(L->group_count);
    uint64_t doff;
    if (!fz_desc_offset(L, g, &doff)) return;

    static const struct { uint32_t off; unsigned w; } f[] = {
        { 0x00, 4 }, { 0x04, 4 }, { 0x08, 4 },   /* bitmap/itable lo */
        { 0x0C, 2 }, { 0x0E, 2 }, { 0x10, 2 },   /* free counts, dirs */
        { 0x12, 2 },                             /* flags: UNINIT/ZEROED */
        { 0x1C, 2 },                             /* itable_unused_lo */
        { 0x1E, 2 },                             /* the checksum itself */
        { 0x20, 4 }, { 0x24, 4 }, { 0x28, 4 },   /* the _hi halves */
        { 0x2C, 2 }, { 0x2E, 2 }, { 0x32, 2 },
    };
    unsigned i;
    do { i = rnd_below((uint32_t)(sizeof f / sizeof f[0])); }
    while (f[i].off >= L->desc_size);

    poke(L->base + doff + f[i].off, f[i].w, interesting(f[i].w));

    /* Not when the field poked WAS the checksum: leaving that one wrong is
     * the point of choosing it. */
    if (f[i].off != 0x1E) {
        fz_stamp_bbitmap(L, g);
        fz_stamp_ibitmap(L, g);
        fz_stamp_desc(L, g);
    }
    restamp_sb(L);
}

static void mut_inode(fz_layout *L)
{
    uint32_t ino = pick_live_inode(L);
    if (!ino) return;
    uint64_t off;
    if (!fz_inode_offset(L, ino, &off)) return;

    static const struct { uint32_t o; unsigned w; } f[] = {
        { INODE_MODE, 2 }, { INODE_SIZE_LO, 4 }, { INODE_LINKS, 2 },
        { INODE_BLOCKS_LO, 4 }, { INODE_FLAGS, 4 }, { INODE_GENERATION, 4 },
        { INODE_FILE_ACL, 4 }, { INODE_SIZE_HI, 4 }, { INODE_EXTRA, 2 },
        { 0x14, 4 },                             /* i_dtime */
    };
    unsigned i = rnd_below((uint32_t)(sizeof f / sizeof f[0]));
    if (f[i].o + f[i].w > L->inode_size) return;
    poke(L->base + off + f[i].o, f[i].w, interesting(f[i].w));

    fz_stamp_inode(L, ino);
    restamp_sb(L);
}

static void mut_extent(fz_layout *L)
{
    uint32_t ino = pick_live_inode(L);
    if (!ino) return;
    uint64_t off;
    if (!fz_inode_offset(L, ino, &off)) return;
    uint8_t *p = L->base + off;
    if (!(fz_rd32(p + INODE_FLAGS) & INODE_FLAG_EXTENTS)) return;

    uint8_t *eh = p + INODE_IBLOCK;

    /* Half the time the root header inside the inode, which is the one that
     * never passes through a block reader and so was validated by nothing
     * before patch 0048. */
    if (rnd_pct(50) || fz_rd16(eh) != 0xF30A) {
        switch (rnd_below(4)) {
        case 0: poke(eh + 0, 2, interesting(2)); break;   /* eh_magic   */
        case 1: poke(eh + 2, 2, interesting(2)); break;   /* eh_entries */
        case 2: poke(eh + 4, 2, interesting(2)); break;   /* eh_max     */
        case 3: poke(eh + 6, 2, rnd_below(6)); break;     /* eh_depth   */
        }
        fz_stamp_inode(L, ino);
        restamp_sb(L);
        return;
    }

    uint16_t entries = fz_rd16(eh + 2);
    uint16_t depth   = fz_rd16(eh + 6);
    if (entries == 0 || entries > 4) { fz_stamp_inode(L, ino); return; }

    uint8_t *e = eh + 12 + 12u * rnd_below(entries);
    if (depth == 0) {
        switch (rnd_below(4)) {
        case 0: poke(e + 0, 4, interesting(4)); break;    /* ee_block    */
        case 1: poke(e + 4, 2, interesting(2)); break;    /* ee_len, incl >32768 */
        case 2: poke(e + 6, 2, interesting(2)); break;    /* ee_start_hi */
        case 3: poke(e + 8, 4, interesting(4)); break;    /* ee_start_lo */
        }
    } else {
        switch (rnd_below(3)) {
        case 0: poke(e + 0, 4, interesting(4)); break;    /* ei_block    */
        case 1: poke(e + 4, 4, interesting(4)); break;    /* ei_leaf_lo  */
        case 2: poke(e + 8, 2, interesting(2)); break;    /* ei_leaf_hi  */
        }
        /* And sometimes the node it points at, which does have a tail. */
        uint64_t leaf = (uint64_t)fz_rd32(e + 4) |
                        ((uint64_t)fz_rd16(e + 8) << 32);
        uint64_t boff = leaf * (uint64_t)L->block_size;
        if (rnd_pct(50) && fz_in_range(L, boff, L->block_size)) {
            uint8_t *node = L->base + boff;
            if (fz_rd16(node) == 0xF30A) {
                poke(node + 2 + 2u * rnd_below(3), 2, interesting(2));
                fz_stamp_extent_block(L, ino, leaf);
            }
        }
    }
    fz_stamp_inode(L, ino);
    restamp_sb(L);
}

static void mut_indirect(fz_layout *L)
{
    uint32_t ino = pick_live_inode(L);
    if (!ino) return;
    uint64_t off;
    if (!fz_inode_offset(L, ino, &off)) return;
    uint8_t *p = L->base + off;
    if (fz_rd32(p + INODE_FLAGS) & INODE_FLAG_EXTENTS) return;   /* not this one */

    /* i_block[0..14]: twelve direct, then single, double and triple. */
    unsigned slot = rnd_below(15);
    static const uint64_t targets[] = { 0, 1, 2, 0xFFFFFFFFu, 0x7FFFFFFFu };
    uint64_t v = rnd_pct(60)
        ? targets[rnd_below(5)]
        : interesting(4);
    poke(p + INODE_IBLOCK + 4u * slot, 4, v);

    /* And sometimes a word inside the indirect block itself. */
    uint64_t ind = fz_rd32(p + INODE_IBLOCK + 4u * 12);
    uint64_t boff = ind * (uint64_t)L->block_size;
    if (ind && rnd_pct(50) && fz_in_range(L, boff, L->block_size)) {
        uint32_t words = L->block_size / 4;
        poke(L->base + boff + 4u * rnd_below(words), 4, interesting(4));
    }
    fz_stamp_inode(L, ino);
    restamp_sb(L);
}

static void mut_dirent(fz_layout *L)
{
    /* A directory, and its first block. */
    uint32_t ino = 0;
    for (int t = 0; t < 32 && !ino; t++) {
        uint32_t c = pick_live_inode(L);
        if (c && inode_is_dir(L, c)) ino = c;
    }
    if (!ino) return;
    uint64_t blk;
    if (!inode_first_block(L, ino, &blk)) return;
    uint64_t boff = blk * (uint64_t)L->block_size;
    if (!fz_in_range(L, boff, L->block_size)) return;
    uint8_t *b = L->base + boff;

    /* Walk to a random entry rather than always poking the first, which is
     * "." and is special-cased everywhere. */
    uint32_t pos = 0, chosen = 0, seen = 0;
    while (pos + 8 < L->block_size) {
        uint16_t rec = fz_rd16(b + pos + 4);
        if (rec < 8 || pos + rec > L->block_size) break;
        if (seen++ && rnd_pct(40)) { chosen = pos; break; }
        chosen = pos;
        pos += rec;
    }
    uint8_t *d = b + chosen;

    switch (rnd_below(5)) {
    case 0: poke(d + 0, 4, interesting(4)); break;            /* inode        */
    case 1: {                                                 /* rec_len      */
        static const uint16_t bad[] = { 0, 1, 4, 7, 9, 0xFFFF };
        uint16_t v = rnd_pct(70) ? bad[rnd_below(6)]
                                 : (uint16_t)(L->block_size + 4);
        poke(d + 4, 2, v);
        break;
    }
    case 2: poke(d + 6, 1, interesting(1)); break;            /* name_len     */
    case 3: poke(d + 7, 1, 8 + rnd_below(248)); break;        /* file_type >= 8 */
    case 4:                                                   /* the tail     */
        if (L->block_size >= 12)
            poke(b + L->block_size - 12 + rnd_below(12), 1, interesting(1));
        break;
    }
    fz_stamp_dir_block(L, ino, blk);
    restamp_sb(L);
}

static void mut_htree(fz_layout *L)
{
    uint32_t ino = 0;
    for (int t = 0; t < 48 && !ino; t++) {
        uint32_t c = pick_live_inode(L);
        if (!c || !inode_is_dir(L, c)) continue;
        uint64_t o;
        if (!fz_inode_offset(L, c, &o)) continue;
        if (fz_rd32(L->base + o + INODE_FLAGS) & INODE_FLAG_INDEX) ino = c;
    }
    if (!ino) return;
    uint64_t blk;
    if (!inode_first_block(L, ino, &blk)) return;
    uint64_t boff = blk * (uint64_t)L->block_size;
    if (!fz_in_range(L, boff, L->block_size)) return;
    uint8_t *b = L->base + boff;

    /* dx_root: two fake dirents (8 + 12 bytes... 0..23), then dx_root_info at
     * 24: reserved_zero(4) hash_version(1) info_length(1) indirect_levels(1)
     * unused_flags(1); then the count/limit pair at 32. */
    if (L->block_size < 64) return;
    switch (rnd_below(6)) {
    case 0: poke(b + 28, 1, rnd_below(8)); break;      /* hash_version   */
    case 1: poke(b + 29, 1, interesting(1)); break;    /* info_length    */
    case 2: poke(b + 30, 1, rnd_pct(50) ? rnd_below(4) : 255); break; /* indirect_levels */
    case 3: poke(b + 32, 2, interesting(2)); break;    /* limit          */
    case 4: poke(b + 34, 2, interesting(2)); break;    /* count          */
    case 5: {                                          /* an entry's block */
        uint16_t count = fz_rd16(b + 34);
        if (count == 0 || count > 512) count = 1;
        uint32_t e = 32 + 8u * (1 + rnd_below(count));
        if (e + 8 <= L->block_size) poke(b + e + 4, 4, interesting(4));
        break;
    }
    }
    fz_stamp_dx_block(L, ino, blk);
    restamp_sb(L);
}

static void mut_xattr(fz_layout *L)
{
    uint32_t ino = pick_live_inode(L);
    if (!ino) return;
    uint64_t off;
    if (!fz_inode_offset(L, ino, &off)) return;
    uint8_t *p = L->base + off;

    /* An xattr block, when the inode has one. */
    uint64_t acl = fz_rd32(p + INODE_FILE_ACL);
    uint64_t boff = acl * (uint64_t)L->block_size;
    if (acl && fz_in_range(L, boff, L->block_size) && rnd_pct(60)) {
        uint8_t *h = L->base + boff;
        switch (rnd_below(6)) {
        case 0: poke(h + 0x00, 4, interesting(4)); break;   /* h_magic     */
        case 1: poke(h + 0x04, 4, interesting(4)); break;   /* h_refcount  */
        case 2: poke(h + 0x08, 4, interesting(4)); break;   /* h_blocks    */
        case 3: poke(h + 0x10, 4, interesting(4)); break;   /* h_checksum  */
        case 4: {                                           /* first entry */
            uint8_t *e = h + 32;
            switch (rnd_below(5)) {
            case 0: poke(e + 0, 1, interesting(1)); break;  /* name_len    */
            case 1: poke(e + 1, 1, interesting(1)); break;  /* name_index  */
            case 2: poke(e + 2, 2, interesting(2)); break;  /* value_offs  */
            case 3: poke(e + 4, 4, interesting(4)); break;  /* value_inum  */
            case 4: poke(e + 8, 4, interesting(4)); break;  /* value_size  */
            }
            break;
        }
        case 5:                                             /* terminator  */
            poke(h + 32 + 16u * rnd_below(4), 4, interesting(4));
            break;
        }
        if (rnd_pct(100 - restamp_skip_percent))
            fz_stamp_xattr_block(L, ino, acl);
        fz_stamp_inode(L, ino);
        restamp_sb(L);
        return;
    }

    /* Otherwise the in-inode area, which starts after i_extra_isize. */
    if (L->inode_size <= 128) return;
    uint16_t extra = fz_rd16(p + INODE_EXTRA);
    uint32_t ibody = 128u + extra;
    if (ibody + 8 > L->inode_size) return;
    switch (rnd_below(3)) {
    case 0: poke(p + ibody, 4, interesting(4)); break;        /* h_magic     */
    case 1: poke(p + ibody + 4, 1, interesting(1)); break;    /* name_len    */
    case 2: poke(p + ibody + 6, 2, interesting(2)); break;    /* value_offs  */
    }
    fz_stamp_inode(L, ino);
    restamp_sb(L);
}

/*
 * The journal, which is big-endian throughout -- including inside its own
 * checksum computations, which is what patches 0015 and 0017 are about.
 */
static void mut_jbd2(fz_layout *L)
{
    /* s_journal_inum is normally 8; find its first block through the inode. */
    uint32_t jinum = fz_rd32(L->base + EXT4_SB_OFFSET + 0x0E0);
    if (jinum == 0 || jinum > L->inodes_count) jinum = 8;
    uint64_t jblk;
    if (!inode_first_block(L, jinum, &jblk)) return;
    uint64_t joff = jblk * (uint64_t)L->block_size;
    if (!fz_in_range(L, joff, L->block_size)) return;
    uint8_t *jsb = L->base + joff;
    if (rd32_be(jsb) != 0xC03B3998u) return;          /* not a journal sb */

    if (rnd_pct(60)) {
        /* The journal superblock. Offsets are the jbd2 header (12) then
         * blocksize, maxlen, first, sequence, start. */
        static const struct { uint32_t o; unsigned w; } f[] = {
            { 0x0C, 4 },  /* s_blocksize */
            { 0x10, 4 },  /* s_maxlen    */
            { 0x14, 4 },  /* s_first     */
            { 0x18, 4 },  /* s_sequence  */
            { 0x1C, 4 },  /* s_start     */
            { 0x24, 4 },  /* s_feature_compat    */
            { 0x28, 4 },  /* s_feature_incompat  */
            { 0x2C, 4 },  /* s_feature_ro_compat */
            { 0x50, 1 },  /* s_checksum_type     */
        };
        unsigned i = rnd_below((uint32_t)(sizeof f / sizeof f[0]));
        poke_be(jsb + f[i].o, f[i].w, interesting(f[i].w));
        restamp_sb(L);
        return;
    }

    /* Or a block inside the log: descriptor tags, commit or revoke records.
     * Everything here is deliberately left with a wrong checksum some of the
     * time -- a journal whose commit block does not verify is the case
     * recovery is supposed to stop at, and it is code. */
    uint32_t maxlen = rd32_be(jsb + 0x10);
    if (maxlen == 0 || maxlen > 1u << 20) maxlen = 64;
    uint32_t which = 1 + rnd_below(maxlen - 1 > 64 ? 64 : (maxlen > 1 ? maxlen - 1 : 1));
    uint64_t boff = joff + (uint64_t)which * L->block_size;
    if (!fz_in_range(L, boff, L->block_size)) return;
    uint8_t *b = L->base + boff;
    if (rd32_be(b) != 0xC03B3998u) {
        /* Not a header block: make it look like one, which is its own test. */
        poke_be(b, 4, 0xC03B3998u);
        poke_be(b + 4, 4, 1 + rnd_below(5));      /* block type */
        poke_be(b + 8, 4, interesting(4));        /* sequence   */
        restamp_sb(L);
        return;
    }
    uint32_t type = rd32_be(b + 4);
    switch (type) {
    case 1:   /* descriptor: tags follow the 12-byte header */
        poke_be(b + 12 + 4u * rnd_below(4), 4, interesting(4));
        break;
    case 2:   /* commit */
        poke_be(b + 8, 4, interesting(4));        /* sequence */
        poke_be(b + 0x10, 4, interesting(4));     /* checksum */
        break;
    case 5:   /* revoke: r_count at 12 */
        poke_be(b + 12, 4, interesting(4));
        break;
    default:
        poke_be(b + 4, 4, rnd_below(8));
        break;
    }
    restamp_sb(L);
}

static void mut_block(fz_layout *L, uint8_t *data, size_t *size, size_t max_size)
{
    uint32_t bs = L->block_size;
    if (bs == 0 || *size < 2u * bs) return;
    uint64_t nblocks = *size / bs;

    switch (rnd_below(4)) {
    case 0: {   /* copy one block over another: aliasing */
        uint64_t a = rnd_below((uint32_t)nblocks), b = rnd_below((uint32_t)nblocks);
        if (a != b) memcpy(data + b * bs, data + a * bs, bs);
        break;
    }
    case 1:     /* zero a block */
        memset(data + (uint64_t)rnd_below((uint32_t)nblocks) * bs, 0, bs);
        break;
    case 2: {   /* swap two blocks */
        uint64_t a = rnd_below((uint32_t)nblocks), b = rnd_below((uint32_t)nblocks);
        if (a == b) break;
        uint8_t *tmp = malloc(bs);
        if (!tmp) break;
        memcpy(tmp, data + a * bs, bs);
        memcpy(data + a * bs, data + b * bs, bs);
        memcpy(data + b * bs, tmp, bs);
        free(tmp);
        break;
    }
    case 3:     /* shorten or lengthen the device by a block */
        if (rnd_pct(50)) { if (*size > 2u * bs) *size -= bs; }
        else if (*size + bs <= max_size) { memset(data + *size, 0, bs); *size += bs; }
        break;
    }
    /* Block 0 and 1 hold the superblock on a 1 KiB volume; if either moved,
     * the checksum has to follow, or every mutant of this kind is refused at
     * the gate for the wrong reason. */
    restamp_sb(L);
}

/* -------------------------------------------------------------- entries -- */

static int pick_strategy(void)
{
    int total = 0;
    for (int i = 0; i < S_COUNT; i++) total += weights[i];
    if (total <= 0) return S_RAW;
    int r = (int)rnd_below((uint32_t)total);
    for (int i = 0; i < S_COUNT; i++) {
        if (r < weights[i]) return i;
        r -= weights[i];
    }
    return S_RAW;
}

size_t ext4_mutate(uint8_t *data, size_t size, size_t max_size, unsigned seed)
{
    ext4_mutator_init();
    rng_state = ((uint64_t)seed << 32) ^ (uint64_t)size ^ 0x9E3779B97F4A7C15ull;
    if (rng_state == 0) rng_state = 1;

    int s = pick_strategy();

    /* The resolver is the gate on every structured strategy. An image whose
     * superblock does not parse has no structures to aim at, and a raw edit
     * is exactly the right thing to do to it. */
    fz_layout L;
    if (s != S_RAW && !fz_layout_parse(&L, data, size))
        s = S_RAW;

    counts[s]++;
    switch (s) {
    case S_RAW:         return LLVMFuzzerMutate(data, size, max_size);
    case S_SUPERBLOCK:  mut_superblock(&L); break;
    case S_GROUP_DESC:  mut_group_desc(&L); break;
    case S_INODE:       mut_inode(&L); break;
    case S_EXTENT:      mut_extent(&L); break;
    case S_INDIRECT:    mut_indirect(&L); break;
    case S_DIRENT:      mut_dirent(&L); break;
    case S_HTREE:       mut_htree(&L); break;
    case S_XATTR:       mut_xattr(&L); break;
    case S_JBD2:        mut_jbd2(&L); break;
    case S_BLOCK:       mut_block(&L, data, &size, max_size); break;
    default:            break;
    }
    return size;
}

/*
 * Splice at block granularity and at the SAME offset in both, so the result
 * is still a plausible volume: a group's bitmaps from one image with another
 * image's inode table is a combination neither seed contains and no
 * byte-level crossover would produce.
 */
size_t ext4_crossover(const uint8_t *a, size_t alen,
                      const uint8_t *b, size_t blen,
                      uint8_t *out, size_t max_out, unsigned seed)
{
    ext4_mutator_init();
    rng_state = ((uint64_t)seed << 32) ^ (uint64_t)alen ^ (uint64_t)blen ^ 0xD1B54A32D192ED03ull;
    if (rng_state == 0) rng_state = 1;

    size_t n = alen < max_out ? alen : max_out;
    if (n == 0) return 0;
    memcpy(out, a, n);

    fz_layout L;
    uint32_t bs = fz_layout_parse(&L, out, n) ? L.block_size : 4096;
    if (bs == 0) bs = 4096;

    uint64_t blocks = n / bs;
    if (blocks < 2) return n;

    unsigned splices = 1 + rnd_below(4);
    for (unsigned i = 0; i < splices; i++) {
        uint64_t start = rnd_below((uint32_t)blocks);
        uint64_t count = 1 + rnd_below((uint32_t)(blocks - start));
        uint64_t off   = start * bs;
        uint64_t len   = count * bs;
        if (off + len > n) len = n - off;
        if (off + len > blen) {
            if (off >= blen) continue;
            len = blen - off;
        }
        memcpy(out + off, b + off, (size_t)len);
    }

    if (fz_layout_parse(&L, out, n))
        restamp_sb(&L);
    return n;
}
