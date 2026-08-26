//
//  crypto_hash.c
//  SPDX-License-Identifier: GPL-3.0-or-later
//

#include "crypto_hash.h"

#include <CommonCrypto/CommonCryptor.h>   /* kCCSuccess */
#include <CommonCrypto/CommonDigest.h>
#include <CommonCrypto/CommonKeyDerivation.h>
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
    switch (h) {
    case CRYPTO_HASH_SHA1:   CC_SHA1(data,   (CC_LONG)len, out); return 0;
    case CRYPTO_HASH_SHA256: CC_SHA256(data, (CC_LONG)len, out); return 0;
    case CRYPTO_HASH_SHA512: CC_SHA512(data, (CC_LONG)len, out); return 0;
    default:                 return EINVAL;
    }
}

int crypto_pbkdf2(crypto_hash h,
                  const uint8_t *password, size_t password_len,
                  const uint8_t *salt, size_t salt_len,
                  uint32_t iterations,
                  uint8_t *out, size_t out_len)
{
    CCPseudoRandomAlgorithm prf;
    switch (h) {
    case CRYPTO_HASH_SHA1:   prf = kCCPRFHmacAlgSHA1;   break;
    case CRYPTO_HASH_SHA256: prf = kCCPRFHmacAlgSHA256; break;
    case CRYPTO_HASH_SHA512: prf = kCCPRFHmacAlgSHA512; break;
    default: return EINVAL;
    }
    if (!out || out_len == 0 || iterations == 0)
        return EINVAL;

    /* An empty passphrase is legal in LUKS, and CommonCrypto accepts a NULL
     * pointer only with a zero length, so normalise rather than pass NULL. */
    const char *pw = (const char *)(password ? password : (const uint8_t *)"");

    int rc = CCKeyDerivationPBKDF(kCCPBKDF2, pw, password_len,
                                  salt, salt_len, prf, iterations,
                                  out, out_len);
    return rc == kCCSuccess ? 0 : EIO;
}
