/*
 * ext4barrierd.c — issue a write barrier on behalf of the sandboxed extension.
 *
 * Copyright (C) 2026 open_ext4_for_mac contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * A journal is a claim about order, and nothing in the driver could enforce
 * it. FSKit's metadataFlush, the one write barrier in the whole FSResource
 * API, fails with EIO for this module. The device-level barrier underneath it,
 * DKIOCSYNCHRONIZECACHE, is refused by the App Sandbox -- by name, in the
 * kernel's own words:
 *
 *     Sandbox: Ext4FS deny(1) file-ioctl path:/dev/rdiskN
 *              ioctl-command:(_IO "d" 22)
 *
 * There is no entitlement that lifts that. A file-path exception grants
 * file-read and file-write, not file-ioctl; both it and the IOKit user-client
 * exception Apple's own msdos module carries were tried, and the denial came
 * back byte for byte identical. What is left is to have the ioctl issued
 * somewhere the sandbox does not reach.
 *
 * That is all this is. It is deliberately the smallest privileged thing that
 * can close the gap:
 *
 *   - It knows exactly one verb: synchronize the cache on a disk. It never
 *     reads a byte, never writes a byte, and issues no other ioctl.
 *   - It accepts a BSD disk name, not a path -- diskN or diskNsM and nothing
 *     else, so there is no path to traverse and nothing else to name.
 *   - It answers only callers whose code signature it has checked against a
 *     requirement naming this project's team and the extension's identifier.
 *
 * The worst a subverted caller can do with it is make disks flush caches they
 * were going to flush anyway. That bound is the point: a root daemon earns its
 * keep by being boring, and this one has no interesting capability to steal.
 *
 * Why a writable descriptor: the flush is a write operation, and xnu refuses
 * it on a read-only one. Opening O_WRONLY is measured, not incidental --
 * O_RDONLY returns EACCES for the barrier while answering DKIOCGETBLOCKSIZE
 * perfectly happily, which is a confusing thing to debug from the far side of
 * an XPC call.
 */

#include <xpc/xpc.h>
#include <dispatch/dispatch.h>
#include <Security/Security.h>
#include <sys/disk.h>
#include <sys/ioctl.h>
#include <bsm/audit.h>
#include <fcntl.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <stdbool.h>
#include <os/log.h>

#define SERVICE_NAME "dev.h3ct0r.ext4mac.barrier"

/* Where install-barrier puts this binary. Only used to tell the user which
 * file to hand Full Disk Access to, which is the one thing they must do by
 * hand and the one thing no error message otherwise mentions. */
#define BARRIER_PROGRAM_PATH "/Library/PrivilegedHelperTools/ext4barrierd"

/* Who may ask. The team is this project's; the identifier is the FSKit
 * extension's. Nothing else on the machine matches, including the container
 * app, which has no reason to want a barrier. */
#define CALLER_REQUIREMENT \
    "anchor apple generic" \
    " and certificate leaf[subject.OU] = \"BDLYXW7QMN\"" \
    " and identifier \"dev.h3ct0r.ext4mac.Ext4FS\""

/* Not public API, but it is the only way to identify a peer without a race:
 * xpc_connection_get_pid answers a question whose answer can change before it
 * is used, and a PID that has been recycled is exactly the case that matters. */
extern void xpc_connection_get_audit_token(xpc_connection_t, audit_token_t *);

static os_log_t log_handle;

/* ------------------------------------------------------------- device names */

/*
 * `diskN`, or `diskNsM`, and nothing else.
 *
 * Written out rather than done with a regex because this is the whole security
 * boundary on what a caller can name. No leading slash, no dots, no length the
 * buffer below cannot hold -- so the path built from it cannot escape /dev,
 * and cannot name anything that is not a disk.
 */
static bool valid_bsd_name(const char *s)
{
    size_t n = strlen(s);
    if (n < 5 || n > 24)
        return false;
    if (strncmp(s, "disk", 4) != 0)
        return false;

    size_t i = 4;
    size_t digits = 0;
    while (i < n && s[i] >= '0' && s[i] <= '9') { i++; digits++; }
    if (digits == 0)
        return false;
    if (i == n)
        return true;              /* diskN */

    if (s[i] != 's')
        return false;
    i++;
    digits = 0;
    while (i < n && s[i] >= '0' && s[i] <= '9') { i++; digits++; }
    return digits > 0 && i == n;  /* diskNsM */
}

/* ------------------------------------------------------------- descriptors */

