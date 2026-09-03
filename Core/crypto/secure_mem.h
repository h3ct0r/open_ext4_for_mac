/*
 * secure_mem.h — allocations the kernel has been asked not to page out
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * A key schedule lives for as long as a volume is mounted. The anti-forensic
 * split of a master key lives for as long as argon2id takes to run, which is a
 * second or two of deliberately heavy memory traffic -- exactly the conditions
 * under which the kernel goes looking for pages to evict. Anonymous memory
 * that gets evicted is written to a swap file, on a disk, which survives the
 * machine being switched off; the memset_s afterwards does nothing at all for
 * that copy.
 *
 * mlock is the only answer a userspace process has, and it is best-effort:
 * RLIMIT_MEMLOCK is small and a sandboxed extension cannot raise it. When the
 * lock fails the caller carries on -- a container that will not open because
 * the kernel declined to lock a page is worse for the person holding the disk
 * than a key that might reach swap -- and records that it failed, so a test
 * can assert the difference rather than assume it.
 *
 * Page-aligned, because mlock works in whole pages. An allocation that shares
 * a page with something else locks that something else too, and then freeing
 * either one raises the question of who is allowed to unlock the page.
 *
 * -DLUKS_NO_MLOCK=1 skips the lock. It is a test-only define, and the point of
 * it is that `cryptotest` and `Ext4Mac selftest` go red under it: an assertion
 * about a defence is worth nothing if it cannot notice the defence missing.
 */
#ifndef EXT4B_SECURE_MEM_H
#define EXT4B_SECURE_MEM_H

#include <errno.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
/* memset_s: Apple provides it, glibc does not, and crypto_portable.h is where
 * that difference lives. Included here rather than relied on from whichever
 * file happens to include this one first -- patch 0070 is what an unstated
 * include costs on Linux. */
#include "crypto_portable.h"

static inline size_t ext4b_page_size(void)
{
    long p = sysconf(_SC_PAGESIZE);
    return (p > 0) ? (size_t)p : 4096;
}

/*
 * Allocate `len` bytes, zeroed, page-aligned, and locked if the kernel allows.
 *
 * `*alloc_out` receives the rounded size -- the caller must pass that same
 * value back to ext4b_secure_free, because it is what was locked and what has
 * to be wiped. `*locked_out` receives whether the lock took.
 */
/* Why the last ext4b_secure_alloc did not lock, or 0 if it did (or never
 * tried). One value per process is enough: it exists so a test can tell "the
 * code did not ask" from "the code asked and this machine said no", and
 * those need different responses -- the first is a regression, the second is
 * a RLIMIT_MEMLOCK the runner or the sandbox set, which the caller has
 * already decided to live with. */
/* Defined once, in aes_xts.c. A `static` inside a static inline function is
 * a separate object in every translation unit that includes this header, and
 * the first version of this was exactly that: cryptotest read its own copy,
 * which nothing had written, and reported "errno 0" for a refused lock. */
extern int ext4b_secure_lock_errno;
static inline int *ext4b_secure_lock_errno_slot(void) { return &ext4b_secure_lock_errno; }

/* Does this build ask the kernel to lock at all? False only under the
 * test-only LUKS_NO_MLOCK define. */
static inline bool ext4b_secure_lock_attempted(void)
{
#ifdef LUKS_NO_MLOCK
    return false;
#else
    return true;
#endif
}

static inline void *ext4b_secure_alloc(size_t len, size_t *alloc_out, bool *locked_out)
{
    size_t page = ext4b_page_size();
    size_t rounded = ((len + page - 1) / page) * page;
    if (rounded == 0)
        rounded = page;

    void *p = NULL;
    if (posix_memalign(&p, page, rounded) != 0 || !p)
        return NULL;
    memset(p, 0, rounded);

    bool locked = false;
#ifndef LUKS_NO_MLOCK
    locked = (mlock(p, rounded) == 0);
    *ext4b_secure_lock_errno_slot() = locked ? 0 : errno;
#endif
    if (alloc_out)  *alloc_out = rounded;
    if (locked_out) *locked_out = locked;
    return p;
}

/* Wipe, unlock, free -- in that order. memset_s rather than memset, because a
 * compiler is entitled to delete a plain memset of memory about to be freed,
 * which is precisely the case where it matters. */
static inline void ext4b_secure_free(void *p, size_t alloc_len, bool locked)
{
    if (!p)
        return;
    memset_s(p, alloc_len, 0, alloc_len);
    if (locked)
        (void)munlock(p, alloc_len);
    free(p);
}

#endif /* EXT4B_SECURE_MEM_H */
