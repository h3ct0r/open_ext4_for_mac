/* ext4's on-disk checksums, computed outside the driver. See ext4_csum.h. */

#include "ext4_csum.h"

#include <string.h>

/* ------------------------------------------------------------------ crc -- */

static uint32_t crc32c_table[256];
static uint16_t crc16_table[256];
static bool     tables_built;

/*
 * Built at first use rather than written out as a literal table. A table
 * transcribed into a source file is a table nobody can check; this one is
 * derived from the polynomial, and the polynomial is the thing the red-first
 * proof overrides.
 */
static void build_tables(void)
{
    for (unsigned i = 0; i < 256; i++) {
        uint32_t c = i;
        for (int k = 0; k < 8; k++)
            c = (c & 1) ? (EXT4_CSUM_POLY ^ (c >> 1)) : (c >> 1);
        crc32c_table[i] = c;
    }
    /* crc16 as ext4 uses it for the old GDT_CSUM: reflected, poly 0xA001
     * (which is 0x8005 reversed), init 0xFFFF, no final xor. */
    for (unsigned i = 0; i < 256; i++) {
        uint16_t c = (uint16_t)i;
        for (int k = 0; k < 8; k++)
            c = (uint16_t)((c & 1) ? (0xA001u ^ (c >> 1)) : (c >> 1));
        crc16_table[i] = c;
    }
    tables_built = true;
}

uint32_t fz_crc32c(uint32_t crc, const void *buf, size_t len)
{
    const uint8_t *p = (const uint8_t *)buf;
    if (!tables_built) build_tables();
    while (len--)
        crc = crc32c_table[(crc ^ *p++) & 0xFF] ^ (crc >> 8);
    return crc;
}

uint16_t fz_crc16(uint16_t crc, const void *buf, size_t len)
{
    const uint8_t *p = (const uint8_t *)buf;
    if (!tables_built) build_tables();
    while (len--)
        crc = (uint16_t)(crc16_table[(crc ^ *p++) & 0xFF] ^ (crc >> 8));
    return crc;
}

/* ------------------------------------------------------------ accessors -- */

uint16_t fz_rd16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }
uint32_t fz_rd32(const uint8_t *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
uint64_t fz_rd64(const uint8_t *p)
{
    return (uint64_t)fz_rd32(p) | ((uint64_t)fz_rd32(p + 4) << 32);
}
void fz_wr16(uint8_t *p, uint16_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); }
void fz_wr32(uint8_t *p, uint32_t v)
{
    p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8);
    p[2] = (uint8_t)(v >> 16); p[3] = (uint8_t)(v >> 24);
}

/* --------------------------------------------------------------- layout -- */

/* Superblock field offsets. */
#define SB_INODES_COUNT      0x000
#define SB_BLOCKS_COUNT_LO   0x004
#define SB_FIRST_DATA_BLOCK  0x014
#define SB_LOG_BLOCK_SIZE    0x018
#define SB_BLOCKS_PER_GROUP  0x020
#define SB_INODES_PER_GROUP  0x028
#define SB_MAGIC_OFF         0x038
#define SB_FIRST_INO         0x054
#define SB_INODE_SIZE        0x058
#define SB_FEATURE_COMPAT    0x05C
#define SB_FEATURE_INCOMPAT  0x060
#define SB_FEATURE_RO_COMPAT 0x064
#define SB_UUID              0x068
#define SB_BLOCKS_COUNT_HI   0x150
#define SB_DESC_SIZE         0x0FE
#define SB_CHECKSUM_SEED     0x270
#define SB_CHECKSUM          0x3FC

#define INCOMPAT_64BIT       0x00000080u
#define INCOMPAT_CSUM_SEED   0x00002000u
#define INCOMPAT_EXTENTS     0x00000040u
#define RO_COMPAT_GDT_CSUM   0x00000010u
#define RO_COMPAT_METADATA_CSUM 0x00000400u

bool fz_in_range(const fz_layout *L, uint64_t off, uint64_t n)
{
    if (!L->base) return false;
    if (off > (uint64_t)L->len) return false;
    /* Two terms, never their sum: a corrupt field can make off + n wrap, and
     * a wrapped sum compares as comfortably in range. */
    return n <= (uint64_t)L->len - off;
}