/*
 * One open descriptor per device, kept for the life of the daemon.
 *
 * Reopening per request would put an open() and a close() on the path of every
 * journal commit, and open() on a busy disk device is not free. The cache is
 * small and fixed: a machine does not have many disks, and a fixed array with
 * no eviction cannot be made to grow by a caller naming devices in a loop.
 */
#define MAX_DEVICES 12

static struct {
    char name[25];
    int  fd;
} devices[MAX_DEVICES];

static size_t device_count;
static dispatch_queue_t device_queue;

static int synchronize(int fd);

/* Reduce a partition name to its whole disk: disk8s1 -> disk8. A no-op for a
 * name that is already a whole disk. The cache flush is a property of the
 * drive, so the whole-disk node is what we key on and open -- and keying on it
 * means the two partitions of one disk share a single entry and a single
 * descriptor, instead of consuming two slots and holding two fds on the same
 * node (which is what forget then failed to fully release). */
static void whole_disk_of(const char *name, char *out, size_t out_len)
{
    strlcpy(out, name, out_len);
    char *suffix = strrchr(out, 's');
    if (suffix && suffix != out && suffix[-1] >= '0' && suffix[-1] <= '9')
        *suffix = '\0';
}

/* Must run on device_queue. */
static int descriptor_for(const char *name)
{
    char whole[sizeof devices[0].name];
    whole_disk_of(name, whole, sizeof whole);

    for (size_t i = 0; i < device_count; i++)
        if (strcmp(devices[i].name, whole) == 0)
            return devices[i].fd;

    if (device_count == MAX_DEVICES)
        return -1;

    char path[40];
    snprintf(path, sizeof path, "/dev/r%s", whole);

    /*
     * Try each mode, and prove the barrier works before keeping the
     * descriptor. Which mode is allowed depends on what the device is doing,
     * and it is not the rule you would guess:
     *
     *   idle       O_WRONLY and O_RDWR open and flush; O_RDONLY opens but is
     *              refused the flush with EACCES, because a cache flush is a
     *              write operation.
     *   mounted    the partition node opens and flushes in *all three* modes,
     *              while the whole-disk node refuses the writable opens with
     *              EBUSY and grants the flush read-only.
     *
     * So the read-only descriptor, useless when the disk is idle, is the one
     * that works when a volume is live -- which is the only time a journal
     * asks for a barrier. Guessing a single mode gets this wrong half the
     * time, and the failure is silent: writes keep working, ordering just is
     * not enforced.
     *
     * Read-only comes first, and that order is about safety rather than
     * speed. A barrier is only ever wanted while a volume is live, which is
     * exactly when the read-only descriptor works -- so the writable modes are
     * the fallback for an idle disk, not the common path. Opening a mounted
     * device O_WRONLY from a second process is a good way to wedge it: the
     * first version of this did that, and the stick stopped answering reads
     * partway through a run three times.
     */
    static const int modes[] = { O_RDONLY, O_WRONLY, O_RDWR };
    int last_errno = 0;

    for (size_t m = 0; m < sizeof modes / sizeof modes[0]; m++) {
        int fd = open(path, modes[m]);
        if (fd < 0) { last_errno = errno; continue; }

        int rc = synchronize(fd);
        if (rc == 0) {
            strlcpy(devices[device_count].name, whole, sizeof devices[0].name);
            devices[device_count].fd = fd;
            device_count++;
            os_log(log_handle, "opened %{public}s for barriers (mode %d)",
                   path, modes[m]);
            return fd;
        }

        /* Opened but cannot flush: a descriptor that answers every request
         * with EACCES is worse than none, because it looks like a barrier. */
        last_errno = rc;
        close(fd);
    }

    /*
     * EPERM here is almost always TCC, not a permission bit.
     *
     * Being root is not enough to open a removable volume's device node: that
     * is gated by kTCCServiceSystemPolicyRemovableVolumes, and a daemon has no
     * UI, so it is never prompted -- it is simply denied, with an errno that
     * says nothing about privacy. The same open from a terminal under sudo
     * succeeds, because it inherits the terminal's grants, which is a very
     * effective way to convince yourself the daemon's code is at fault.
     *
     * The fix is to add this binary to Full Disk Access. Say so here, because
     * the log is the only place anyone will look.
     */
    if (last_errno == EPERM) {
        os_log_error(log_handle,
                     "no barrier on %{public}s: denied. Being root is not "
                     "enough for removable media -- add %{public}s to "
                     "System Settings > Privacy & Security > Full Disk Access",
                     path, BARRIER_PROGRAM_PATH);
    } else {
        os_log_error(log_handle, "no usable barrier on %{public}s: %{public}s",
                     path, strerror(last_errno ? last_errno : EIO));
    }
    return -1;
}


