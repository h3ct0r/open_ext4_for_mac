//
//  crypto_hash.h
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  The handful of hashes LUKS names in its headers, behind one small
//  interface. LUKS stores the hash as a string ("sha256"), so the mapping from
//  name to implementation is an allow-list: a hash we do not recognise is
//  refused rather than substituted, because guessing here would mean deriving
//  the wrong key and reporting a wrong passphrase.
//

#ifndef CRYPTO_HASH_H
#define CRYPTO_HASH_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    CRYPTO_HASH_NONE = 0,
    CRYPTO_HASH_SHA1,
    CRYPTO_HASH_SHA256,
    CRYPTO_HASH_SHA512,
} crypto_hash;

/// CRYPTO_HASH_NONE when the name is not one we support.
crypto_hash crypto_hash_by_name(const char *name);

/// Digest length in bytes, or 0 for CRYPTO_HASH_NONE.
size_t crypto_hash_size(crypto_hash h);

/// Human-readable name, for error messages.
const char *crypto_hash_name(crypto_hash h);

/// One-shot digest. Returns 0, or an errno value.
int crypto_hash_compute(crypto_hash h, const uint8_t *data, size_t len,
                        uint8_t *out);

/// PBKDF2-HMAC over the same hash. Returns 0, or an errno value.
int crypto_pbkdf2(crypto_hash h,
                  const uint8_t *password, size_t password_len,
                  const uint8_t *salt, size_t salt_len,
                  uint32_t iterations,
                  uint8_t *out, size_t out_len);

#ifdef __cplusplus
}
#endif

#endif /* CRYPTO_HASH_H */
