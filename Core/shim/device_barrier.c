/*
 * device_barrier.c — ask the medium to commit what it has been given.
 *
 * Copyright (C) 2026 open_ext4_for_mac contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * A journal is a claim about order: the transaction is on the medium before
 * the commit block that vouches for it, and the commit block is on the medium
 * before the filesystem is changed to match. Neither claim is true by default.
 * A drive is free to hold writes in volatile cache and commit them in whatever
 * order suits its flash translation layer, and it will happily report a write
 * complete while it does.
 *
 * FSKit offers exactly one primitive that would impose the order --
 * `metadataFlush` -- and it fails with EIO for this module, along with the
 * whole metadata I/O family it belongs to. That left the journal issuing
 * barriers into nothing.
 *
 * But FSKit does the I/O from inside the extension's own process, and it holds
 * the medium open to do it: /dev/rdiskN, sitting in our descriptor table.
 * A descriptor is a capability, and the sandbox check happened at open time.
 * So the barrier the API does not expose is reachable through the descriptor
 * the API had to leave lying around.
 *
 * Three calls, most specific first:
 *
 *   DKIOCSYNCHRONIZE with DK_SYNCHRONIZE_OPTION_BARRIER  -- order, no wait
 *   DKIOCSYNCHRONIZECACHE                                -- commit, and wait
 *   F_FULLFSYNC                                          -- for a plain file
 *
 * The first is what a journal actually wants and the last is what works on an
 * image, so all three are worth trying before giving up.
 */

#include <sys/disk.h>
#include <sys/ioctl.h>
#include <fcntl.h>
#include <errno.h>
#include <string.h>
#include <stdint.h>

#include "ext4_bridge.h"

/* Does this descriptor reach a disk at all?
 *
 * A barrier that fails with ENOTTY has two very different explanations. The
 * medium may genuinely not implement it -- an image has no drive underneath,
 * and some USB bridges implement nothing beyond read and write. Or every disk
 * ioctl through this descriptor may be refused, by the sandbox or because the
 * descriptor is not what it appears to be, in which case the barrier was never
 * asked for.
 *
 * DKIOCGETBLOCKSIZE tells them apart. Every disk answers it; nothing has an
 * excuse not to. If it works and the barrier does not, the medium is the
 * answer. If neither works, the descriptor is.
 */
int ext4b_probe_disk_ioctl(int fd, uint32_t *block_size)
{
    if (fd < 0)
        return EBADF;

    uint32_t bs = 0;
    if (ioctl(fd, DKIOCGETBLOCKSIZE, &bs) != 0)
        return errno ? errno : EIO;

    if (block_size)
        *block_size = bs;
    return 0;
}

int ext4b_barrier_fd(int fd)
{
    if (fd < 0)
        return EBADF;

    /*
     * The hot path -- this runs on every journal commit. Stop at the first
     * call that succeeds instead of issuing all three: a real barrier
     * (DKIOCSYNCHRONIZE) is sufficient on its own, and the two fallbacks
     * (a full cache flush, then F_FULLFSYNC) exist only for media that refuse
     * it. Doing all three unconditionally tripled the dominant cost of a
     * commit. The verbose variant still runs the full set, for diagnosis.
     */
    dk_synchronize_t sync;
    memset(&sync, 0, sizeof sync);
    sync.options = DK_SYNCHRONIZE_OPTION_BARRIER;
    if (ioctl(fd, DKIOCSYNCHRONIZE, &sync) == 0)
        return 0;

    if (ioctl(fd, DKIOCSYNCHRONIZECACHE) == 0)
        return 0;

    if (fcntl(fd, F_FULLFSYNC) == 0)
        return 0;

    return errno ? errno : EIO;
}

/* The same three calls, reporting what each one said.
 *
 * Collapsing them to a single errno was actively misleading: the last call
 * tried is F_FULLFSYNC, which answers ENOTTY on a character device for
 * reasons that have nothing to do with whether the drive can be told to
 * commit. Reporting that as the verdict hid a very different errno coming
 * back from the ioctls, and pointed the diagnosis at the medium when it did
 * not belong there. Each result is kept separately now.
 */
int ext4b_barrier_fd_verbose(int fd, ext4b_barrier_report *out)
{
    ext4b_barrier_report r;
    memset(&r, 0, sizeof r);

    if (fd < 0) {
        r.sync_barrier = r.sync_cache = r.fullfsync = EBADF;
        if (out) *out = r;
        return EBADF;
    }

    /* errno ? errno : EIO on each: a failed ioctl that happens to leave errno
     * at 0 must not be recorded as a success. */
    dk_synchronize_t sync;
    memset(&sync, 0, sizeof sync);
    sync.options = DK_SYNCHRONIZE_OPTION_BARRIER;
    r.sync_barrier = ioctl(fd, DKIOCSYNCHRONIZE, &sync) == 0 ? 0 : (errno ? errno : EIO);

    r.sync_cache = ioctl(fd, DKIOCSYNCHRONIZECACHE) == 0 ? 0 : (errno ? errno : EIO);

    r.fullfsync = fcntl(fd, F_FULLFSYNC) == 0 ? 0 : (errno ? errno : EIO);

    if (out) *out = r;

    if (r.sync_barrier == 0 || r.sync_cache == 0 || r.fullfsync == 0)
        return 0;

    /* The most specific call's complaint is the most informative one. */
    return r.sync_barrier ? r.sync_barrier : EIO;
}