/* Drop a descriptor whose device has gone: a stick pulled while mounted leaves
 * one behind that will fail every barrier from then on, and the next mount of
 * a device that reuses the name would inherit the failure. */
static void forget_descriptor(const char *name)
{
    char whole[sizeof devices[0].name];
    whole_disk_of(name, whole, sizeof whole);
    for (size_t i = 0; i < device_count; i++) {
        if (strcmp(devices[i].name, whole) != 0)
            continue;
        close(devices[i].fd);
        devices[i] = devices[device_count - 1];
        device_count--;
        os_log(log_handle, "released %{public}s", whole);
        return;
    }
}

/*
 * The barrier itself. Ordered-without-waiting first, since that is what a
 * journal actually needs and it is much cheaper than a full flush; then the
 * full synchronize; then the older spelling for anything that only knows that.
 */
static int synchronize(int fd)
{
    dk_synchronize_t sync;

    memset(&sync, 0, sizeof sync);
    sync.options = DK_SYNCHRONIZE_OPTION_BARRIER;
    if (ioctl(fd, DKIOCSYNCHRONIZE, &sync) == 0)
        return 0;

    memset(&sync, 0, sizeof sync);
    if (ioctl(fd, DKIOCSYNCHRONIZE, &sync) == 0)
        return 0;

    if (ioctl(fd, DKIOCSYNCHRONIZECACHE) == 0)
        return 0;

    return errno ? errno : EIO;
}

/* ------------------------------------------------------------ authorisation */

/*
 * The two validation stages, shared by the trust boundary and --selfcheck.
 *
 * They are separate because the API insists: SecCodeCheckValidity judges a
 * *live* process and accepts only the default flags. Handing it the static
 * flags below returns errSecCSInvalidFlags (-67070) -- refusing every caller
 * while looking exactly like a signature mismatch in the log. That shipped
 * once, and only a physical USB stick surfaced it, because disk images are
 * exempt from the barrier and no image-backed test ever asks. --selfcheck
 * exists so it cannot ship twice.
 *
 * The strict flags still run where they are legal: on the static code behind
 * the process, where kSecCSStrictValidate rejects signatures the default
 * flags tolerate and kSecCSCheckAllArchitectures covers every slice of a fat
 * binary rather than the one that happens to be running.
 */
static OSStatus dynamic_ok(SecCodeRef code, SecRequirementRef req)
{
    return SecCodeCheckValidity(code, kSecCSDefaultFlags, req);
}

static OSStatus static_ok(SecCodeRef code, SecRequirementRef req)
{
    SecStaticCodeRef disk = NULL;
    OSStatus rc = SecCodeCopyStaticCode(code, kSecCSDefaultFlags, &disk);
    if (rc != errSecSuccess || !disk)
        return rc != errSecSuccess ? rc : errSecCSInternalError;
    rc = SecStaticCodeCheckValidity(disk,
                                    kSecCSDefaultFlags
                                    | kSecCSStrictValidate
                                    | kSecCSCheckAllArchitectures,
                                    req);
    CFRelease(disk);
    return rc;
}

static bool peer_is_trusted(xpc_connection_t peer)
{
    audit_token_t token;
    xpc_connection_get_audit_token(peer, &token);

    CFDataRef token_data = CFDataCreate(NULL, (const UInt8 *)&token, sizeof token);
    if (!token_data)
        return false;

    const void *keys[]   = { kSecGuestAttributeAudit };
    const void *values[] = { token_data };
    CFDictionaryRef attrs = CFDictionaryCreate(NULL, keys, values, 1,
                                               &kCFTypeDictionaryKeyCallBacks,
                                               &kCFTypeDictionaryValueCallBacks);
    CFRelease(token_data);
    if (!attrs)
        return false;

    SecCodeRef code = NULL;
    OSStatus rc = SecCodeCopyGuestWithAttributes(NULL, attrs, kSecCSDefaultFlags, &code);
    CFRelease(attrs);
    if (rc != errSecSuccess || !code) {
        os_log_error(log_handle, "cannot identify caller: %d", (int)rc);
        return false;
    }

    SecRequirementRef requirement = NULL;
    CFStringRef text = CFStringCreateWithCString(NULL, CALLER_REQUIREMENT,
                                                 kCFStringEncodingUTF8);
    rc = SecRequirementCreateWithString(text, kSecCSDefaultFlags, &requirement);
    CFRelease(text);
    if (rc != errSecSuccess || !requirement) {
        CFRelease(code);
        return false;
    }

    /* Both stages: the live process must satisfy the requirement, and so
     * must every architecture of the binary behind it, strictly validated.
     * This is the whole trust boundary for a root daemon, so it pays the
     * stricter check -- in the one place the API permits it. */
    rc = dynamic_ok(code, requirement);
    if (rc == errSecSuccess)
        rc = static_ok(code, requirement);
    CFRelease(requirement);
    CFRelease(code);

    if (rc != errSecSuccess) {
        os_log_error(log_handle, "refusing caller: signature does not match (%d)",
                     (int)rc);
        return false;
    }
    return true;
}