bool fz_layout_parse(fz_layout *L, uint8_t *base, size_t len)
{
    memset(L, 0, sizeof(*L));
    L->base = base;
    L->len  = len;

    if (len < EXT4_SB_OFFSET + 1024) return false;
    const uint8_t *sb = base + EXT4_SB_OFFSET;
    if (fz_rd16(sb + SB_MAGIC_OFF) != EXT4_SB_MAGIC) return false;

    uint32_t log_bs = fz_rd32(sb + SB_LOG_BLOCK_SIZE);
    if (log_bs > 6) return false;                 /* 1 KiB .. 64 KiB */
    L->block_size = 1024u << log_bs;

    L->first_data_block = fz_rd32(sb + SB_FIRST_DATA_BLOCK);
    L->blocks_per_group = fz_rd32(sb + SB_BLOCKS_PER_GROUP);
    L->inodes_per_group = fz_rd32(sb + SB_INODES_PER_GROUP);
    L->inodes_count     = fz_rd32(sb + SB_INODES_COUNT);
    L->inode_size       = fz_rd16(sb + SB_INODE_SIZE);
    L->first_ino        = fz_rd32(sb + SB_FIRST_INO);
    L->feature_compat   = fz_rd32(sb + SB_FEATURE_COMPAT);
    L->feature_incompat = fz_rd32(sb + SB_FEATURE_INCOMPAT);
    L->feature_ro_compat= fz_rd32(sb + SB_FEATURE_RO_COMPAT);
    memcpy(L->uuid, sb + SB_UUID, 16);

    L->blocks_count = fz_rd32(sb + SB_BLOCKS_COUNT_LO);
    L->has_64bit    = (L->feature_incompat & INCOMPAT_64BIT) != 0;
    if (L->has_64bit)
        L->blocks_count |= (uint64_t)fz_rd32(sb + SB_BLOCKS_COUNT_HI) << 32;

    L->has_metadata_csum = (L->feature_ro_compat & RO_COMPAT_METADATA_CSUM) != 0;
    L->has_gdt_csum      = (L->feature_ro_compat & RO_COMPAT_GDT_CSUM) != 0;
    L->has_extents       = (L->feature_incompat & INCOMPAT_EXTENTS) != 0;

    /* Without 64BIT the descriptor is the 32-byte form whatever s_desc_size
     * claims, and the _hi halves of every field simply do not exist. */
    L->desc_size = L->has_64bit ? fz_rd16(sb + SB_DESC_SIZE) : 32;
    if (L->desc_size < 32) L->desc_size = 32;
    if (L->desc_size > 64) return false;

    /* metadata_csum_seed: the seed is stored rather than derived, precisely
     * so tune2fs -U can change the UUID without rewriting every checksum. */
    if (L->feature_incompat & INCOMPAT_CSUM_SEED)
        L->csum_seed = fz_rd32(sb + SB_CHECKSUM_SEED);
    else
        L->csum_seed = fz_crc32c(0xFFFFFFFFu, L->uuid, 16);

    if (L->blocks_per_group == 0 || L->inodes_per_group == 0) return false;
    if (L->inode_size < 128 || L->inode_size > L->block_size) return false;
    if ((L->inode_size & (L->inode_size - 1)) != 0) return false;
    if (L->blocks_count <= L->first_data_block) return false;

    uint64_t groups = (L->blocks_count - L->first_data_block +
                       L->blocks_per_group - 1) / L->blocks_per_group;
    if (groups == 0 || groups > 0xFFFFFFFFull) return false;
    L->group_count = (uint32_t)groups;

    L->gdt_block = (uint64_t)L->first_data_block + 1;
    L->ok = true;
    return true;
}

bool fz_desc_offset(const fz_layout *L, uint32_t group, uint64_t *off)
{
    if (!L->ok || group >= L->group_count) return false;
    uint64_t o = L->gdt_block * (uint64_t)L->block_size +
                 (uint64_t)group * L->desc_size;
    if (!fz_in_range(L, o, L->desc_size)) return false;
    *off = o;
    return true;
}

/* The lo/hi split: the hi half exists only in a 64-byte descriptor. */
static bool desc_block(const fz_layout *L, uint32_t group,
                       uint32_t lo_off, uint32_t hi_off, uint64_t *blk)
{
    uint64_t doff;
    if (!fz_desc_offset(L, group, &doff)) return false;
    const uint8_t *d = L->base + doff;
    uint64_t b = fz_rd32(d + lo_off);
    if (L->desc_size >= 64)
        b |= (uint64_t)fz_rd32(d + hi_off) << 32;
    *blk = b;
    return true;
}

