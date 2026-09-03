#!/usr/bin/env python3
"""Structure-aware mutation of ext4 images, for the campaign that runs in
`make validate`.

The Python twin of tools/fuzz/ext4_mutator.c. It exists because the in-process
libFuzzer harness needs Homebrew LLVM, and `make validate` must never need it:
validation runs on whatever compiler the machine has. This drives the release
`ext4dump` over mutated files instead, which is slower per input and reaches
exactly the same parsers.

Both read the same tools/fuzz/mutweights.json, so the two instruments aim at
the same places and a finding from one is reproducible by the other.

    mutate_image.py --seed 7 --count 300 --out DIR --mode restamp seed.img

Writes NNN.img beside NNN.json, where the JSON records every edit as
{off, old, new, what} plus what was re-stamped afterwards -- so a finding can
be described in a sentence instead of as three megabytes of bytes.
"""
import argparse
import json
import os
import random
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))          # Tests/, for bitmap_csum

from ext4_csum import Layout, u16, u32, p16, p32, SB_OFF   # noqa: E402

# The plan asks this to share Tests/bitmap_csum.py's Volume, and it does --
# not because the parsing is hard, but because two independent resolvers
# agreeing on where the group descriptor table is is worth more than one
# resolver being confident. A disagreement aborts rather than being averaged.
try:
    from bitmap_csum import Volume                          # noqa: E402
except Exception:                                           # pragma: no cover
    Volume = None

WEIGHTS_PATH = os.path.join(os.path.dirname(HERE), "..", "tools", "fuzz",
                            "mutweights.json")

# The values that break arithmetic, by width. A corrupt filesystem is not
# random bytes: it is a plausible structure with one field that is zero, one
# past the end, or all ones.
INTERESTING = [0, 1, 2, 3, 4, 7, 8, 12, 16, 32, 63, 64, 127, 128, 255, 256,
               0x7FFF, 0x8000, 0xFFFF, 0x10000, 0x7FFFFFFF, 0x80000000,
               0xFFFFFFFF, 0xFFFFFFFE]

INODE_MODE, INODE_SIZE_LO, INODE_LINKS = 0x00, 0x04, 0x1A
INODE_BLOCKS_LO, INODE_FLAGS, INODE_IBLOCK = 0x1C, 0x20, 0x28
INODE_GENERATION, INODE_FILE_ACL, INODE_SIZE_HI = 0x64, 0x68, 0x6C
INODE_EXTRA = 0x80
FLAG_EXTENTS, FLAG_INDEX = 0x00080000, 0x00001000


def load_weights():
    fallback = {"raw": 20, "superblock": 12, "group_desc": 10, "inode": 12,
                "extent": 10, "indirect": 5, "dirent": 10, "htree": 10,
                "xattr": 8, "jbd2": 8, "block": 5}
    skip = 5
    try:
        with open(WEIGHTS_PATH) as f:
            j = json.load(f)
        w = dict(fallback)
        w.update({k: int(v) for k, v in j.get("weights", {}).items() if k in w})
        skip = int(j.get("restamp_skip_percent", skip))
        return w, skip, WEIGHTS_PATH
    except Exception:
        return fallback, skip, None