/* ----------------------------------------------------------------- requests */

static void handle_message(xpc_connection_t peer, xpc_object_t message)
{
    if (xpc_get_type(message) != XPC_TYPE_DICTIONARY)
        return;

    const char *name = xpc_dictionary_get_string(message, "device");
    bool release = xpc_dictionary_get_bool(message, "release");

    xpc_object_t reply = xpc_dictionary_create_reply(message);
    if (!reply)
        return;

    if (!name || !valid_bsd_name(name)) {
        os_log_error(log_handle, "refusing a request naming %{public}s",
                     name ? name : "(nothing)");
        xpc_dictionary_set_int64(reply, "status", EINVAL);
        xpc_connection_send_message(peer, reply);
        xpc_release(reply);
        return;
    }

    /* Serialised: the descriptor table is shared, and the ioctl itself is
     * cheap enough that a queue per device would buy nothing. */
    dispatch_sync(device_queue, ^{
        int status;
        if (release) {
            forget_descriptor(name);
            status = 0;
        } else {
            int fd = descriptor_for(name);
            status = fd < 0 ? EACCES : synchronize(fd);
            /* A barrier that fails because the device went away should not
             * poison every later one through a stale descriptor. */
            if (status == ENXIO || status == EIO || status == EBADF)
                forget_descriptor(name);
        }
        xpc_dictionary_set_int64(reply, "status", status);
    });

    xpc_connection_send_message(peer, reply);
    xpc_release(reply);
}

static void handle_connection(xpc_connection_t peer)
{
    if (!peer_is_trusted(peer)) {
        xpc_connection_cancel(peer);
        return;
    }

    /*
     * Track what this client had open, and let go of it when the client does.
     *
     * Holding a writable descriptor on a disk after the process that wanted it
     * has gone is not a leak, it is a wedge: the next thing to write to that
     * device -- a reformat, another mount -- blocks in uninterruptible I/O
     * against a descriptor whose owner no longer exists, and no signal clears
     * it. An extension that is killed rather than unmounted never sends a
     * release, and being killed is exactly the case this daemon exists for.
     */
    /* The set of whole disks this client has opened, so teardown can release
     * every one -- not just the last. A single char* leaked all but the most
     * recent when a client named more than one device. Keyed by whole disk
     * (disk8s1 and disk8s2 collapse to disk8), so the small fixed set is more
     * than enough: one client is one extension serving one volume. On the heap
     * behind a __block pointer, because a block cannot reference a __block
     * array directly. */
    struct owned_set {
        size_t count;
        char   names[MAX_DEVICES][sizeof devices[0].name];
    };
    __block struct owned_set *owned = calloc(1, sizeof *owned);
    if (!owned) { xpc_connection_cancel(peer); return; }

    xpc_connection_set_event_handler(peer, ^(xpc_object_t event) {
        if (xpc_get_type(event) == XPC_TYPE_ERROR) {
            for (size_t i = 0; i < owned->count; i++) {
                /* A block can capture a char* but not a C array, so pass a
                 * heap copy; dispatch_sync is synchronous, so freeing right
                 * after is safe. */
                char *wp = strdup(owned->names[i]);
                if (!wp) continue;
                dispatch_sync(device_queue, ^{ forget_descriptor(wp); });
                free(wp);
            }
            free(owned);
            owned = NULL;
            return;
        }
        if (!owned) return;

        const char *device = xpc_dictionary_get_string(event, "device");
        if (device && valid_bsd_name(device)) {
            char whole[sizeof devices[0].name];
            whole_disk_of(device, whole, sizeof whole);
            bool known = false;
            for (size_t i = 0; i < owned->count; i++)
                if (strcmp(owned->names[i], whole) == 0) { known = true; break; }
            if (!known && owned->count < MAX_DEVICES)
                strlcpy(owned->names[owned->count++], whole, sizeof devices[0].name);
        }

        handle_message(peer, event);
    });
    xpc_connection_resume(peer);
}

