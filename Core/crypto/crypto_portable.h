/*
 * crypto_portable.h — the handful of things this crypto layer needs that the
 * two systems it builds on spell differently.
 *
 * The driver ships on macOS. The tools also build on Linux, because that is
 * where the oracle suites can run without a virtual machine: the Linux
 * kernel's own ext4 is the second opinion on everything this driver writes,
 * and no macOS CI runner can give us that.
 *
 * Two differences, and both matter for correctness rather than convenience:
 *
 *   memset_s   C11 Annex K, which Apple implements and glibc does not. It
 *              exists to zero key material and NOT be optimised away, which
 *              an ordinary memset on a buffer about to be freed reliably is.
 *              The Linux stand-in uses a volatile function pointer to
 *              memset, which is the portable idiom for the same guarantee --
 *              the compiler cannot prove anything about a value it must load.
 *
 *   AES + PBKDF2 + SHA
 *              CommonCrypto on macOS, OpenSSL's libcrypto on Linux. Both are
 *              the platform's own audited implementation, which is the point:
 *              this file must never contain an AES.
 */
#ifndef EXT4B_CRYPTO_PORTABLE_H
#define EXT4B_CRYPTO_PORTABLE_H

#include <stddef.h>
#include <string.h>
#include <errno.h>   /* every helper below reports through errno values */

#ifdef __APPLE__

#include <CommonCrypto/CommonCryptor.h>
#include <CommonCrypto/CommonDigest.h>
#include <CommonCrypto/CommonKeyDerivation.h>

#else  /* Linux */

#include <openssl/evp.h>
#include <openssl/sha.h>

/* CommonCrypto's digest lengths, by their CommonCrypto names, so the callers
 * below do not have to know which system they are on. */
#define CC_SHA1_DIGEST_LENGTH   20
#define CC_SHA256_DIGEST_LENGTH 32
#define CC_SHA512_DIGEST_LENGTH 64

/*
 * memset_s, near enough. The standard's contract is "this store happens",
 * and a volatile pointer to memset is how that is obtained without Annex K:
 * the compiler must load the pointer and call through it, so it cannot
 * conclude the write is dead.
 */
/* `const volatile`, and both words matter. `const` alone is a compile-time
 * constant that the optimiser folds straight back to memset, after which the
 * wipe of a buffer that is about to be freed is a dead store and is deleted --
 * gcc -O2 removes the entire call. `volatile` is what forces the load through
 * the pointer, so the compiler cannot know what it calls and must call it.
 * The same idiom, spelled the same way, is in argon2/core.c. */
static void *(*const volatile ext4b_volatile_memset)(void *, int, size_t) = memset;

static inline int memset_s(void *dst, size_t dstsz, int ch, size_t n)
{
    if (dst == NULL) return EINVAL;
    if (n > dstsz)   { ext4b_volatile_memset(dst, ch, dstsz); return ERANGE; }
    ext4b_volatile_memset(dst, ch, n);
    return 0;
}

#endif /* __APPLE__ */

/* ------------------------------------------------------------- AES-ECB -- */
/*
 * One primitive, three uses.
 *
 * AES-XTS is built out of ECB here because ECB is the only AES mode both
 * platforms expose as a raw block operation -- see the note in aes_xts.h. The
 * cryptor lives as long as the key rather than as long as a sector, because a
 * per-sector create/destroy costs more than the encryption does.
 *
 * The two backends are the platform's own audited implementation, and that is
 * the whole design rule for this directory: no AES is written here.
 */
#ifdef __APPLE__
typedef CCCryptorRef ext4b_ecb;
#else
typedef EVP_CIPHER_CTX *ext4b_ecb;
#endif

/* Returns 0, or an errno. `encrypt` chooses the direction; key_len is 16 or
 * 32 bytes. */
