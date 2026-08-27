/*
 * ext4_check.c — a structural check of a mounted volume.
 *
 * Copyright (C) 2026 open_ext4_for_mac contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * This is not e2fsck and does not try to be. It repairs nothing, and it cannot
 * see anything the filesystem's own read path cannot: it walks the directory
 * tree through the same calls a `find` would use, and checks the answers
 * against each other.
 *
 * That sounds weak and turns out not to be, because it is exactly the class of
 * damage this driver has actually produced. Every failure the kill-recovery
 * suite reported against real hardware was one of these:
 *
 *     Inode 2 ref count is 12, should be 13
 *     Entry 'k30922-r1' in / (2) has an incorrect filetype
 *     Entry '.fseventsd' in / (2) has deleted/unused inode 13
 *     Unattached inode 320
 *
 * Link counts that do not match the tree, entries pointing at inodes that are
 * not there, and entries whose recorded type disagrees with the inode. All
 * three are visible from a walk, and until now `startCheck` reported none of
 * them -- it decided only whether the volume was mountable, and a volume in
 * every one of those states mounts perfectly well.
 *
 * What it still cannot see: blocks claimed by two inodes, free counts that
 * disagree with the bitmaps, orphaned inodes with no directory entry at all.
 * Those need the allocation metadata rather than the tree, and `e2fsck` is
 * the right tool. The report says so rather than implying a clean bill of
 * health.
 */

#include "ext4_bridge.h"

#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <stdarg.h>
#include <errno.h>

/* Directories still to descend into. Explicit rather than recursive: a
 * directory tree's depth is attacker-controlled on a volume from elsewhere,
 * and blowing the stack inside a filesystem driver is a poor way to report
 * that a filesystem is corrupt. */
typedef struct {
    uint32_t *items;
    size_t    count;
    size_t    cap;
} inode_stack;

static bool stack_push(inode_stack *s, uint32_t ino)
{
    if (s->count == s->cap) {
        size_t cap = s->cap ? s->cap * 2 : 256;
        uint32_t *p = realloc(s->items, cap * sizeof *p);
        if (!p)
            return false;
        s->items = p;
        s->cap = cap;
    }
    s->items[s->count++] = ino;
    return true;
}

/* One bit per inode, so a hard-linked file is counted once and a directory
 * loop terminates instead of running forever. */
typedef struct {
    uint8_t *bits;
    uint32_t count;
} inode_set;

static bool seen(inode_set *s, uint32_t ino)
{
    if (ino == 0 || ino > s->count)
        return true;                     /* out of range: not ours to walk */
    return (s->bits[(ino - 1) / 8] >> ((ino - 1) % 8)) & 1;
}

static void mark(inode_set *s, uint32_t ino)
{
    if (ino == 0 || ino > s->count)
        return;
    s->bits[(ino - 1) / 8] |= (uint8_t)(1u << ((ino - 1) % 8));
}

/* What one directory's enumeration collects. */
typedef struct {
    ext4b_device       *dev;
    ext4b_check_result *out;
    inode_stack        *stack;
    inode_set          *visited;
    uint32_t            dir_inode;
    uint32_t            subdirs;      /* excluding . and ..                */
    bool                out_of_memory;
} walk_ctx;

static void problem(ext4b_check_result *out, const char *fmt, ...)
{
    out->problems++;
    if (out->first_problem[0] != '\0')
        return;

    va_list ap;
    va_start(ap, fmt);
    vsnprintf(out->first_problem, sizeof out->first_problem, fmt, ap);
    va_end(ap);
}

