#!/usr/bin/env python3
"""Read and corrupt block-group bitmap checksums, from outside the driver.

    Tests/bitmap_csum.py show    <image> <group>
    Tests/bitmap_csum.py corrupt <image> <group> block|inode

`show` prints the checksum the group descriptor stores for each bitmap and a
digest of the bitmap block itself. `corrupt` flips one byte inside the region
the checksum covers, which makes the stored checksum wrong without touching
the descriptor.

Nothing here computes a crc32c. That is deliberate: this is the oracle for the
driver's own checksum code, so it must not share an implementation with it. A
bug in ext4_balloc_bitmap_csum would cancel out if this file recomputed the
same wrong value. What it does instead is record the stored bytes before and
after, which answers the only two questions that matter -- did the write get
refused, and did anything rewrite the checksum over the corruption.
"""
import hashlib
import struct
import sys

SB_OFF = 1024


def u16(b, o): return struct.unpack_from("<H", b, o)[0]
def u32(b, o): return struct.unpack_from("<I", b, o)[0]


class Volume:
    def __init__(self, path):
        self.path = path
        with open(path, "rb") as f:
            f.seek(SB_OFF)
            sb = f.read(1024)
        if u16(sb, 0x38) != 0xEF53:
            sys.exit(f"{path}: not an ext2/3/4 image (bad magic)")
        self.block_size = 1024 << u32(sb, 0x18)
        self.first_data_block = u32(sb, 0x14)
        self.blocks_per_group = u32(sb, 0x20)
        self.inodes_per_group = u32(sb, 0x28)
        incompat = u32(sb, 0x60)
        # 64BIT; without it the descriptor is the 32-byte form whatever
        # s_desc_size says, and the _hi checksum halves do not exist.
        self.desc_size = u16(sb, 0xFE) if (incompat & 0x80) else 32
        if self.desc_size < 32:
            self.desc_size = 32
        self.gdt_block = self.first_data_block + 1

    def desc(self, group):
        """(offset, bytes) of one group descriptor."""
        off = self.gdt_block * self.block_size + group * self.desc_size
        with open(self.path, "rb") as f:
            f.seek(off)
            d = f.read(self.desc_size)
        if len(d) != self.desc_size:
            sys.exit(f"group {group} is past the end of {self.path}")
        return off, d

    def bitmap(self, group, which):
        """(block address, bytes the checksum covers) for one bitmap."""
        _, d = self.desc(group)
        lo_off, hi_off = (0x00, 0x20) if which == "block" else (0x04, 0x24)
        blk = u32(d, lo_off)
        if self.desc_size >= 64:
            blk |= u32(d, hi_off) << 32
        covered = (self.blocks_per_group // 8 if which == "block"
                   else (self.inodes_per_group + 7) // 8)
        return blk, covered

    def stored_csum(self, group, which):
        _, d = self.desc(group)
        lo_off, hi_off = (0x18, 0x38) if which == "block" else (0x1A, 0x3A)
        csum = u16(d, lo_off)
        if self.desc_size >= 64:
            csum |= u16(d, hi_off) << 16
        return csum


def cmd_show(vol, group):
    for which in ("block", "inode"):
        blk, covered = vol.bitmap(group, which)
        with open(vol.path, "rb") as f:
            f.seek(blk * vol.block_size)
            data = f.read(covered)
        print("%s_csum=0x%08x %s_bitmap=%s"
              % (which, vol.stored_csum(group, which), which,
                 hashlib.sha256(data).hexdigest()[:16]))


def cmd_corrupt(vol, group, which):
    blk, covered = vol.bitmap(group, which)
    if covered == 0:
        sys.exit("nothing is covered by this checksum")
    # The last covered byte: highest-numbered blocks/inodes in the group, so
    # the flip lands in padding rather than in a live allocation. The point is
    # to break the checksum, not to fabricate a specific allocator state.
    off = blk * vol.block_size + covered - 1
    with open(vol.path, "r+b") as f:
        f.seek(off)
        before = f.read(1)[0]
        f.seek(off)
        f.write(bytes([before ^ 0x80]))
    print("flipped byte %d of the %s bitmap in group %d (0x%02x -> 0x%02x)"
          % (covered - 1, which, group, before, before ^ 0x80))


def main():
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    cmd, image, group = sys.argv[1], sys.argv[2], int(sys.argv[3])
    vol = Volume(image)
    if cmd == "show":
        cmd_show(vol, group)
    elif cmd == "corrupt":
        if len(sys.argv) < 5 or sys.argv[4] not in ("block", "inode"):
            sys.exit("corrupt needs 'block' or 'inode'")
        cmd_corrupt(vol, group, sys.argv[4])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
