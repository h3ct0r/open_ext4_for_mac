//
//  crypto_hash.c
//  SPDX-License-Identifier: GPL-3.0-or-later
//

#include "crypto_portable.h"
#include "crypto_hash.h"

#include <errno.h>
#include <string.h>

crypto_hash crypto_hash_by_name(const char *name)
{
    if (!name)
        return CRYPTO_HASH_NONE;
    if (strcmp(name, "sha1")   == 0) return CRYPTO_HASH_SHA1;
    if (strcmp(name, "sha256") == 0) return CRYPTO_HASH_SHA256;
    if (strcmp(name, "sha512") == 0) return CRYPTO_HASH_SHA512;
    return CRYPTO_HASH_NONE;
}

size_t crypto_hash_size(crypto_hash h)
{
    switch (h) {
    case CRYPTO_HASH_SHA1:   return CC_SHA1_DIGEST_LENGTH;
    case CRYPTO_HASH_SHA256: return CC_SHA256_DIGEST_LENGTH;
    case CRYPTO_HASH_SHA512: return CC_SHA512_DIGEST_LENGTH;
    default:                 return 0;
    }
}

const char *crypto_hash_name(crypto_hash h)
{
    switch (h) {
    case CRYPTO_HASH_SHA1:   return "sha1";
    case CRYPTO_HASH_SHA256: return "sha256";
    case CRYPTO_HASH_SHA512: return "sha512";
    default:                 return "unknown";
    }
}

int crypto_hash_compute(crypto_hash h, const uint8_t *data, size_t len,
                        uint8_t *out)
{
    if (!out || (!data && len))
        return EINVAL;
    size_t n = crypto_hash_size(h);
    if (n == 0)
        return EINVAL;
    return ext4b_digest(n, data, len, out);
}

int crypto_pbkdf2(crypto_hash h,
                  const uint8_t *password, size_t password_len,
                  const uint8_t *salt, size_t salt_len,
                  uint32_t iterations,
                  uint8_t *out, size_t out_len)
{
    size_t n = crypto_hash_size(h);
    if (n == 0)
        return EINVAL;
    if (!out || out_len == 0 || iterations == 0)
        return EINVAL;

    return ext4b_pbkdf2(n, password, password_len, salt, salt_len,
                        iterations, out, out_len);
}
