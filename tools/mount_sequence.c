/*
 * Volumes in sequence, one process: does each start clean?
 *
 *   build/bin/mount_sequence
 *
 * The extension is one process that can mount one volume after another, and
 * lwext4 keeps its mount point in a global slot that the next mount reuses.
 * ext4_fs_init sets the fields it knows about and left the rest, so a volume
 * inherited the previous volume's inode-allocator starting group -- and on a
 * volume with fewer block groups than that, every inode allocation failed
 * ENOSPC. An empty stick, mounted after a big one, could not take one file.
 *
 * So: A (64 MiB, 1 KiB blocks, 8 groups, 16 inodes per group) takes sixty
 * files, which walks the inode allocator well past group 1; B (2 MiB, one
 * group), freshly formatted, must then take one. Between the two, lwext4's
 * global tables must be empty -- no device, no mount point, nothing left in
 * an unmounted slot.
 *
 * The device is state too. C is formatted, mounted, written, unmounted and
 * mounted again through ONE device object, which ext4b_format's contract --
 * the volume left "consistent and unmounted" -- promises is fine. lwext4's
 * mkfs bound a block cache from its own stack frame to that device and
 * returned without unbinding it, so the mount after it walked a cache that
 * no longer existed (lwext4 0084). The extension never met it because its
 * format path closes the device it formatted through, and A and B do the
 * same.
 *
 * In-memory images, no fixtures, no Homebrew. Links the test core for the
 * table accounting. Prints ok/FAIL lines; exits 0 only when all pass.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "ext4_bridge.h"

typedef struct { uint8_t *base; size_t len; } memdev;

static int mem_read(void *c, void *b, uint64_t off, size_t n)
{
    memdev *m = c;
    if (off > m->len || n > m->len - off) return -1;
    memcpy(b, m->base + off, n);
    return 0;
}

static int mem_write(void *c, const void *b, uint64_t off, size_t n)
{
    memdev *m = c;
    if (off > m->len || n > m->len - off) return -1;
    memcpy(m->base + off, b, n);
    return 0;
}

static int mem_flush(void *c) { (void)c; return 0; }

/* A pointer into a stack frame that has returned reads whatever ran there
 * since, so the symptom depends on the code around it: here the release
 * build faults on C's mount and ASan's default mode reports an overflow in
 * main's frame, while a smaller program making the same calls passed under
 * ASan without a word. This has ASan name the read for what it is every
 * time -- a stack-use-after-return into ext4_mkfs's frame -- from the binary
 * itself, not an ASAN_OPTIONS a caller might not set. Builds without ASan
 * never call it. */
const char *__asan_default_options(void)
{
    return "detect_stack_use_after_return=1";
}

static int failures;

static void check(int cond, const char *what, const char *detail)
{
    if (cond) {
        printf("  ok    %s\n", what);
    } else {
        printf("  FAIL  %s\n        %s\n", what, detail);
        failures++;
    }
}

static ext4b_device *attach(memdev *m)
{
    return ext4b_device_create(m, 512, m->len / 512, false,
                               mem_read, mem_write, mem_flush);
}

/* A fresh in-memory volume, formatted; returns the device the format went
 * through. */
static ext4b_device *format_volume(memdev *m, size_t bytes, uint32_t inodes,
                                   uint8_t uuid_seed)
{
    m->len = bytes;
    m->base = calloc(1, bytes);
    if (!m->base) { perror("calloc"); exit(2); }

    ext4b_format_options o;
    memset(&o, 0, sizeof o);
    o.generation  = 4;
    o.block_size  = 1024;
    o.inode_count = inodes;
    o.journal     = true;
    for (int i = 0; i < 16; i++) o.uuid[i] = (uint8_t)(uuid_seed + i);

    ext4b_device *d = attach(m);
    if (!d || ext4b_format(d, &o) != 0) { fprintf(stderr, "format failed\n"); exit(2); }
    return d;
}

/* Format through one device and mount through another, as the extension
 * does: its format path closes the device it formatted through. */
static ext4b_device *make_volume(memdev *m, size_t bytes, uint32_t inodes,
                                 uint8_t uuid_seed)
{
    ext4b_device_destroy(format_volume(m, bytes, inodes, uuid_seed));
    return attach(m);
}