/* ---------------------------------------------------------------- selfcheck */

static int expect(const char *what, OSStatus got, OSStatus want)
{
    if (got == want) {
        printf("  ok    %s (%d)\n", what, (int)got);
        return 0;
    }
    printf("  FAIL  %s: got %d, wanted %d%s\n", what, (int)got, (int)want,
           got == errSecCSInvalidFlags
               ? " -- invalid API flags: the daemon would refuse every caller"
               : "");
    return 1;
}

/*
 * Prove the validation calls are legal API before they guard anything.
 *
 * Runs the exact production stages twice: against this binary's own
 * designated requirement, which must pass -- exercising both flag sets end
 * to end -- and against the extension requirement, which must fail with
 * errSecCSReqFailed, the healthy refusal. Any other outcome, -67070 above
 * all, means the check itself is broken, and broken in the direction that
 * silently disables the barrier on every removable mount.
 *
 * Needs the signed binary; an unsigned build has no designated requirement.
 */
static int selfcheck(void)
{
    SecCodeRef self = NULL;
    SecStaticCodeRef disk = NULL;
    SecRequirementRef own = NULL;
    SecRequirementRef ext = NULL;
    int failures = 0;

    if (SecCodeCopySelf(kSecCSDefaultFlags, &self) != errSecSuccess || !self) {
        fprintf(stderr, "selfcheck: cannot identify self\n");
        return 1;
    }
    if (SecCodeCopyStaticCode(self, kSecCSDefaultFlags, &disk) != errSecSuccess
        || SecCodeCopyDesignatedRequirement(disk, kSecCSDefaultFlags, &own)
               != errSecSuccess) {
        fprintf(stderr,
                "selfcheck: no designated requirement -- unsigned build? "
                "run make sign first\n");
        CFRelease(self);
        if (disk) CFRelease(disk);
        return 1;
    }

    failures += expect("dynamic check, own requirement",
                       dynamic_ok(self, own), errSecSuccess);
    failures += expect("static check, own requirement",
                       static_ok(self, own), errSecSuccess);

    CFStringRef text = CFStringCreateWithCString(NULL, CALLER_REQUIREMENT,
                                                 kCFStringEncodingUTF8);
    if (!text
        || SecRequirementCreateWithString(text, kSecCSDefaultFlags, &ext)
               != errSecSuccess) {
        printf("  FAIL  extension requirement does not parse\n");
        failures++;
    } else {
        failures += expect("dynamic check, extension requirement refused",
                           dynamic_ok(self, ext), errSecCSReqFailed);
        failures += expect("static check, extension requirement refused",
                           static_ok(self, ext), errSecCSReqFailed);
    }

    if (text) CFRelease(text);
    if (ext) CFRelease(ext);
    CFRelease(own);
    CFRelease(disk);
    CFRelease(self);

    printf(failures ? "selfcheck: FAIL\n" : "selfcheck: ok\n");
    return failures ? 1 : 0;
}

int main(int argc, char **argv)
{
    if (argc > 1 && strcmp(argv[1], "--selfcheck") == 0)
        return selfcheck();
    if (argc > 1) {
        fprintf(stderr, "usage: ext4barrierd [--selfcheck]\n");
        return 2;
    }

    /* Same subsystem as the app and extension (dev.h3ct0r.ext4), so the one
     * documented `log stream --predicate 'subsystem == "dev.h3ct0r.ext4"'`
     * shows the daemon too -- it used to log under a subsystem that predicate
     * never matched. */
    log_handle = os_log_create("dev.h3ct0r.ext4", "barrier");
    device_queue = dispatch_queue_create("dev.h3ct0r.ext4mac.barrier.devices",
                                         DISPATCH_QUEUE_SERIAL);

    xpc_connection_t listener =
        xpc_connection_create_mach_service(SERVICE_NAME, NULL,
                                           XPC_CONNECTION_MACH_SERVICE_LISTENER);
    if (!listener) {
        os_log_error(log_handle, "cannot listen on %{public}s", SERVICE_NAME);
        return 1;
    }

    xpc_connection_set_event_handler(listener, ^(xpc_object_t event) {
        if (xpc_get_type(event) == XPC_TYPE_CONNECTION)
            handle_connection((xpc_connection_t)event);
    });
    xpc_connection_resume(listener);

    os_log(log_handle, "ext4 barrier daemon ready");
    dispatch_main();
    return 0;
}
