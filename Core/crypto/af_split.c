//
//  af_split.c
//  SPDX-License-Identifier: GPL-3.0-or-later
//

#include "crypto_portable.h"
#include "af_split.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>

/*
 * The diffusion step: hash the buffer in digest-sized chunks, each prefixed
 * with its own index as a big-endian 32-bit counter, so that a change anywhere
 * in a chunk changes the whole chunk of output. A trailing partial chunk is
 * hashed the same way and truncated.
 *
 * This is cryptsetup's AF_hash-based diffuse; the counter prefix is what makes
 * the chunks independent rather than a single long hash chain.
 */
static int diffuse(const uint8_t *src, uint8_t *dst, size_t len,
                   crypto_hash hash)
{
    const size_t digest_len = crypto_hash_size(hash);
    if (digest_len == 0)
        return EINVAL;

    const size_t full = len / digest_len;
    const size_t tail = len % digest_len;

    uint8_t *chunk = malloc(digest_len + 4);
    uint8_t  digest[64];   /* large enough for SHA-512 */
    if (!chunk)
        return ENOMEM;

    int r = 0;
    for (size_t i = 0; i < full; i++) {
        uint32_t counter = (uint32_t)i;
        chunk[0] = (uint8_t)(counter >> 24);
        chunk[1] = (uint8_t)(counter >> 16);
        chunk[2] = (uint8_t)(counter >> 8);
        chunk[3] = (uint8_t)(counter);
        memcpy(chunk + 4, src + i * digest_len, digest_len);

        r = crypto_hash_compute(hash, chunk, digest_len + 4, dst + i * digest_len);
        if (r != 0)
            goto out;
    }

    if (tail) {
        uint32_t counter = (uint32_t)full;
        chunk[0] = (uint8_t)(counter >> 24);
        chunk[1] = (uint8_t)(counter >> 16);
        chunk[2] = (uint8_t)(counter >> 8);
        chunk[3] = (uint8_t)(counter);
        memcpy(chunk + 4, src + full * digest_len, tail);

        r = crypto_hash_compute(hash, chunk, tail + 4, digest);
        if (r != 0)
            goto out;
        memcpy(dst + full * digest_len, digest, tail);
    }

out:
    memset_s(chunk, digest_len + 4, 0, digest_len + 4);
    memset_s(digest, sizeof(digest), 0, sizeof(digest));
    free(chunk);
    return r;
}

int af_merge(const uint8_t *src, size_t key_len, unsigned stripes,
             crypto_hash hash, uint8_t *out)
{
    if (!src || !out || key_len == 0 || stripes == 0)
        return EINVAL;
    if (crypto_hash_size(hash) == 0)
        return EINVAL;

    uint8_t *acc = calloc(1, key_len);
    if (!acc)
        return ENOMEM;

    int r = 0;
    /* Fold in every stripe but the last, diffusing after each. */
    for (unsigned i = 0; i < stripes - 1; i++) {
        for (size_t j = 0; j < key_len; j++)
            acc[j] ^= src[i * key_len + j];

        r = diffuse(acc, acc, key_len, hash);
        if (r != 0)
            goto out;
    }

    /* The last stripe is XORed in without diffusion; the result is the key. */
    for (size_t j = 0; j < key_len; j++)
        out[j] = acc[j] ^ src[(stripes - 1) * key_len + j];

out:
    memset_s(acc, key_len, 0, key_len);
    free(acc);
    return r;
}