static inline int ext4b_ecb_create(ext4b_ecb *out, int encrypt,
                                   const uint8_t *key, size_t key_len)
{
#ifdef __APPLE__
    CCCryptorRef ref = NULL;
    if (CCCryptorCreate(encrypt ? kCCEncrypt : kCCDecrypt,
                        kCCAlgorithmAES, kCCOptionECBMode,
                        key, key_len, NULL, &ref) != kCCSuccess)
        return EIO;
    *out = ref;
    return 0;
#else
    const EVP_CIPHER *c = (key_len == 16) ? EVP_aes_128_ecb()
                        : (key_len == 32) ? EVP_aes_256_ecb()
                        : NULL;
    if (!c) return EINVAL;
    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    if (!ctx) return ENOMEM;
    if (EVP_CipherInit_ex(ctx, c, NULL, key, NULL, encrypt ? 1 : 0) != 1) {
        EVP_CIPHER_CTX_free(ctx);
        return EIO;
    }
    /* No padding: this is a raw block operation and the caller always passes
     * whole blocks. With padding on, OpenSSL would withhold the final block
     * and then append one, which is not what a block cipher primitive does. */
    EVP_CIPHER_CTX_set_padding(ctx, 0);
    *out = ctx;
    return 0;
#endif
}

static inline int ext4b_ecb_run(ext4b_ecb ref, const uint8_t *in,
                                uint8_t *out, size_t len)
{
#ifdef __APPLE__
    size_t moved = 0;
    if (CCCryptorUpdate(ref, in, len, out, len, &moved) != kCCSuccess)
        return EIO;
    return moved == len ? 0 : EIO;
#else
    int moved = 0;
    if (EVP_CipherUpdate(ref, out, &moved, in, (int)len) != 1)
        return EIO;
    return (size_t)moved == len ? 0 : EIO;
#endif
}

static inline void ext4b_ecb_free(ext4b_ecb ref)
{
    if (!ref) return;
#ifdef __APPLE__
    CCCryptorRelease(ref);
#else
    EVP_CIPHER_CTX_free(ref);
#endif
}

/* ------------------------------------------------------ digests, PBKDF2 -- */

/* SHA-1, SHA-256 and SHA-512 in one call, chosen by digest length so the
 * caller's enum does not have to cross this header. */
static inline int ext4b_digest(size_t out_len, const uint8_t *data, size_t len,
                               uint8_t *out)
{
#ifdef __APPLE__
    switch (out_len) {
    case CC_SHA1_DIGEST_LENGTH:   CC_SHA1(data,   (CC_LONG)len, out); return 0;
    case CC_SHA256_DIGEST_LENGTH: CC_SHA256(data, (CC_LONG)len, out); return 0;
    case CC_SHA512_DIGEST_LENGTH: CC_SHA512(data, (CC_LONG)len, out); return 0;
    default: return EINVAL;
    }
#else
    switch (out_len) {
    case CC_SHA1_DIGEST_LENGTH:   SHA1(data, len, out);   return 0;
    case CC_SHA256_DIGEST_LENGTH: SHA256(data, len, out); return 0;
    case CC_SHA512_DIGEST_LENGTH: SHA512(data, len, out); return 0;
    default: return EINVAL;
    }
#endif
}

static inline int ext4b_pbkdf2(size_t digest_len,
                               const uint8_t *password, size_t password_len,
                               const uint8_t *salt, size_t salt_len,
                               uint32_t iterations,
                               uint8_t *out, size_t out_len)
{
    /* An empty passphrase is legal in LUKS, and both backends want a non-NULL
     * pointer with a zero length rather than NULL. */
    const char *pw = (const char *)(password ? password : (const uint8_t *)"");
#ifdef __APPLE__
    CCPseudoRandomAlgorithm prf;
    switch (digest_len) {
    case CC_SHA1_DIGEST_LENGTH:   prf = kCCPRFHmacAlgSHA1;   break;
    case CC_SHA256_DIGEST_LENGTH: prf = kCCPRFHmacAlgSHA256; break;
    case CC_SHA512_DIGEST_LENGTH: prf = kCCPRFHmacAlgSHA512; break;
    default: return EINVAL;
    }
    return CCKeyDerivationPBKDF(kCCPBKDF2, pw, password_len,
                                salt, salt_len, prf, iterations,
                                out, out_len) == kCCSuccess ? 0 : EIO;
#else
    const EVP_MD *md = (digest_len == CC_SHA1_DIGEST_LENGTH)   ? EVP_sha1()
                     : (digest_len == CC_SHA256_DIGEST_LENGTH) ? EVP_sha256()
                     : (digest_len == CC_SHA512_DIGEST_LENGTH) ? EVP_sha512()
                     : NULL;
    if (!md) return EINVAL;
    return PKCS5_PBKDF2_HMAC(pw, (int)password_len, salt, (int)salt_len,
                             (int)iterations, md, (int)out_len, out) == 1
           ? 0 : EIO;
#endif
}

#endif /* EXT4B_CRYPTO_PORTABLE_H */
