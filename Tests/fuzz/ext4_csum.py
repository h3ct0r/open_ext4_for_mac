#!/usr/bin/env python3
"""ext4's on-disk checksums, in Python, for the mutation campaign.

The twin of tools/fuzz/ext4_csum.c. Two implementations exist because two
instruments need them: the in-process libFuzzer harness, which needs a fast
stamper in C, and the toolchain-free campaign that runs in `make validate`,
which must work on a machine with no Homebrew LLVM at all.

They are written from the same formulas and checked against the same
question -- does this agree with what mke2fs actually wrote -- so a
disagreement between them is a bug in one of them rather than a difference of
opinion:

    Tests/fuzz/ext4_csum.py --verify <image>...
    Tests/fuzz/ext4_csum.py --verify --poly 0x82F63B79 <image>...   (must fail)

Neither shares code with the driver. That is the point: this is the oracle
for the driver's checksums as well as the mutator's stamper, and a shared bug
would cancel out in both roles. Tests/bitmap_csum.py takes the same position.
"""
import argparse
import struct
import sys

SB_OFF = 1024
SB_MAGIC = 0xEF53

INCOMPAT_64BIT = 0x00000080
INCOMPAT_CSUM_SEED = 0x00002000
RO_COMPAT_GDT_CSUM = 0x00000010
RO_COMPAT_METADATA_CSUM = 0x00000400

BG_INODE_UNINIT = 0x0001
BG_BLOCK_UNINIT = 0x0002

# Superblock field offsets, named once, the same names the C twin uses.
SB_INODES_COUNT = 0x000
SB_BLOCKS_COUNT_LO = 0x004
SB_FIRST_DATA_BLOCK = 0x014
SB_LOG_BLOCK_SIZE = 0x018
SB_BLOCKS_PER_GROUP = 0x020
SB_INODES_PER_GROUP = 0x028
SB_MAGIC_OFF = 0x038
SB_FIRST_INO = 0x054
SB_INODE_SIZE = 0x058
SB_FEATURE_COMPAT = 0x05C
SB_FEATURE_INCOMPAT = 0x060
SB_FEATURE_RO_COMPAT = 0x064
SB_UUID = 0x068
SB_DESC_SIZE = 0x0FE
SB_BLOCKS_COUNT_HI = 0x150
SB_CHECKSUM_SEED = 0x270
SB_CHECKSUM = 0x3FC

INODE_CSUM_LO = 0x7C
INODE_CSUM_HI = 0x82
INODE_EXTRA_ISIZE = 0x80
INODE_GENERATION = 0x64

DEFAULT_POLY = 0x82F63B78


class Crc:
    """crc32c and crc16, table-driven from the polynomial.

    Built rather than transcribed: a table written out as a literal is a table
    nobody can check, and --poly is what makes the checker checkable.
    """

    def __init__(self, poly=DEFAULT_POLY):
        self.poly = poly
        self.t32 = []
        for i in range(256):
            c = i
            for _ in range(8):
                c = (poly ^ (c >> 1)) if (c & 1) else (c >> 1)
            self.t32.append(c & 0xFFFFFFFF)
        self.t16 = []
        for i in range(256):
            c = i
            for _ in range(8):
                c = (0xA001 ^ (c >> 1)) if (c & 1) else (c >> 1)
            self.t16.append(c & 0xFFFF)

    def crc32c(self, crc, data):
        t = self.t32
        for b in data:
            crc = t[(crc ^ b) & 0xFF] ^ (crc >> 8)
        return crc & 0xFFFFFFFF

    def crc16(self, crc, data):
        t = self.t16
        for b in data:
            crc = t[(crc ^ b) & 0xFF] ^ (crc >> 8)
        return crc & 0xFFFF


def u16(b, o):
    return struct.unpack_from("<H", b, o)[0]


def u32(b, o):
    return struct.unpack_from("<I", b, o)[0]


def p16(b, o, v):
    struct.pack_into("<H", b, o, v & 0xFFFF)


def p32(b, o, v):
    struct.pack_into("<I", b, o, v & 0xFFFFFFFF)


