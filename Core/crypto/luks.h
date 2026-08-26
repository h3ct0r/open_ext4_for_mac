//
//  luks.h
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Opening a LUKS container, so that an ext4 filesystem inside one can be
//  mounted.
//
//  LUKS is not an ext4 feature; it is a block layer *underneath* the
//  filesystem. That is why this fits without disturbing anything: it decorates
//  the same read/write/flush callbacks ext4b_device_create() already takes,
//  shifting offsets past the header and encrypting each sector on the way
//  through. lwext4 never learns that the volume is encrypted.
//
//      lwext4 -> ext4b_device -> [ luks_device ] -> the caller's callbacks
//
//  Two halves, deliberately separable:
//
//    * unlocking  -- turning a passphrase into the master key. Expensive by
//                    design (LUKS2 asks for a gigabyte of memory), and the
//                    only part that ever touches the passphrase.
//    * the device -- turning the master key into readable sectors. Cheap, and
//                    all that a mounted volume needs.
//
//  A caller may therefore unlock somewhere convenient -- a container app that
//  can prompt and can allocate -- and hand only the master key to whatever
//  does the mounting.
//

#ifndef LUKS_H
#define LUKS_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "ext4_bridge.h"   /* ext4b_read_fn / ext4b_write_fn / ext4b_flush_fn */

#ifdef __cplusplus
extern "C" {
#endif

#define LUKS_MAX_MASTER_KEY 64      /* AES-256-XTS: two 32-byte halves */
#define LUKS_UUID_LEN       40

/// Why a container cannot be opened. Reported rather than guessed at: a
/// mistaken assumption about a cipher would produce plausible-looking garbage,
/// not an error.
typedef enum {
    LUKS_OK = 0,
    LUKS_NOT_LUKS,          /* no LUKS magic                                */
    LUKS_UNSUPPORTED,       /* LUKS, but with parameters we do not implement */
    LUKS_BAD_PASSPHRASE,    /* no key slot accepted it                       */
    LUKS_IO,                /* the device could not be read                  */
    LUKS_CORRUPT,           /* the header contradicts itself                 */
} luks_status;

const char *luks_strstatus(luks_status s);

/// What a container advertises about itself, filled in by luks_probe().
typedef struct {
    int      version;                    /* 1 or 2                        */
    char     cipher[32];                 /* "aes"                         */
    char     mode[32];                   /* "xts-plain64"                 */
    char     hash[32];                   /* "sha256"                      */
    uint64_t payload_offset;             /* bytes from the start          */
    uint32_t key_bytes;                  /* master key length             */
    uint32_t sector_size;                /* encryption sector, 512 or 4096 */
    char     uuid[LUKS_UUID_LEN + 1];
    char     unsupported[160];           /* why, when status is UNSUPPORTED */
} luks_info;

/// Read and validate the header. Does not need a passphrase.
luks_status luks_probe(void *ctx, ext4b_read_fn read_fn, luks_info *out);

/// Turn a passphrase into the master key, trying every enabled key slot.
///
/// `master_key` must have room for LUKS_MAX_MASTER_KEY bytes; `*mk_len`
/// receives the length actually used. The result is verified against the
/// header's own digest, so a wrong passphrase is reported as
/// LUKS_BAD_PASSPHRASE rather than yielding a key that decrypts to noise.
luks_status luks_unlock(void *ctx, ext4b_read_fn read_fn,
                        const luks_info *info,
                        const uint8_t *passphrase, size_t passphrase_len,
                        uint8_t *master_key, size_t *mk_len);

/// A device that decrypts on the way through. Offsets it is given are relative
/// to the start of the payload, so the caller sees a plain block device.
typedef struct luks_device luks_device;

luks_device *luks_device_open(void *ctx,
                              ext4b_read_fn read_fn,
                              ext4b_write_fn write_fn,
                              ext4b_flush_fn flush_fn,
                              const luks_info *info,
                              const uint8_t *master_key, size_t mk_len);

/// Zeroes the key material before freeing.
void luks_device_close(luks_device *d);

/// Hand these to ext4b_device_create(), with the luks_device as its context.
int luks_device_read(void *ctx, void *buf, uint64_t offset, size_t count);
int luks_device_write(void *ctx, const void *buf, uint64_t offset, size_t count);
int luks_device_flush(void *ctx);

/// Bytes available to the filesystem, given the size of the whole container.
uint64_t luks_payload_size(const luks_device *d, uint64_t container_size);

#ifdef __cplusplus
}
#endif

#endif /* LUKS_H */
