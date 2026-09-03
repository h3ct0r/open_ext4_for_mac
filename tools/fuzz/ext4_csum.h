/*
 * ext4_csum.h — ext4's on-disk checksums, computed outside the driver.
 *
 * The mutator needs these because metadata_csum gates almost everything: an
 * edit to an inode, a descriptor or a directory block that does not re-stamp
 * its checksum never reaches the parser it was aimed at, because the driver
 * refuses the structure first. A campaign without a stamper spends its whole
 * budget proving the checksum code works.
 *
 * Deliberately a SECOND implementation. This must not share code with
 * Core/shim or Core/lwext4: it is the oracle for their checksums as well as
 * the mutator's stamper, and a shared bug would cancel out in both roles.
 * Tests/bitmap_csum.py takes the same position for the same reason.
 *
 * Lives in tools/ and never in libext4core.a.
 *
 * The formulas follow the Linux kernel's fs/ext4, which is the definition of
 * what other systems will accept; where lwext4 and the kernel could disagree,
 * the kernel is right by construction, because a volume this driver writes
 * has to be readable by Linux.
 */
#ifndef EXT4_FUZZ_CSUM_H
#define EXT4_FUZZ_CSUM_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

/*
 * crc32c, Castagnoli, reflected: polynomial 0x82F63B78, init ~0, no final
 * xor. EXT4_CSUM_POLY exists so the stamp checker can be built with a wrong
 * polynomial and shown to disagree with every stored checksum on a real
 * image -- which is the only way to know the checker is checking.
 */
#ifndef EXT4_CSUM_POLY
#define EXT4_CSUM_POLY 0x82F63B78u
#endif

uint32_t fz_crc32c(uint32_t crc, const void *buf, size_t len);
uint16_t fz_crc16(uint16_t crc, const void *buf, size_t len);

/* ------------------------------------------------------------- geometry -- */

/*
 * Everything derived from the superblock, with every derived address bounds
 * checked against the image. A resolver that cannot make sense of the
 * superblock sets ok = false, and the mutator then falls back to raw byte
 * mutation -- which is the right answer, because an image whose geometry does
 * not parse is exactly the input a raw mutation is for.
 */
typedef struct {
    uint8_t  *base;
    size_t    len;

    bool      ok;

    uint32_t  block_size;
    uint32_t  first_data_block;
    uint32_t  blocks_per_group;
    uint32_t  inodes_per_group;
    uint32_t  inodes_count;
    uint64_t  blocks_count;
    uint32_t  inode_size;
    uint32_t  first_ino;
    uint32_t  desc_size;
    uint32_t  feature_compat;
    uint32_t  feature_incompat;
    uint32_t  feature_ro_compat;
    uint32_t  group_count;
    uint64_t  gdt_block;
    uint32_t  csum_seed;      /* the seed every other checksum starts from */
    uint8_t   uuid[16];

    bool      has_metadata_csum;
    bool      has_gdt_csum;
    bool      has_64bit;
    bool      has_extents;
} fz_layout;

/* Superblock offsets, named once. */
#define EXT4_SB_OFFSET            1024
#define EXT4_SB_MAGIC             0xEF53u

bool fz_layout_parse(fz_layout *L, uint8_t *base, size_t len);

/* Byte offset of one group descriptor; false when it is off the end. */
bool fz_desc_offset(const fz_layout *L, uint32_t group, uint64_t *off);
/* Byte offset of one inode; false when it is off the end or unresolvable. */
bool fz_inode_offset(const fz_layout *L, uint32_t ino, uint64_t *off);
/* Block address of a group's inode table / block bitmap / inode bitmap. */
bool fz_group_itable(const fz_layout *L, uint32_t group, uint64_t *blk);
bool fz_group_bbitmap(const fz_layout *L, uint32_t group, uint64_t *blk);
bool fz_group_ibitmap(const fz_layout *L, uint32_t group, uint64_t *blk);
/* Is [off, off+n) inside the image? */
bool fz_in_range(const fz_layout *L, uint64_t off, uint64_t n);

/* ------------------------------------------------------------- stamping -- */
/*
 * Each of these recomputes one structure's checksum and writes it back. They
 * are no-ops when the volume has no metadata_csum, and false when the address
 * does not resolve -- a mutation whose checksum could not be restamped is
 * still a legitimate input, it just exercises the checksum gate rather than
 * the parser behind it.
 */
bool fz_stamp_superblock(fz_layout *L);
bool fz_stamp_desc(fz_layout *L, uint32_t group);
bool fz_stamp_inode(fz_layout *L, uint32_t ino);
bool fz_stamp_bbitmap(fz_layout *L, uint32_t group);
bool fz_stamp_ibitmap(fz_layout *L, uint32_t group);
bool fz_stamp_extent_block(fz_layout *L, uint32_t ino, uint64_t block);
bool fz_stamp_dir_block(fz_layout *L, uint32_t ino, uint64_t block);
bool fz_stamp_dx_block(fz_layout *L, uint32_t ino, uint64_t block);
bool fz_stamp_xattr_block(fz_layout *L, uint32_t ino, uint64_t block);

/* -------------------------------------------------------------- reading -- */
/* What is stored, and what should be there. Used by ext4_stampcheck. */
bool fz_check_superblock(fz_layout *L, uint32_t *stored, uint32_t *want);
bool fz_check_desc(fz_layout *L, uint32_t g, uint32_t *stored, uint32_t *want);
bool fz_check_inode(fz_layout *L, uint32_t ino, uint32_t *stored, uint32_t *want);
bool fz_check_bbitmap(fz_layout *L, uint32_t g, uint32_t *stored, uint32_t *want);
bool fz_check_ibitmap(fz_layout *L, uint32_t g, uint32_t *stored, uint32_t *want);

/* Little-endian accessors over the image. */
uint16_t fz_rd16(const uint8_t *p);
uint32_t fz_rd32(const uint8_t *p);
uint64_t fz_rd64(const uint8_t *p);
void     fz_wr16(uint8_t *p, uint16_t v);
void     fz_wr32(uint8_t *p, uint32_t v);

#endif /* EXT4_FUZZ_CSUM_H */