bool fz_group_bbitmap(const fz_layout *L, uint32_t g, uint64_t *blk)
{ return desc_block(L, g, 0x00, 0x20, blk); }
bool fz_group_ibitmap(const fz_layout *L, uint32_t g, uint64_t *blk)
{ return desc_block(L, g, 0x04, 0x24, blk); }
bool fz_group_itable(const fz_layout *L, uint32_t g, uint64_t *blk)
{ return desc_block(L, g, 0x08, 0x28, blk); }

bool fz_inode_offset(const fz_layout *L, uint32_t ino, uint64_t *off)
{
    if (!L->ok || ino == 0) return false;
    if (L->inodes_count && ino > L->inodes_count) return false;

    uint32_t group = (ino - 1) / L->inodes_per_group;
    uint32_t index = (ino - 1) % L->inodes_per_group;
    uint64_t itable;
    if (!fz_group_itable(L, group, &itable)) return false;

    uint64_t o = itable * (uint64_t)L->block_size +
                 (uint64_t)index * L->inode_size;
    if (!fz_in_range(L, o, L->inode_size)) return false;
    *off = o;
    return true;
}

/* --------------------------------------------------------------- stamps -- */

/* The per-inode seed every structure an inode owns is checksummed with. */
static bool inode_seed(const fz_layout *L, uint32_t ino, uint32_t *out)
{
    uint64_t off;
    if (!fz_inode_offset(L, ino, &off)) return false;
    uint8_t le[4];
    uint32_t crc;
    fz_wr32(le, ino);
    crc = fz_crc32c(L->csum_seed, le, 4);
    /* i_generation, at 0x64 */
    crc = fz_crc32c(crc, L->base + off + 0x64, 4);
    *out = crc;
    return true;
}

bool fz_stamp_superblock(fz_layout *L)
{
    if (!L->base || L->len < EXT4_SB_OFFSET + 1024) return false;
    if (!L->has_metadata_csum) return true;   /* nothing to stamp */
    uint8_t *sb = L->base + EXT4_SB_OFFSET;
    fz_wr32(sb + SB_CHECKSUM, fz_crc32c(0xFFFFFFFFu, sb, SB_CHECKSUM));
    return true;
}

bool fz_check_superblock(fz_layout *L, uint32_t *stored, uint32_t *want)
{
    if (!L->base || L->len < EXT4_SB_OFFSET + 1024) return false;
    if (!L->has_metadata_csum) return false;
    const uint8_t *sb = L->base + EXT4_SB_OFFSET;
    *stored = fz_rd32(sb + SB_CHECKSUM);
    *want   = fz_crc32c(0xFFFFFFFFu, sb, SB_CHECKSUM);
    return true;
}

static bool desc_csum(const fz_layout *L, uint32_t group, uint32_t *want)
{
    uint64_t doff;
    if (!fz_desc_offset(L, group, &doff)) return false;
    const uint8_t *d = L->base + doff;
    uint8_t le[4];
    fz_wr32(le, group);

    if (L->has_metadata_csum) {
        static const uint8_t zero2[2] = { 0, 0 };
        uint32_t crc = fz_crc32c(L->csum_seed, le, 4);
        crc = fz_crc32c(crc, d, 0x1E);          /* up to bg_checksum */
        crc = fz_crc32c(crc, zero2, 2);         /* the field itself, zeroed */
        if (L->desc_size > 32)
            crc = fz_crc32c(crc, d + 0x20, L->desc_size - 0x20);
        *want = crc & 0xFFFFu;
        return true;
    }
    if (L->has_gdt_csum) {
        uint16_t crc = fz_crc16(0xFFFFu, L->uuid, 16);
        crc = fz_crc16(crc, le, 4);
        crc = fz_crc16(crc, d, 0x1E);
        if (L->has_64bit && L->desc_size > 32)
            crc = fz_crc16(crc, d + 0x20, L->desc_size - 0x20);
        *want = crc;
        return true;
    }
    return false;
}

bool fz_stamp_desc(fz_layout *L, uint32_t group)
{
    uint32_t want; uint64_t doff;
    if (!desc_csum(L, group, &want)) return false;
    if (!fz_desc_offset(L, group, &doff)) return false;
    fz_wr16(L->base + doff + 0x1E, (uint16_t)want);
    return true;
}

