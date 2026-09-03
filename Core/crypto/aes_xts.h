//
//  aes_xts.h
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  AES-XTS, as dm-crypt uses it for LUKS (`aes-xts-plain64`).
//
//  XTS is not a general-purpose mode: it is designed for storage, where the
//  same key encrypts every sector and the sector number itself supplies the
//  variation. Each sector is encrypted independently, which is what makes
//  random access possible -- and also what makes a wrong sector number produce
//  perfectly-formed garbage rather than an error.
//
//  This is built on CommonCrypto's AES-ECB, which is the only primitive macOS
//  exposes that XTS needs; there is no kCCModeXTS. Apple Silicon accelerates
//  AES in hardware, so the ECB call underneath is not the slow part.
//

#ifndef AES_XTS_H
#define AES_XTS_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/// One XTS key pair. `key` is the concatenation key1||key2 as LUKS stores it:
/// 64 bytes for AES-256-XTS, 32 bytes for AES-128-XTS.
typedef struct aes_xts_key aes_xts_key;

/// Returns NULL if the key length is not 32 or 64 bytes.
aes_xts_key *aes_xts_key_create(const uint8_t *key, size_t key_len);

/// Zeroes the key material before freeing it.
void aes_xts_key_destroy(aes_xts_key *k);

/*
 * Whether the schedule sits in memory the kernel has been told not to page
 * out. A key schedule lives for as long as the volume is mounted, and
 * anonymous memory that lives that long can end up in a swap file that
 * outlives the machine being switched off; mlock is the only answer a
 * userspace process has. False is not a failure to open anything -- the lock
 * is best-effort, because a container that refuses to mount when the kernel
 * declines to lock a page is worse for its owner than a key that might reach
 * swap -- but it is a fact a test is entitled to check.
 */
bool aes_xts_key_is_locked(const aes_xts_key *k);

/// Encrypt or decrypt one sector in place.
///
/// `tweak` is the value dm-crypt calls the IV. For `plain64` it is the sector
/// index as a 64-bit little-endian integer, zero-padded to 16 bytes -- which
/// aes_xts_plain64_tweak() builds. `len` must be a non-zero multiple of 16;
/// storage sectors always are, so ciphertext stealing is not implemented and
/// a length that would need it is rejected rather than silently mishandled.
///
/// Returns 0 on success, or an errno value.
int aes_xts_crypt_sector(const aes_xts_key *k, bool encrypt,
                         const uint8_t tweak[16],
                         uint8_t *buf, size_t len);

/// Build the `plain64` tweak for a sector index.
void aes_xts_plain64_tweak(uint64_t sector, uint8_t out[16]);

#ifdef __cplusplus
}
#endif

#endif /* AES_XTS_H */
