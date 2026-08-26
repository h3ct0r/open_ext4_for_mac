//
//  aes_xts.c
//  SPDX-License-Identifier: GPL-3.0-or-later
//

#include "aes_xts.h"

#include <CommonCrypto/CommonCryptor.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>

#define AES_BLOCK 16

struct aes_xts_key {
    uint8_t data_key[32];   /* key1: encrypts the data          */
    uint8_t tweak_key[32];  /* key2: encrypts the sector number */
    size_t  half_len;       /* 16 or 32                         */
};

/*
 * Advance the tweak: multiply by the primitive element of GF(2^128).
 *
 * The field element is stored little-endian, so "multiply by x" is a left
 * shift across the whole 16 bytes, and a carry out of the top reduces by the
 * polynomial x^128 + x^7 + x^2 + x + 1 -- which is the 0x87 below.
 */
static void gf_mul_alpha(uint8_t t[AES_BLOCK])
{
    uint8_t carry = 0;
    for (int i = 0; i < AES_BLOCK; i++) {
        uint8_t next = (uint8_t)((t[i] >> 7) & 1);
        t[i] = (uint8_t)((t[i] << 1) | carry);
        carry = next;
    }
    if (carry)
        t[0] ^= 0x87;
}

static int aes_ecb(bool encrypt, const uint8_t *key, size_t key_len,
                   const uint8_t *in, uint8_t *out, size_t len)
{
    size_t moved = 0;
    CCCryptorStatus s = CCCrypt(encrypt ? kCCEncrypt : kCCDecrypt,
                                kCCAlgorithmAES, kCCOptionECBMode,
                                key, key_len, NULL,
                                in, len, out, len, &moved);
    if (s != kCCSuccess || moved != len)
        return EIO;
    return 0;
}

aes_xts_key *aes_xts_key_create(const uint8_t *key, size_t key_len)
{
    /* LUKS stores the two halves concatenated, so the master key is twice the
     * AES key size: 64 bytes for AES-256-XTS, 32 for AES-128-XTS. */
    if (!key || (key_len != 32 && key_len != 64))
        return NULL;

    aes_xts_key *k = calloc(1, sizeof(*k));
    if (!k)
        return NULL;

    k->half_len = key_len / 2;
    memcpy(k->data_key,  key,                k->half_len);
    memcpy(k->tweak_key, key + k->half_len,  k->half_len);
    return k;
}

void aes_xts_key_destroy(aes_xts_key *k)
{
    if (!k)
        return;
    /* memset_s rather than memset: the compiler is entitled to delete a plain
     * memset of memory that is about to be freed, which is exactly the case
     * where it matters. */
    memset_s(k, sizeof(*k), 0, sizeof(*k));
    free(k);
}

void aes_xts_plain64_tweak(uint64_t sector, uint8_t out[AES_BLOCK])
{
    memset(out, 0, AES_BLOCK);
    for (int i = 0; i < 8; i++)
        out[i] = (uint8_t)(sector >> (8 * i));
}

int aes_xts_crypt_sector(const aes_xts_key *k, bool encrypt,
                         const uint8_t tweak[AES_BLOCK],
                         uint8_t *buf, size_t len)
{
    if (!k || !tweak || !buf || len == 0 || (len % AES_BLOCK) != 0)
        return EINVAL;

    /* T = AES-Enc(key2, tweak) -- encryption, in both directions. */
    uint8_t t[AES_BLOCK];
    int r = aes_ecb(true, k->tweak_key, k->half_len, tweak, t, AES_BLOCK);
    if (r != 0)
        return r;

    /*
     * XTS is XOR-encrypt-XOR: for each block, XOR the running tweak in,
     * apply the block cipher, XOR the same tweak out.
     *
     * ECB treats every block independently, so instead of one CommonCrypto
     * call per 16 bytes, the whole sector is masked first and enciphered in a
     * single call. On a 4 KiB sector that is 1 call instead of 256.
     */
    uint8_t *tweaks = malloc(len);
    if (!tweaks)
        return ENOMEM;

    for (size_t off = 0; off < len; off += AES_BLOCK) {
        memcpy(tweaks + off, t, AES_BLOCK);
        for (size_t i = 0; i < AES_BLOCK; i++)
            buf[off + i] ^= t[i];
        gf_mul_alpha(t);
    }

    r = aes_ecb(encrypt, k->data_key, k->half_len, buf, buf, len);
    if (r == 0) {
        for (size_t i = 0; i < len; i++)
            buf[i] ^= tweaks[i];
    }

    memset_s(tweaks, len, 0, len);
    free(tweaks);
    memset_s(t, sizeof(t), 0, sizeof(t));
    return r;
}