bool fz_check_desc(fz_layout *L, uint32_t g, uint32_t *stored, uint32_t *want)
{
    uint64_t doff;
    if (!fz_desc_offset(L, g, &doff)) return false;
    if (!desc_csum(L, g, want)) return false;
    *stored = fz_rd16(L->base + doff + 0x1E);
    return true;
}

/*
 * The inode checksum covers the inode with its own two checksum fields
 * zeroed, so it has to be computed over a copy. i_checksum_hi only exists
 * when i_extra_isize reaches it -- the kernel's EXT4_FITS_IN_INODE -- and
 * stamping it when it does not is writing over whatever field is there.
 */
#define INODE_CSUM_LO_OFF 0x7C
#define INODE_CSUM_HI_OFF 0x82
#define INODE_EXTRA_ISIZE 0x80

static bool inode_csum(const fz_layout *L, uint32_t ino, uint32_t *want,
                       bool *has_hi)
{
    uint64_t off;
    if (!L->has_metadata_csum) return false;
    if (!fz_inode_offset(L, ino, &off)) return false;
    if (L->inode_size > 4096) return false;

    uint8_t copy[4096];
    memcpy(copy, L->base + off, L->inode_size);

    *has_hi = false;
    if (L->inode_size > 128) {
        uint16_t extra = fz_rd16(copy + INODE_EXTRA_ISIZE);
        if (extra >= 4) *has_hi = true;   /* 130 + 2 <= 128 + extra_isize */
    }
    fz_wr16(copy + INODE_CSUM_LO_OFF, 0);
    if (*has_hi) fz_wr16(copy + INODE_CSUM_HI_OFF, 0);

    uint8_t le[4];
    uint32_t crc;
    fz_wr32(le, ino);
    crc = fz_crc32c(L->csum_seed, le, 4);
    crc = fz_crc32c(crc, copy + 0x64, 4);         /* i_generation */
    crc = fz_crc32c(crc, copy, L->inode_size);
    *want = crc;
    return true;
}

bool fz_stamp_inode(fz_layout *L, uint32_t ino)
{
    uint32_t want; bool has_hi; uint64_t off;
    if (!inode_csum(L, ino, &want, &has_hi)) return false;
    if (!fz_inode_offset(L, ino, &off)) return false;
    fz_wr16(L->base + off + INODE_CSUM_LO_OFF, (uint16_t)(want & 0xFFFF));
    if (has_hi)
        fz_wr16(L->base + off + INODE_CSUM_HI_OFF, (uint16_t)(want >> 16));
    return true;
}

bool fz_check_inode(fz_layout *L, uint32_t ino, uint32_t *stored, uint32_t *want)
{
    uint32_t w; bool has_hi; uint64_t off;
    if (!inode_csum(L, ino, &w, &has_hi)) return false;
    if (!fz_inode_offset(L, ino, &off)) return false;
    uint32_t s = fz_rd16(L->base + off + INODE_CSUM_LO_OFF);
    if (has_hi) {
        s |= (uint32_t)fz_rd16(L->base + off + INODE_CSUM_HI_OFF) << 16;
        *want = w;
    } else {
        *want = w & 0xFFFFu;      /* only the low half is stored */
    }
    *stored = s;
    return true;
}

/* Group descriptor flags, at offset 0x12. */
#define BG_INODE_UNINIT 0x0001u
#define BG_BLOCK_UNINIT 0x0002u

/*
 * Bitmaps. The covered size is the group's capacity in bits, not the block.
 *
 * A group flagged UNINIT has no bitmap on the medium at all -- it is
 * materialised the first time something allocates there -- and e2fsprogs
 * stores a zero checksum for it rather than the checksum of a block it has
 * not written. Computing one anyway is how the first version of this
 * disagreed with mke2fs on exactly one structure out of 330: group 4 of s01,
 * flagged INODE_UNINIT, stored 0x00000000. Skipping is the correct answer for
 * both roles -- there is nothing to verify, and stamping a bitmap the
 * filesystem considers absent would make the volume claim it is present.
 */