static bool on_entry(void *ctx,
                     const char *name, size_t name_len,
                     uint32_t inode,
                     ext4b_item_type type,
                     uint64_t next_cookie)
{
    (void)next_cookie;
    walk_ctx *w = ctx;

    /* "." and ".." are the directory's own link count, not children. */
    if ((name_len == 1 && name[0] == '.') ||
        (name_len == 2 && name[0] == '.' && name[1] == '.'))
        return true;

    char shown[64];
    size_t n = name_len < sizeof shown - 1 ? name_len : sizeof shown - 1;
    memcpy(shown, name, n);
    shown[n] = '\0';

    if (inode == 0) {
        problem(w->out, "entry '%s' in inode %u points at inode 0",
                shown, w->dir_inode);
        return true;
    }

    /* Does the inode the entry names actually exist? A deleted-but-still-named
     * inode is what a torn unlink leaves, and e2fsck calls it
     * "has deleted/unused inode". */
    ext4b_attrs a;
    int r = ext4b_getattr(w->dev, inode, &a);
    if (r != 0) {
        problem(w->out, "entry '%s' in inode %u names inode %u, which cannot "
                        "be read (%s)",
                shown, w->dir_inode, inode, ext4b_strerror(r));
        return true;
    }
    if (a.link_count == 0) {
        problem(w->out, "entry '%s' in inode %u names inode %u, which has no "
                        "links", shown, w->dir_inode, inode);
        return true;
    }

    /* The directory entry caches the type; the inode is authoritative. They
     * disagree when a directory block was written and its inode was not. */
    if (type != EXT4B_TYPE_UNKNOWN && type != a.type) {
        problem(w->out, "entry '%s' in inode %u says type %d, inode %u says %d",
                shown, w->dir_inode, (int)type, inode, (int)a.type);
    }

    if (a.type == EXT4B_TYPE_DIR) {
        w->subdirs++;
        /* A directory reached twice is a loop, or a second hard link to a
         * directory, which ext4 does not allow. Either way, do not descend. */
        if (seen(w->visited, inode)) {
            problem(w->out, "directory inode %u is reachable more than once",
                    inode);
        } else {
            mark(w->visited, inode);
            if (!stack_push(w->stack, inode))
                w->out_of_memory = true;
        }
        w->out->directories++;
    } else {
        w->out->files++;
    }
    return true;
}

int ext4b_check_tree(ext4b_device *dev, ext4b_check_result *out)
{
    if (!dev || !out)
        return EINVAL;

    memset(out, 0, sizeof *out);

    ext4b_statfs_info sfs;
    if (ext4b_statfs(dev, &sfs) != 0)
        return EIO;

    inode_set visited = { 0 };
    visited.count = (uint32_t)sfs.total_inodes;
    if (visited.count == 0)
        return EIO;
    visited.bits = calloc((visited.count + 7) / 8, 1);
    if (!visited.bits)
        return ENOMEM;

    inode_stack stack = { 0 };
    int rc = 0;

    mark(&visited, EXT4B_ROOT_INO);
    if (!stack_push(&stack, EXT4B_ROOT_INO)) {
        rc = ENOMEM;
        goto done;
    }
    out->directories++;                  /* the root itself */

    while (stack.count > 0) {
        uint32_t dir = stack.items[--stack.count];

        ext4b_attrs da;
        int r = ext4b_getattr(dev, dir, &da);
        if (r != 0) {
            problem(out, "directory inode %u cannot be read (%s)",
                    dir, ext4b_strerror(r));
            continue;
        }

        walk_ctx w = {
            .dev = dev, .out = out, .stack = &stack,
            .visited = &visited, .dir_inode = dir,
        };

        r = ext4b_readdir(dev, dir, 0, on_entry, &w);
        if (r != 0) {
            problem(out, "directory inode %u cannot be read through (%s)",
                    dir, ext4b_strerror(r));
            continue;
        }
        if (w.out_of_memory) {
            rc = ENOMEM;
            goto done;
        }

        /*
         * A directory's link count is "." plus its parent's entry for it plus
         * one per subdirectory's "..". This is the check that catches what the
         * kill tests kept reporting -- "Inode 2 ref count is 12, should be 13"
         * is precisely this sum disagreeing.
         *
         * Inodes with more than 65000 links stop counting: ext4 parks the
         * count at 1 and sets a feature bit rather than overflowing, so a
         * directory that has been there is not comparable.
         */
        uint32_t expected = w.subdirs + 2;
        if (da.link_count != expected && da.link_count > 1) {
            problem(out, "directory inode %u has link count %u, tree says %u",
                    dir, da.link_count, expected);
        }
    }

done:
    free(visited.bits);
    free(stack.items);
    return rc;
}