class Layout:
    """Everything derived from the superblock, over a bytearray.

    Raises ValueError when the image does not resolve. Callers treat that as
    "mutate raw bytes instead", which is the right answer for an image whose
    geometry does not parse.
    """

    def __init__(self, data, poly=DEFAULT_POLY):
        if len(data) < SB_OFF + 1024:
            raise ValueError("too small to hold a superblock")
        self.d = data
        self.crc = Crc(poly)
        sb = memoryview(data)[SB_OFF:SB_OFF + 1024]
        if u16(sb, SB_MAGIC_OFF) != SB_MAGIC:
            raise ValueError("bad magic")

        log_bs = u32(sb, SB_LOG_BLOCK_SIZE)
        if log_bs > 6:
            raise ValueError("implausible log_block_size")
        self.block_size = 1024 << log_bs
        self.first_data_block = u32(sb, SB_FIRST_DATA_BLOCK)
        self.blocks_per_group = u32(sb, SB_BLOCKS_PER_GROUP)
        self.inodes_per_group = u32(sb, SB_INODES_PER_GROUP)
        self.inodes_count = u32(sb, SB_INODES_COUNT)
        self.inode_size = u16(sb, SB_INODE_SIZE)
        self.first_ino = u32(sb, SB_FIRST_INO)
        self.feature_compat = u32(sb, SB_FEATURE_COMPAT)
        self.feature_incompat = u32(sb, SB_FEATURE_INCOMPAT)
        self.feature_ro_compat = u32(sb, SB_FEATURE_RO_COMPAT)
        self.uuid = bytes(sb[SB_UUID:SB_UUID + 16])

        self.has_64bit = bool(self.feature_incompat & INCOMPAT_64BIT)
        self.blocks_count = u32(sb, SB_BLOCKS_COUNT_LO)
        if self.has_64bit:
            self.blocks_count |= u32(sb, SB_BLOCKS_COUNT_HI) << 32

        self.has_metadata_csum = bool(self.feature_ro_compat & RO_COMPAT_METADATA_CSUM)
        self.has_gdt_csum = bool(self.feature_ro_compat & RO_COMPAT_GDT_CSUM)

        # Without 64BIT the descriptor is the 32-byte form whatever s_desc_size
        # claims, and the _hi halves simply do not exist.
        self.desc_size = u16(sb, SB_DESC_SIZE) if self.has_64bit else 32
        self.desc_size = max(self.desc_size, 32)
        if self.desc_size > 64:
            raise ValueError("implausible desc_size")

        if self.feature_incompat & INCOMPAT_CSUM_SEED:
            self.csum_seed = u32(sb, SB_CHECKSUM_SEED)
        else:
            self.csum_seed = self.crc.crc32c(0xFFFFFFFF, self.uuid)

        if not self.blocks_per_group or not self.inodes_per_group:
            raise ValueError("zero group geometry")
        if self.inode_size < 128 or self.inode_size > self.block_size:
            raise ValueError("implausible inode_size")
        if self.inode_size & (self.inode_size - 1):
            raise ValueError("inode_size is not a power of two")
        if self.blocks_count <= self.first_data_block:
            raise ValueError("blocks_count below first_data_block")

        groups = (self.blocks_count - self.first_data_block +
                  self.blocks_per_group - 1) // self.blocks_per_group
        if groups < 1 or groups > 0xFFFFFFFF:
            raise ValueError("implausible group count")
        self.group_count = groups
        self.gdt_block = self.first_data_block + 1

    # ------------------------------------------------------------ addresses --

    def in_range(self, off, n):
        # Two terms, never their sum: a corrupt field makes off + n wrap, and a
        # wrapped sum compares as comfortably in range.
        return 0 <= off <= len(self.d) and n <= len(self.d) - off

    def desc_offset(self, g):
        if g >= self.group_count:
            return None
        off = self.gdt_block * self.block_size + g * self.desc_size
        return off if self.in_range(off, self.desc_size) else None

    def _desc_block(self, g, lo, hi):
        off = self.desc_offset(g)
        if off is None:
            return None
        b = u32(self.d, off + lo)
        if self.desc_size >= 64:
            b |= u32(self.d, off + hi) << 32
        return b

    def group_bbitmap(self, g):
        return self._desc_block(g, 0x00, 0x20)

    def group_ibitmap(self, g):
        return self._desc_block(g, 0x04, 0x24)

    def group_itable(self, g):
        return self._desc_block(g, 0x08, 0x28)

    def inode_offset(self, ino):
        if ino < 1 or (self.inodes_count and ino > self.inodes_count):
            return None
        g, idx = divmod(ino - 1, self.inodes_per_group)
        itable = self.group_itable(g)
        if itable is None:
            return None
        off = itable * self.block_size + idx * self.inode_size
        return off if self.in_range(off, self.inode_size) else None

    def inode_seed(self, ino):
        off = self.inode_offset(ino)
        if off is None:
            return None
        crc = self.crc.crc32c(self.csum_seed, struct.pack("<I", ino))
        return self.crc.crc32c(crc, self.d[off + INODE_GENERATION:
                                          off + INODE_GENERATION + 4])

    # ------------------------------------------------------------- checksums --

    def superblock_csum(self):
        return self.crc.crc32c(0xFFFFFFFF, self.d[SB_OFF:SB_OFF + SB_CHECKSUM])

    def stamp_superblock(self):
        if not self.has_metadata_csum:
            return False
        p32(self.d, SB_OFF + SB_CHECKSUM, self.superblock_csum())
        return True

    def desc_csum(self, g):
        off = self.desc_offset(g)
        if off is None:
            return None
        d = self.d[off:off + self.desc_size]
        le = struct.pack("<I", g)
        if self.has_metadata_csum:
            crc = self.crc.crc32c(self.csum_seed, le)
            crc = self.crc.crc32c(crc, d[:0x1E])
            crc = self.crc.crc32c(crc, b"\x00\x00")
            if self.desc_size > 32:
                crc = self.crc.crc32c(crc, d[0x20:self.desc_size])
            return crc & 0xFFFF
        if self.has_gdt_csum:
            crc = self.crc.crc16(0xFFFF, self.uuid)
            crc = self.crc.crc16(crc, le)
            crc = self.crc.crc16(crc, d[:0x1E])
            if self.has_64bit and self.desc_size > 32:
                crc = self.crc.crc16(crc, d[0x20:self.desc_size])
            return crc
        return None

    def stamp_desc(self, g):
        want = self.desc_csum(g)
        off = self.desc_offset(g)
        if want is None or off is None:
            return False
        p16(self.d, off + 0x1E, want)
        return True

    def inode_csum(self, ino):
        """(checksum, has_hi) or None."""
        if not self.has_metadata_csum:
            return None
        off = self.inode_offset(ino)
        if off is None:
            return None
        copy = bytearray(self.d[off:off + self.inode_size])
        has_hi = False
        if self.inode_size > 128 and u16(copy, INODE_EXTRA_ISIZE) >= 4:
            has_hi = True
        p16(copy, INODE_CSUM_LO, 0)
        if has_hi:
            p16(copy, INODE_CSUM_HI, 0)
        crc = self.crc.crc32c(self.csum_seed, struct.pack("<I", ino))
        crc = self.crc.crc32c(crc, copy[INODE_GENERATION:INODE_GENERATION + 4])
        crc = self.crc.crc32c(crc, copy)
        return crc, has_hi

    def stamp_inode(self, ino):
        r = self.inode_csum(ino)
        off = self.inode_offset(ino)
        if r is None or off is None:
            return False
        crc, has_hi = r
        p16(self.d, off + INODE_CSUM_LO, crc & 0xFFFF)
        if has_hi:
            p16(self.d, off + INODE_CSUM_HI, crc >> 16)
        return True

    def _bitmap_csum(self, g, block_map):
        # An UNINIT group has no bitmap on the medium; e2fsprogs stores a zero
        # rather than the checksum of a block it never wrote.
        if not self.has_metadata_csum:
            return None
        off = self.desc_offset(g)
        if off is None:
            return None
        flags = u16(self.d, off + 0x12)
        if block_map and (flags & BG_BLOCK_UNINIT):
            return None
        if not block_map and (flags & BG_INODE_UNINIT):
            return None
        blk = self.group_bbitmap(g) if block_map else self.group_ibitmap(g)
        if blk is None:
            return None
        sz = (self.blocks_per_group // 8 if block_map
              else (self.inodes_per_group + 7) // 8)
        boff = blk * self.block_size
        if not self.in_range(boff, sz):
            return None
        return self.crc.crc32c(self.csum_seed, self.d[boff:boff + sz])

    def stamp_bitmap(self, g, block_map):
        want = self._bitmap_csum(g, block_map)
        off = self.desc_offset(g)
        if want is None or off is None:
            return False
        lo, hi, hi_end = ((0x18, 0x38, 58) if block_map else (0x1A, 0x3A, 60))
        p16(self.d, off + lo, want & 0xFFFF)
        if self.desc_size >= hi_end:
            p16(self.d, off + hi, want >> 16)
        return True

    def stamp_group(self, g):
        self.stamp_bitmap(g, True)
        self.stamp_bitmap(g, False)
        self.stamp_desc(g)

    # ------------------------------------------------------------- verifying --

    def verify(self):
        """[(what, stored, computed)] for everything that disagrees, and a count."""
        bad, checked, live = [], 0, 0
        if self.has_metadata_csum:
            stored = u32(self.d, SB_OFF + SB_CHECKSUM)
            want = self.superblock_csum()
            checked += 1
            if stored != want:
                bad.append(("superblock", stored, want))

        for g in range(self.group_count):
            off = self.desc_offset(g)
            if off is None:
                continue
            want = self.desc_csum(g)
            if want is not None:
                checked += 1
                stored = u16(self.d, off + 0x1E)
                if stored != want:
                    bad.append(("group %d descriptor" % g, stored, want))
            for block_map, lo, hi, hi_end, label in (
                    (True, 0x18, 0x38, 58, "block"),
                    (False, 0x1A, 0x3A, 60, "inode")):
                want = self._bitmap_csum(g, block_map)
                if want is None:
                    continue
                checked += 1
                stored = u16(self.d, off + lo)
                if self.desc_size >= hi_end:
                    stored |= u16(self.d, off + hi) << 16
                else:
                    want &= 0xFFFF
                if stored != want:
                    bad.append(("group %d %s bitmap" % (g, label), stored, want))

        limit = min(self.inodes_count, 4096)
        for ino in range(1, limit + 1):
            off = self.inode_offset(ino)
            if off is None:
                continue
            if u16(self.d, off) == 0 and u16(self.d, off + 0x1A) == 0:
                continue
            r = self.inode_csum(ino)
            if r is None:
                continue
            crc, has_hi = r
            checked += 1
            live += 1
            stored = u16(self.d, off + INODE_CSUM_LO)
            want = crc & 0xFFFF
            if has_hi:
                stored |= u16(self.d, off + INODE_CSUM_HI) << 16
                want = crc
            if stored != want:
                bad.append(("inode %d" % ino, stored, want))

        return bad, checked, live


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--verify", action="store_true",
                    help="recompute every checksum and compare")
    ap.add_argument("--poly", default=hex(DEFAULT_POLY),
                    help="crc32c polynomial (the wrong one must fail)")
    ap.add_argument("images", nargs="+")
    a = ap.parse_args()
    poly = int(a.poly, 0)

    print("ext4_csum.py: polynomial 0x%08x" % poly)
    rc = 0
    for path in a.images:
        data = bytearray(open(path, "rb").read())
        try:
            L = Layout(data, poly)
        except ValueError as e:
            print("  %s: not an image this resolver understands (%s)" % (path, e))
            continue
        print("  %s: %d-byte blocks, %d group(s), %d-byte inodes, desc %d, "
              "metadata_csum %s"
              % (path, L.block_size, L.group_count, L.inode_size, L.desc_size,
                 "on" if L.has_metadata_csum else
                 ("gdt_csum" if L.has_gdt_csum else "off")))
        bad, checked, live = L.verify()
        for what, stored, want in bad[:12]:
            print("    BAD  %-28s stored 0x%08x, computed 0x%08x"
                  % (what, stored, want))
        if len(bad) > 12:
            print("    ... and %d more" % (len(bad) - 12))
        print("    %d checked, %d mismatched (%d live inode(s))"
              % (checked, len(bad), live))
        # metadata_csum on and nothing checked means the resolver failed and is
        # wearing a pass.
        if L.has_metadata_csum and (checked == 0 or live == 0):
            print("    BAD  metadata_csum is on and nothing meaningful was checked")
            rc = 1
        if bad:
            rc = 1
    print("MISMATCHES PRESENT" if rc else "all checksums agree")
    return rc


if __name__ == "__main__":
    sys.exit(main())