static bool bitmap_csum(const fz_layout *L, uint32_t g, bool block_map,
                        uint32_t *want, uint64_t *doff_out)
{
    uint64_t blk, doff;
    if (!L->has_metadata_csum) return false;
    if (!fz_desc_offset(L, g, &doff)) return false;

    uint16_t flags = fz_rd16(L->base + doff + 0x12);
    if (block_map && (flags & BG_BLOCK_UNINIT)) return false;
    if (!block_map && (flags & BG_INODE_UNINIT)) return false;

    if (block_map) { if (!fz_group_bbitmap(L, g, &blk)) return false; }
    else           { if (!fz_group_ibitmap(L, g, &blk)) return false; }

    uint64_t sz = block_map ? (uint64_t)L->blocks_per_group / 8
                            : ((uint64_t)L->inodes_per_group + 7) / 8;
    uint64_t off = blk * (uint64_t)L->block_size;
    if (!fz_in_range(L, off, sz)) return false;

    *want = fz_crc32c(L->csum_seed, L->base + off, (size_t)sz);
    *doff_out = doff;
    return true;
}

/* The _hi halves exist only once the descriptor is long enough to hold them:
 * 58 bytes for the block bitmap's, 60 for the inode bitmap's. */
static bool stamp_bitmap(fz_layout *L, uint32_t g, bool block_map)
{
    uint32_t want; uint64_t doff;
    if (!bitmap_csum(L, g, block_map, &want, &doff)) return false;
    uint32_t lo_off = block_map ? 0x18 : 0x1A;
    uint32_t hi_off = block_map ? 0x38 : 0x3A;
    uint32_t hi_end = block_map ? 58u : 60u;
    fz_wr16(L->base + doff + lo_off, (uint16_t)(want & 0xFFFF));
    if (L->desc_size >= hi_end)
        fz_wr16(L->base + doff + hi_off, (uint16_t)(want >> 16));
    return true;
}

bool fz_stamp_bbitmap(fz_layout *L, uint32_t g) { return stamp_bitmap(L, g, true); }
bool fz_stamp_ibitmap(fz_layout *L, uint32_t g) { return stamp_bitmap(L, g, false); }

static bool check_bitmap(fz_layout *L, uint32_t g, bool block_map,
                         uint32_t *stored, uint32_t *want)
{
    uint32_t w; uint64_t doff;
    if (!bitmap_csum(L, g, block_map, &w, &doff)) return false;
    uint32_t lo_off = block_map ? 0x18 : 0x1A;
    uint32_t hi_off = block_map ? 0x38 : 0x3A;
    uint32_t hi_end = block_map ? 58u : 60u;
    uint32_t s = fz_rd16(L->base + doff + lo_off);
    if (L->desc_size >= hi_end) {
        s |= (uint32_t)fz_rd16(L->base + doff + hi_off) << 16;
        *want = w;
    } else {
        *want = w & 0xFFFFu;
    }
    *stored = s;
    return true;
}

bool fz_check_bbitmap(fz_layout *L, uint32_t g, uint32_t *s, uint32_t *w)
{ return check_bitmap(L, g, true, s, w); }
bool fz_check_ibitmap(fz_layout *L, uint32_t g, uint32_t *s, uint32_t *w)
{ return check_bitmap(L, g, false, s, w); }

/*
 * An extent node held in a block carries a 4-byte tail after the last entry
 * slot -- at 12 + 12 * eh_max, which is why a corrupt eh_max used to send the
 * checksum code hundreds of kilobytes past the block (patch 0048). The root
 * header, living inside the inode, has no tail at all.
 */
bool fz_stamp_extent_block(fz_layout *L, uint32_t ino, uint64_t block)
{
    uint32_t seed;
    if (!L->has_metadata_csum) return false;
    if (!inode_seed(L, ino, &seed)) return false;

    uint64_t off = block * (uint64_t)L->block_size;
    if (!fz_in_range(L, off, L->block_size)) return false;
    uint8_t *node = L->base + off;
    if (fz_rd16(node) != 0xF30A) return false;          /* not an extent node */

    uint32_t eh_max = fz_rd16(node + 4);
    uint64_t tail   = 12ull + 12ull * eh_max;
    if (tail + 4 > L->block_size) return false;           /* would not fit */

    fz_wr32(node + tail, fz_crc32c(seed, node, (size_t)tail));
    return true;
}

/*
 * A directory block's tail is the last twelve bytes, shaped like an entry
 * with inode 0 so that a reader without metadata_csum skips it. The checksum
 * covers everything before it.
 */