class Mutator:
    def __init__(self, data, rng, weights, skip_pct, restamp=True):
        self.d = data
        self.rng = rng
        self.weights = weights
        self.skip_pct = skip_pct
        self.restamp = restamp
        self.edits = []
        self.restamped = []
        try:
            self.L = Layout(data)
        except ValueError:
            self.L = None

    # ------------------------------------------------------------- helpers --

    def val(self, width):
        if self.rng.random() < 0.70:
            v = self.rng.choice(INTERESTING)
        else:
            v = self.rng.getrandbits(64)
        return v & ((1 << (8 * width)) - 1)

    def poke(self, off, width, value, what):
        if off < 0 or off + width > len(self.d):
            return False
        old = bytes(self.d[off:off + width])
        self.d[off:off + width] = value.to_bytes(width, "little")
        self.edits.append({"off": off, "old": old.hex(),
                           "new": bytes(self.d[off:off + width]).hex(),
                           "what": what})
        return True

    def poke_be(self, off, width, value, what):
        if off < 0 or off + width > len(self.d):
            return False
        old = bytes(self.d[off:off + width])
        self.d[off:off + width] = value.to_bytes(width, "big")
        self.edits.append({"off": off, "old": old.hex(),
                           "new": bytes(self.d[off:off + width]).hex(),
                           "what": what})
        return True

    def stamp_sb(self):
        # Five per cent of the time, deliberately not: the checksum gate is
        # code too, and a corpus of only well-formed volumes never exercises
        # the refusal.
        if not self.restamp or self.L is None:
            return
        if self.rng.randrange(100) < self.skip_pct:
            return
        if self.L.stamp_superblock():
            self.restamped.append("superblock")

    def stamp_inode(self, ino):
        if self.restamp and self.L is not None and self.L.stamp_inode(ino):
            self.restamped.append("inode %d" % ino)

    def stamp_group(self, g):
        if self.restamp and self.L is not None:
            self.L.stamp_group(g)
            self.restamped.append("group %d" % g)

    def live_inode(self):
        L = self.L
        limit = min(L.inodes_count or 1, 100000)
        if self.rng.random() < 0.25:
            for ino in (2, 7, 8, 11):
                if L.inode_offset(ino) is not None:
                    return ino
        for _ in range(64):
            ino = self.rng.randrange(1, limit + 1)
            off = L.inode_offset(ino)
            if off is None:
                continue
            if u16(self.d, off) or u16(self.d, off + INODE_LINKS):
                return ino
        return None

    def inode_first_block(self, ino):
        L = self.L
        off = L.inode_offset(ino)
        if off is None:
            return None
        flags = u32(self.d, off + INODE_FLAGS)
        if flags & FLAG_EXTENTS:
            eh = off + INODE_IBLOCK
            if u16(self.d, eh) != 0xF30A:
                return None
            entries, depth = u16(self.d, eh + 2), u16(self.d, eh + 6)
            if not 1 <= entries <= 4:
                return None
            e = eh + 12
            if depth == 0:
                blk = u32(self.d, e + 8) | (u16(self.d, e + 6) << 32)
            else:
                blk = u32(self.d, e + 4) | (u16(self.d, e + 8) << 32)
            return blk or None
        blk = u32(self.d, off + INODE_IBLOCK)
        return blk or None

    def is_dir(self, ino):
        off = self.L.inode_offset(ino)
        return off is not None and (u16(self.d, off) & 0xF000) == 0x4000

    # ---------------------------------------------------------- strategies --

    SB_FIELDS = [(0x000, 4, "s_inodes_count"), (0x004, 4, "s_blocks_count_lo"),
                 (0x014, 4, "s_first_data_block"), (0x018, 4, "s_log_block_size"),
                 (0x01C, 4, "s_log_cluster_size"), (0x020, 4, "s_blocks_per_group"),
                 (0x024, 4, "s_clusters_per_group"), (0x028, 4, "s_inodes_per_group"),
                 (0x03A, 2, "s_state"), (0x04C, 4, "s_rev_level"),
                 (0x054, 4, "s_first_ino"), (0x058, 2, "s_inode_size"),
                 (0x05C, 4, "s_feature_compat"), (0x060, 4, "s_feature_incompat"),
                 (0x064, 4, "s_feature_ro_compat"), (0x0E0, 4, "s_journal_inum"),
                 (0x0EC, 4, "s_last_orphan"), (0x0FC, 2, "s_reserved_gdt_blocks"),
                 (0x0FE, 2, "s_desc_size"), (0x150, 4, "s_blocks_count_hi"),
                 (0x175, 1, "s_log_groups_per_flex"), (0x26C, 1, "s_checksum_type"),
                 (0x270, 4, "s_checksum_seed")]

    def s_superblock(self):
        off, w, name = self.rng.choice(self.SB_FIELDS)
        self.poke(SB_OFF + off, w, self.val(w), name)
        self.stamp_sb()

    DESC_FIELDS = [(0x00, 4, "bg_block_bitmap_lo"), (0x04, 4, "bg_inode_bitmap_lo"),
                   (0x08, 4, "bg_inode_table_lo"), (0x0C, 2, "bg_free_blocks_lo"),
                   (0x0E, 2, "bg_free_inodes_lo"), (0x10, 2, "bg_used_dirs_lo"),
                   (0x12, 2, "bg_flags"), (0x1C, 2, "bg_itable_unused_lo"),
                   (0x1E, 2, "bg_checksum"), (0x20, 4, "bg_block_bitmap_hi"),
                   (0x24, 4, "bg_inode_bitmap_hi"), (0x28, 4, "bg_inode_table_hi")]

    def s_group_desc(self):
        L = self.L
        g = self.rng.randrange(L.group_count)
        doff = L.desc_offset(g)
        if doff is None:
            return
        cand = [f for f in self.DESC_FIELDS if f[0] < L.desc_size]
        off, w, name = self.rng.choice(cand)
        self.poke(doff + off, w, self.val(w), "group %d %s" % (g, name))
        # Not when the field poked WAS the checksum: leaving that wrong is the
        # point of having chosen it.
        if off != 0x1E:
            self.stamp_group(g)
        self.stamp_sb()

    INODE_FIELDS = [(INODE_MODE, 2, "i_mode"), (INODE_SIZE_LO, 4, "i_size_lo"),
                    (INODE_LINKS, 2, "i_links_count"),
                    (INODE_BLOCKS_LO, 4, "i_blocks_lo"),
                    (INODE_FLAGS, 4, "i_flags"),
                    (INODE_GENERATION, 4, "i_generation"),
                    (INODE_FILE_ACL, 4, "i_file_acl_lo"),
                    (INODE_SIZE_HI, 4, "i_size_high"),
                    (INODE_EXTRA, 2, "i_extra_isize"), (0x14, 4, "i_dtime")]

    def s_inode(self):
        ino = self.live_inode()
        if ino is None:
            return
        off = self.L.inode_offset(ino)
        cand = [f for f in self.INODE_FIELDS if f[0] + f[1] <= self.L.inode_size]
        o, w, name = self.rng.choice(cand)
        self.poke(off + o, w, self.val(w), "inode %d %s" % (ino, name))
        self.stamp_inode(ino)
        self.stamp_sb()

    def s_extent(self):
        ino = self.live_inode()
        if ino is None:
            return
        off = self.L.inode_offset(ino)
        if not (u32(self.d, off + INODE_FLAGS) & FLAG_EXTENTS):
            return
        eh = off + INODE_IBLOCK
        # Half the time the root header, which lives inside the inode and so
        # never passes through the block reader that validates the others.
        if self.rng.random() < 0.5 or u16(self.d, eh) != 0xF30A:
            which = self.rng.randrange(4)
            o, name = [(0, "eh_magic"), (2, "eh_entries"),
                       (4, "eh_max"), (6, "eh_depth")][which]
            v = self.rng.randrange(6) if which == 3 else self.val(2)
            self.poke(eh + o, 2, v, "inode %d root %s" % (ino, name))
        else:
            entries, depth = u16(self.d, eh + 2), u16(self.d, eh + 6)
            if not 1 <= entries <= 4:
                return
            e = eh + 12 + 12 * self.rng.randrange(entries)
            if depth == 0:
                o, w, name = self.rng.choice(
                    [(0, 4, "ee_block"), (4, 2, "ee_len"),
                     (6, 2, "ee_start_hi"), (8, 4, "ee_start_lo")])
            else:
                o, w, name = self.rng.choice(
                    [(0, 4, "ei_block"), (4, 4, "ei_leaf_lo"), (8, 2, "ei_leaf_hi")])
            self.poke(e + o, w, self.val(w), "inode %d extent %s" % (ino, name))
        self.stamp_inode(ino)
        self.stamp_sb()

    def s_indirect(self):
        ino = self.live_inode()
        if ino is None:
            return
        off = self.L.inode_offset(ino)
        if u32(self.d, off + INODE_FLAGS) & FLAG_EXTENTS:
            return
        slot = self.rng.randrange(15)
        v = (self.rng.choice([0, 1, 2, 0xFFFFFFFF, 0x7FFFFFFF])
             if self.rng.random() < 0.6 else self.val(4))
        self.poke(off + INODE_IBLOCK + 4 * slot, 4, v,
                  "inode %d i_block[%d]" % (ino, slot))
        ind = u32(self.d, off + INODE_IBLOCK + 48)
        boff = ind * self.L.block_size
        if ind and self.rng.random() < 0.5 and self.L.in_range(boff, self.L.block_size):
            w = self.rng.randrange(self.L.block_size // 4)
            self.poke(boff + 4 * w, 4, self.val(4),
                      "indirect block %d word %d" % (ind, w))
        self.stamp_inode(ino)
        self.stamp_sb()

    def s_dirent(self):
        ino = next((c for c in (self.live_inode() for _ in range(32))
                    if c and self.is_dir(c)), None)
        if ino is None:
            return
        blk = self.inode_first_block(ino)
        if blk is None:
            return
        bs = self.L.block_size
        boff = blk * bs
        if not self.L.in_range(boff, bs):
            return
        pos, chosen, seen = 0, 0, 0
        while pos + 8 < bs:
            rec = u16(self.d, boff + pos + 4)
            if rec < 8 or pos + rec > bs:
                break
            if seen and self.rng.random() < 0.4:
                chosen = pos
                break
            seen += 1
            chosen = pos
            pos += rec
        d = boff + chosen
        pick = self.rng.randrange(5)
        if pick == 0:
            self.poke(d, 4, self.val(4), "dirent inode")
        elif pick == 1:
            v = (self.rng.choice([0, 1, 4, 7, 9, 0xFFFF])
                 if self.rng.random() < 0.7 else (bs + 4) & 0xFFFF)
            self.poke(d + 4, 2, v, "dirent rec_len")
        elif pick == 2:
            self.poke(d + 6, 1, self.val(1), "dirent name_len")
        elif pick == 3:
            self.poke(d + 7, 1, 8 + self.rng.randrange(248), "dirent file_type")
        else:
            self.poke(boff + bs - 12 + self.rng.randrange(12), 1,
                      self.val(1), "dirent tail")
        self.stamp_sb()

    def s_htree(self):
        ino = None
        for _ in range(48):
            c = self.live_inode()
            if not c or not self.is_dir(c):
                continue
            off = self.L.inode_offset(c)
            if u32(self.d, off + INODE_FLAGS) & FLAG_INDEX:
                ino = c
                break
        if ino is None:
            return
        blk = self.inode_first_block(ino)
        if blk is None:
            return
        bs = self.L.block_size
        boff = blk * bs
        if not self.L.in_range(boff, bs) or bs < 64:
            return
        pick = self.rng.randrange(6)
        if pick == 0:
            self.poke(boff + 28, 1, self.rng.randrange(8), "dx hash_version")
        elif pick == 1:
            self.poke(boff + 29, 1, self.val(1), "dx info_length")
        elif pick == 2:
            v = self.rng.randrange(4) if self.rng.random() < 0.5 else 255
            self.poke(boff + 30, 1, v, "dx indirect_levels")
        elif pick == 3:
            self.poke(boff + 32, 2, self.val(2), "dx limit")
        elif pick == 4:
            self.poke(boff + 34, 2, self.val(2), "dx count")
        else:
            count = u16(self.d, boff + 34) or 1
            count = min(count, 512)
            e = 32 + 8 * (1 + self.rng.randrange(count))
            if e + 8 <= bs:
                self.poke(boff + e + 4, 4, self.val(4), "dx entry block")
        self.stamp_sb()

    def s_xattr(self):
        ino = self.live_inode()
        if ino is None:
            return
        off = self.L.inode_offset(ino)
        acl = u32(self.d, off + INODE_FILE_ACL)
        bs = self.L.block_size
        boff = acl * bs
        if acl and self.L.in_range(boff, bs) and self.rng.random() < 0.6:
            o, w, name = self.rng.choice(
                [(0x00, 4, "h_magic"), (0x04, 4, "h_refcount"),
                 (0x08, 4, "h_blocks"), (0x10, 4, "h_checksum"),
                 (0x20, 1, "entry name_len"), (0x21, 1, "entry name_index"),
                 (0x22, 2, "entry value_offs"), (0x24, 4, "entry value_inum"),
                 (0x28, 4, "entry value_size")])
            self.poke(boff + o, w, self.val(w), "xattr block %s" % name)
        else:
            if self.L.inode_size <= 128:
                return
            ibody = off + 128 + u16(self.d, off + INODE_EXTRA)
            if ibody + 8 > off + self.L.inode_size:
                return
            o, w, name = self.rng.choice(
                [(0, 4, "ibody h_magic"), (4, 1, "ibody name_len"),
                 (6, 2, "ibody value_offs")])
            self.poke(ibody + o, w, self.val(w), "xattr %s" % name)
        self.stamp_inode(ino)
        self.stamp_sb()

    def s_jbd2(self):
        L = self.L
        jinum = u32(self.d, SB_OFF + 0x0E0) or 8
        if jinum > (L.inodes_count or 0):
            jinum = 8
        jblk = self.inode_first_block(jinum)
        if jblk is None:
            return
        joff = jblk * L.block_size
        if not L.in_range(joff, L.block_size):
            return
        if struct.unpack_from(">I", self.d, joff)[0] != 0xC03B3998:
            return
        if self.rng.random() < 0.6:
            o, w, name = self.rng.choice(
                [(0x0C, 4, "s_blocksize"), (0x10, 4, "s_maxlen"),
                 (0x14, 4, "s_first"), (0x18, 4, "s_sequence"),
                 (0x1C, 4, "s_start"), (0x24, 4, "s_feature_compat"),
                 (0x28, 4, "s_feature_incompat"), (0x2C, 4, "s_feature_ro_compat"),
                 (0x50, 1, "s_checksum_type")])
            self.poke_be(joff + o, w, self.val(w), "jbd2 %s" % name)
        else:
            maxlen = struct.unpack_from(">I", self.d, joff + 0x10)[0]
            if not 1 < maxlen < (1 << 20):
                maxlen = 64
            which = 1 + self.rng.randrange(min(maxlen - 1, 64))
            boff = joff + which * L.block_size
            if not L.in_range(boff, L.block_size):
                return
            if struct.unpack_from(">I", self.d, boff)[0] != 0xC03B3998:
                self.poke_be(boff, 4, 0xC03B3998, "jbd2 fake header magic")
                self.poke_be(boff + 4, 4, 1 + self.rng.randrange(5), "jbd2 fake type")
                self.poke_be(boff + 8, 4, self.val(4), "jbd2 fake sequence")
            else:
                t = struct.unpack_from(">I", self.d, boff + 4)[0]
                if t == 1:
                    self.poke_be(boff + 12 + 4 * self.rng.randrange(4), 4,
                                 self.val(4), "jbd2 descriptor tag")
                elif t == 2:
                    self.poke_be(boff + 8, 4, self.val(4), "jbd2 commit sequence")
                    self.poke_be(boff + 0x10, 4, self.val(4), "jbd2 commit checksum")
                elif t == 5:
                    self.poke_be(boff + 12, 4, self.val(4), "jbd2 revoke r_count")
                else:
                    self.poke_be(boff + 4, 4, self.rng.randrange(8), "jbd2 block type")
        self.stamp_sb()

    def s_block(self):
        bs = self.L.block_size
        n = len(self.d) // bs
        if n < 2:
            return
        pick = self.rng.randrange(3)
        a, b = self.rng.randrange(n), self.rng.randrange(n)
        if pick == 0 and a != b:
            self.d[b * bs:(b + 1) * bs] = self.d[a * bs:(a + 1) * bs]
            self.edits.append({"off": b * bs, "old": "", "new": "",
                               "what": "copied block %d over %d" % (a, b)})
        elif pick == 1:
            self.d[a * bs:(a + 1) * bs] = b"\x00" * bs
            self.edits.append({"off": a * bs, "old": "", "new": "",
                               "what": "zeroed block %d" % a})
        elif a != b:
            tmp = bytes(self.d[a * bs:(a + 1) * bs])
            self.d[a * bs:(a + 1) * bs] = self.d[b * bs:(b + 1) * bs]
            self.d[b * bs:(b + 1) * bs] = tmp
            self.edits.append({"off": min(a, b) * bs, "old": "", "new": "",
                               "what": "swapped blocks %d and %d" % (a, b)})
        self.stamp_sb()

    def s_raw(self):
        for _ in range(1 + self.rng.randrange(4)):
            off = self.rng.randrange(len(self.d))
            self.poke(off, 1, self.rng.getrandbits(8) , "raw byte")

    # ---------------------------------------------------------------- drive --

    def run(self, target=None):
        table = {"raw": self.s_raw, "superblock": self.s_superblock,
                 "group_desc": self.s_group_desc, "inode": self.s_inode,
                 "extent": self.s_extent, "indirect": self.s_indirect,
                 "dirent": self.s_dirent, "htree": self.s_htree,
                 "xattr": self.s_xattr, "jbd2": self.s_jbd2, "block": self.s_block}
        if target:
            name = target
        else:
            names = list(self.weights)
            name = self.rng.choices(names, [self.weights[n] for n in names])[0]
        # Every structured strategy needs the resolver. An image whose
        # superblock does not parse has no structures to aim at, and a raw
        # edit is exactly the right thing to do to it.
        if name != "raw" and self.L is None:
            name = "raw"
        table[name]()
        return name


def cross_check_resolver(path, L):
    """Two resolvers, one answer. A disagreement is a bug, not a rounding."""
    if Volume is None:
        return None
    try:
        v = Volume(path)
    except SystemExit:
        return None
    if (v.block_size, v.gdt_block, v.desc_size) != \
       (L.block_size, L.gdt_block, L.desc_size):
        return ("bitmap_csum.Volume says block_size=%d gdt_block=%d desc_size=%d; "
                "ext4_csum.Layout says %d/%d/%d"
                % (v.block_size, v.gdt_block, v.desc_size,
                   L.block_size, L.gdt_block, L.desc_size))
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--count", type=int, default=50)
    ap.add_argument("--out", required=True)
    ap.add_argument("--mode", choices=["restamp", "raw"], default="restamp")
    ap.add_argument("--target", help="force one strategy (for the red-first cells)")
    ap.add_argument("--edits", type=int, default=1,
                    help="strategies applied per mutant")
    ap.add_argument("image")
    a = ap.parse_args()

    base = bytearray(open(a.image, "rb").read())
    weights, skip_pct, wpath = load_weights()

    try:
        probe = Layout(bytearray(base))
    except ValueError as e:
        print("mutate_image: %s does not resolve (%s); raw mutation only"
              % (a.image, e))
        probe = None
    if probe is not None:
        problem = cross_check_resolver(a.image, probe)
        if problem:
            print("mutate_image: RESOLVERS DISAGREE: %s" % problem)
            return 2

    os.makedirs(a.out, exist_ok=True)
    counts = {}
    for i in range(a.count):
        rng = random.Random((a.seed << 20) ^ i)
        data = bytearray(base)
        m = Mutator(data, rng, weights, skip_pct, restamp=(a.mode == "restamp"))
        used = [m.run(a.target) for _ in range(a.edits)]
        for u in used:
            counts[u] = counts.get(u, 0) + 1
        name = os.path.join(a.out, "%03d" % i)
        with open(name + ".img", "wb") as f:
            f.write(data)
        with open(name + ".json", "w") as f:
            json.dump({"seed": a.seed, "index": i, "source": a.image,
                       "mode": a.mode, "strategies": used,
                       "edits": m.edits, "restamped": m.restamped}, f, indent=1)

    print("mutate_image: %d mutant(s) from %s, seed %d, mode %s%s"
          % (a.count, os.path.basename(a.image), a.seed, a.mode,
             "" if wpath else " (built-in weights: mutweights.json not found)"))
    print("  " + "  ".join("%s=%d" % (k, counts[k]) for k in sorted(counts)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
