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

/*
 * The cryptors live as long as the key, not as long as one sector.
 *
 * Every sector used to go through two one-shot CCCrypt() calls, and a
 * one-shot call builds a cryptor, runs it, and tears it down. A LUKS2
 * container with 512-byte sectors -- the common case, and the shape of the
 * drive this was measured on -- turns 100 MB into 204,800 sectors, so that
 * was 409,600 cryptor lifecycles and as many malloc/free pairs for the tweak
 * scratch, to encrypt 100 MB. Holding three cryptors (data in both
 * directions, tweak) on the key removes all of it: the key is created once
 * per volume, and the tweak sequence is walked twice rather than stored.
 *
 * ECB carries no state between calls as long as every length is a multiple
 * of the block size -- which this file enforces -- so the cryptors can be
 * reused directly without a reset in between.
 *
 * Not thread-safe, deliberately and in company: the cryptors are shared
 * mutable state, and every caller reaches this through
 * the volume's serial executor, which is also what lwext4 itself requires.
 */
struct aes_xts_key {
    uint8_t data_key[32];   /* key1: encrypts the data          */
    uint8_t tweak_key[32];  /* key2: encrypts the sector number */
    size_t  half_len;       /* 16 or 32                         */

    CCCryptorRef data_enc;  /* key1, ECB, encrypting            */
    CCCryptorRef data_dec;  /* key1, ECB, decrypting            */
    CCCryptorRef tweak_enc; /* key2, ECB, encrypting            */
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
    /* The same shift, two words at a time instead of sixteen bytes. The
     * element is little-endian, so the low word supplies the bits the high
     * word shifts into. memcpy rather than a cast: it says "these bytes are
     * that integer" without promising an alignment the caller never made,
     * and every compiler turns it into a load. */
    uint64_t lo, hi;
    memcpy(&lo, t,     sizeof lo);
    memcpy(&hi, t + 8, sizeof hi);

    uint64_t carry = hi >> 63;
    hi = (hi << 1) | (lo >> 63);
    lo = lo << 1;
    if (carry)
        lo ^= 0x87;

    memcpy(t,     &lo, sizeof lo);
    memcpy(t + 8, &hi, sizeof hi);
}

/* XOR one 16-byte block in place, two words at a time. */
static inline void xor_block(uint8_t *dst, const uint8_t src[AES_BLOCK])
{
    uint64_t d0, d1, s0, s1;
    memcpy(&d0, dst,     sizeof d0);
    memcpy(&d1, dst + 8, sizeof d1);
    memcpy(&s0, src,     sizeof s0);
    memcpy(&s1, src + 8, sizeof s1);
    d0 ^= s0;
    d1 ^= s1;
    memcpy(dst,     &d0, sizeof d0);
    memcpy(dst + 8, &d1, sizeof d1);
}

/* Run a prepared ECB cryptor over a block-aligned buffer. */
static int aes_ecb_run(CCCryptorRef ref, const uint8_t *in, uint8_t *out,
                       size_t len)
{
    size_t moved = 0;
    CCCryptorStatus s = CCCryptorUpdate(ref, in, len, out, len, &moved);
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

    if (CCCryptorCreate(kCCEncrypt, kCCAlgorithmAES, kCCOptionECBMode,
                        k->data_key, k->half_len, NULL,
                        &k->data_enc) != kCCSuccess ||
        CCCryptorCreate(kCCDecrypt, kCCAlgorithmAES, kCCOptionECBMode,
                        k->data_key, k->half_len, NULL,
                        &k->data_dec) != kCCSuccess ||
        CCCryptorCreate(kCCEncrypt, kCCAlgorithmAES, kCCOptionECBMode,
                        k->tweak_key, k->half_len, NULL,
                        &k->tweak_enc) != kCCSuccess) {
        aes_xts_key_destroy(k);
        return NULL;
    }

    return k;
}

void aes_xts_key_destroy(aes_xts_key *k)
{
    if (!k)
        return;
    if (k->data_enc)  CCCryptorRelease(k->data_enc);
    if (k->data_dec)  CCCryptorRelease(k->data_dec);
    if (k->tweak_enc) CCCryptorRelease(k->tweak_enc);
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

    /* The cryptors are built with the key and reused across sectors, which
     * is mutable state behind a const pointer. */
    aes_xts_key *key = (aes_xts_key *)k;

    /* T = AES-Enc(key2, tweak) -- encryption, in both directions. */
    uint8_t t[AES_BLOCK];
    int r = aes_ecb_run(key->tweak_enc, tweak, t, AES_BLOCK);
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
    /* The second pass needs the same tweak sequence as the first. Keeping the
     * starting value and walking the chain again is cheaper than remembering
     * every step: it replaces a buffer the size of the sector, the allocation
     * behind it, and a copy of the whole sector into it with sixteen bytes
     * and one shift per block. */
    uint8_t t0[AES_BLOCK];
    memcpy(t0, t, sizeof t0);

    for (size_t off = 0; off < len; off += AES_BLOCK) {
        xor_block(buf + off, t);
        gf_mul_alpha(t);
    }

    r = aes_ecb_run(encrypt ? key->data_enc : key->data_dec, buf, buf, len);
    if (r == 0) {
        memcpy(t, t0, sizeof t);
        for (size_t off = 0; off < len; off += AES_BLOCK) {
            xor_block(buf + off, t);
            gf_mul_alpha(t);
        }
    }

    memset_s(t0, sizeof(t0), 0, sizeof(t0));
    memset_s(t, sizeof(t), 0, sizeof(t));
    return r;
}