bool fz_stamp_dir_block(fz_layout *L, uint32_t ino, uint64_t block)
{
    uint32_t seed;
    if (!L->has_metadata_csum) return false;
    if (!inode_seed(L, ino, &seed)) return false;
    if (L->block_size < 32) return false;

    uint64_t off = block * (uint64_t)L->block_size;
    if (!fz_in_range(L, off, L->block_size)) return false;
    uint8_t *b = L->base + off;

    size_t covered = L->block_size - 12;
    fz_wr32(b + covered + 8, fz_crc32c(seed, b, covered));
    return true;
}

/*
 * The htree tail is the awkward one. Its checksum covers the block only up to
 * the end of the entries actually in use -- count_offset + count * 8 -- then
 * the tail's own reserved word, then four zero bytes standing in for the
 * checksum field. count_offset is 32 in a root block and 8 in an interior
 * node, told apart by the fake dirent that precedes the index: a root's
 * second fake entry has rec_len covering the rest of the block, an interior
 * node's single fake entry has rec_len 12... which is also what an ordinary
 * empty directory block looks like. So this refuses rather than guesses when
 * the shape is not clearly one of the two, and a mutation whose dx tail could
 * not be stamped simply exercises the checksum gate instead.
 */
bool fz_stamp_dx_block(fz_layout *L, uint32_t ino, uint64_t block)
{
    uint32_t seed;
    if (!L->has_metadata_csum) return false;
    if (!inode_seed(L, ino, &seed)) return false;

    uint64_t off = block * (uint64_t)L->block_size;
    if (!fz_in_range(L, off, L->block_size)) return false;
    uint8_t *b = L->base + off;

    /* The first fake dirent: inode 0, rec_len 12, name "." elided. */
    if (fz_rd32(b) != 0) return false;

    uint32_t count_offset;
    uint16_t rec0 = fz_rd16(b + 4);
    if (rec0 == 12) {
        /* Root: a second fake dirent follows, then dx_root_info (8 bytes). */
        if (fz_rd32(b + 12) != 0) return false;
        if (fz_rd16(b + 16) != L->block_size - 12) return false;
        count_offset = 32;
    } else if (rec0 == L->block_size) {
        count_offset = 8;                          /* interior node */
    } else {
        return false;
    }

    if (count_offset + 4u > L->block_size) return false;
    uint16_t count = fz_rd16(b + count_offset);
    uint16_t limit = fz_rd16(b + count_offset + 2);
    if (count == 0 || count > limit) return false;
    uint64_t used = (uint64_t)count_offset + (uint64_t)count * 8;
    /* The tail sits in the last entry slot, which is why limit is one short
     * of what the block could hold when checksums are on. */
    uint64_t tail = (uint64_t)count_offset + (uint64_t)limit * 8;
    if (tail + 8 > L->block_size) return false;

    static const uint8_t zero4[4] = { 0, 0, 0, 0 };
    uint32_t crc = fz_crc32c(seed, b, (size_t)used);
    crc = fz_crc32c(crc, b + tail, 4);        /* dt_reserved */
    crc = fz_crc32c(crc, zero4, 4);           /* dt_checksum, zeroed */
    fz_wr32(b + tail + 4, crc);
    return true;
}

/*
 * The xattr block's checksum is seeded with the block number, not with an
 * inode: the block can be shared by several inodes through h_refcount.
 */
bool fz_stamp_xattr_block(fz_layout *L, uint32_t ino, uint64_t block)
{
    (void)ino;
    if (!L->has_metadata_csum) return false;

    uint64_t off = block * (uint64_t)L->block_size;
    if (!fz_in_range(L, off, L->block_size)) return false;
    uint8_t *h = L->base + off;
    if (fz_rd32(h) != 0xEA020000u) return false;    /* h_magic */

    uint8_t le[8];
    fz_wr32(le, (uint32_t)block);
    fz_wr32(le + 4, (uint32_t)(block >> 32));

    uint32_t saved = fz_rd32(h + 0x10);
    fz_wr32(h + 0x10, 0);
    uint32_t crc = fz_crc32c(L->csum_seed, le, 8);
    crc = fz_crc32c(crc, h, L->block_size);
    fz_wr32(h + 0x10, saved);

    fz_wr32(h + 0x10, crc);
    return true;
}