static void require_clean_tables(const char *when)
{
    size_t devices = 0, mounted = 0, residue = 0;
    char what[128], detail[160];
    ext4b_lwext4_slots(&devices, &mounted, &residue);
    snprintf(what, sizeof what, "lwext4's global tables are empty %s", when);
    snprintf(detail, sizeof detail,
             "%zu device(s) registered, %zu mount point(s) mounted, "
             "%zu unmounted slot(s) holding state", devices, mounted, residue);
    check(devices == 0 && mounted == 0 && residue == 0, what, detail);
}

int main(void)
{
    char detail[160];
    memdev a, b, c;

    /* A crash is one of the outcomes here, and a pipe's buffer dies with the
     * process: line-buffer, so the suite sees how far it got. */
    setvbuf(stdout, NULL, _IOLBF, 0);

    printf("two volumes, one process\n");

    ext4b_device *da = make_volume(&a, 64u << 20, 8 * 16, 0x10);
    int r = ext4b_mount(da, false);
    snprintf(detail, sizeof detail, "ext4b_mount returned %d", r);
    check(r == 0, "the big volume mounts read-write", detail);

    int made = 0, last = 0;
    for (int i = 0; i < 60; i++) {
        char name[16];
        uint32_t ino = 0;
        snprintf(name, sizeof name, "f%02d", i);
        last = ext4b_create(da, 2, name, strlen(name), EXT4B_TYPE_FILE,
                            0644, 0, 0, &ino);
        if (last == 0) made++;
    }
    snprintf(detail, sizeof detail, "%d of 60 created; last rc %d", made, last);
    check(made == 60, "it takes sixty files, past its first groups", detail);

    r = ext4b_unmount(da);
    snprintf(detail, sizeof detail, "ext4b_unmount returned %d", r);
    check(r == 0, "and unmounts", detail);
    ext4b_device_destroy(da);
    free(a.base);
    require_clean_tables("after it");

    ext4b_device *db = make_volume(&b, 2u << 20, 0, 0x20);
    r = ext4b_mount(db, false);
    snprintf(detail, sizeof detail, "ext4b_mount returned %d", r);
    check(r == 0, "a fresh one-group volume mounts next, same process", detail);

    uint32_t ino = 0;
    r = ext4b_create(db, 2, "x", 1, EXT4B_TYPE_FILE, 0644, 0, 0, &ino);
    snprintf(detail, sizeof detail,
             "ext4b_create returned %d (28 is ENOSPC: the allocator started in "
             "a group this volume does not have)", r);
    check(r == 0 && ino != 0, "and takes a file", detail);

    r = ext4b_unmount(db);
    snprintf(detail, sizeof detail, "ext4b_unmount returned %d", r);
    check(r == 0, "and unmounts", detail);
    ext4b_device_destroy(db);
    free(b.base);
    require_clean_tables("after the second");

    printf("\none device, formatted and then mounted\n");

    ext4b_device *dc = format_volume(&c, 8u << 20, 0, 0x30);
    r = ext4b_mount(dc, false);
    snprintf(detail, sizeof detail, "ext4b_mount returned %d", r);
    check(r == 0, "the device a volume was formatted through mounts it read-write",
          detail);

    uint32_t made_ino = 0;
    r = ext4b_create(dc, 2, "y", 1, EXT4B_TYPE_FILE, 0644, 0, 0, &made_ino);
    snprintf(detail, sizeof detail, "ext4b_create returned %d", r);
    check(r == 0 && made_ino != 0, "and takes a file", detail);

    r = ext4b_unmount(dc);
    snprintf(detail, sizeof detail, "ext4b_unmount returned %d", r);
    check(r == 0, "and unmounts", detail);

    r = ext4b_mount(dc, false);
    snprintf(detail, sizeof detail, "ext4b_mount returned %d", r);
    check(r == 0, "and mounts again, still through the same device", detail);

    uint32_t found = 0;
    ext4b_item_type type;
    r = ext4b_lookup(dc, 2, "y", 1, &found, &type);
    snprintf(detail, sizeof detail, "ext4b_lookup returned %d, inode %u; "
             "the create gave inode %u", r, found, made_ino);
    check(r == 0 && found == made_ino, "with the file still in it", detail);

    r = ext4b_unmount(dc);
    snprintf(detail, sizeof detail, "ext4b_unmount returned %d", r);
    check(r == 0, "and unmounts", detail);
    ext4b_device_destroy(dc);
    free(c.base);
    require_clean_tables("after the third");

    printf("\n%s\n", failures ? "FAILED" : "passed");
    return failures ? 1 : 0;
}
