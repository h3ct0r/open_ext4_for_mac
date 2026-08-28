//
//  luks.c
//  SPDX-License-Identifier: GPL-3.0-or-later
//

#include "luks.h"

#include "aes_xts.h"
#include "af_split.h"
#include "crypto_hash.h"
#include "json.h"
#include "argon2/argon2.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ---------------------------------------------------------- LUKS1 header -- */
/*
 * Every multi-byte field is big-endian, which is unusual enough on a
 * little-endian machine to be worth reading carefully. Offsets are from the
 * LUKS1 on-disk specification.
 */
#define LUKS_MAGIC_LEN      6
static const uint8_t LUKS_MAGIC[LUKS_MAGIC_LEN] = { 'L','U','K','S', 0xba, 0xbe };

/*
 * A ceiling on PBKDF2 iteration counts read from the header. The count is an
 * attacker-controlled field on media we did not create; without a bound,
 * 0xFFFFFFFF iterations of HMAC-SHA512 is hours of CPU per slot, times eight
 * slots -- a denial of service delivered by a crafted header. 100 million is
 * ~25x a paranoid real-world setting (cryptsetup tunes to a time, typically a
 * few million iterations), so it accepts every genuine volume and refuses only
 * the absurd. An over-count is treated as corruption, not clamped: a real
 * header never approaches it.
 */
#define LUKS_MAX_PBKDF2_ITER 100000000u

#define L1_VERSION          6
#define L1_CIPHER_NAME      8
#define L1_CIPHER_MODE      40
#define L1_HASH_SPEC        72
#define L1_PAYLOAD_OFFSET   104
#define L1_KEY_BYTES        108
#define L1_MK_DIGEST        112
#define L1_MK_DIGEST_SALT   132
#define L1_MK_DIGEST_ITER   164
#define L1_UUID             168
#define L1_KEY_SLOTS        208

#define L1_DIGEST_LEN       20      /* fixed by the format, whatever the hash */
#define L1_SALT_LEN         32
#define L1_NUM_SLOTS        8
#define L1_SLOT_SIZE        48
#define L1_SLOT_ENABLED     0x00AC71F3
#define L1_SECTOR           512

#define L1_HEADER_LEN       (L1_KEY_SLOTS + L1_NUM_SLOTS * L1_SLOT_SIZE)

typedef struct {
    uint32_t active;
    uint32_t iterations;
    uint8_t  salt[L1_SALT_LEN];
    uint32_t key_material_offset;   /* in 512-byte sectors */
    uint32_t stripes;
} luks1_slot;

static uint16_t rd16be(const uint8_t *p) { return (uint16_t)((p[0] << 8) | p[1]); }
static uint32_t rd32be(const uint8_t *p)
{
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16)
         | ((uint32_t)p[2] << 8)  |  (uint32_t)p[3];
}

/* Header strings are fixed-width and NUL-padded, but a corrupt header need not
 * be, so copy with a hard bound and terminate ourselves. */
static void copy_field(char *dst, size_t dst_len, const uint8_t *src, size_t n)
{
    size_t len = n < dst_len - 1 ? n : dst_len - 1;
    memcpy(dst, src, len);
    dst[len] = 0;
}

const char *luks_strstatus(luks_status s)
{
    switch (s) {
    case LUKS_OK:             return "ok";
    case LUKS_NOT_LUKS:       return "not a LUKS container";
    case LUKS_UNSUPPORTED:    return "unsupported LUKS parameters";
    case LUKS_BAD_PASSPHRASE: return "no key slot accepted the passphrase";
    case LUKS_IO:             return "could not read the container";
    case LUKS_CORRUPT:        return "the LUKS header is inconsistent";
    default:                  return "unknown";
    }
}

/*
 * Allow-list, in the same spirit as the ext4 feature gate: anything not
 * explicitly vetted is refused. Silently treating an unknown cipher as AES
 * would not fail -- it would produce well-formed nonsense and, on a write,
 * destroy the volume.
 */
static bool supported_cipher(luks_info *info)
{
    if (strcmp(info->cipher, "aes") != 0) {
        snprintf(info->unsupported, sizeof(info->unsupported),
                 "cipher \"%s\" (only aes is implemented)", info->cipher);
        return false;
    }
    if (strcmp(info->mode, "xts-plain64") != 0) {
        snprintf(info->unsupported, sizeof(info->unsupported),
                 "mode \"%s\" (only xts-plain64 is implemented)", info->mode);
        return false;
    }
    if (info->key_bytes != 32 && info->key_bytes != 64) {
        snprintf(info->unsupported, sizeof(info->unsupported),
                 "%u-byte master key (expected 32 or 64 for aes-xts)",
                 info->key_bytes);
        return false;
    }
    if (crypto_hash_by_name(info->hash) == CRYPTO_HASH_NONE) {
        snprintf(info->unsupported, sizeof(info->unsupported),
                 "hash \"%s\" (only sha1, sha256 and sha512 are implemented)",
                 info->hash);
        return false;
    }
    return true;
}

static luks_status probe_luks1(const uint8_t *hdr, luks_info *out)
{
    out->version = 1;
    copy_field(out->cipher, sizeof(out->cipher), hdr + L1_CIPHER_NAME, 32);
    copy_field(out->mode,   sizeof(out->mode),   hdr + L1_CIPHER_MODE, 32);
    copy_field(out->hash,   sizeof(out->hash),   hdr + L1_HASH_SPEC,   32);
    copy_field(out->uuid,   sizeof(out->uuid),   hdr + L1_UUID,        LUKS_UUID_LEN);

    out->key_bytes  = rd32be(hdr + L1_KEY_BYTES);
    out->sector_size = L1_SECTOR;           /* LUKS1 has no other option */
    out->payload_offset = (uint64_t)rd32be(hdr + L1_PAYLOAD_OFFSET) * L1_SECTOR;

    if (out->payload_offset < L1_HEADER_LEN)
        return LUKS_CORRUPT;
    if (out->key_bytes == 0 || out->key_bytes > LUKS_MAX_MASTER_KEY)
        return LUKS_CORRUPT;

    return supported_cipher(out) ? LUKS_OK : LUKS_UNSUPPORTED;
}

/* Defined below, with the rest of the LUKS2 handling. */
static luks_status probe_luks2(void *ctx, ext4b_read_fn read_fn, luks_info *out);

luks_status luks_probe(void *ctx, ext4b_read_fn read_fn, luks_info *out)
{
    if (!read_fn || !out)
        return LUKS_CORRUPT;

    memset(out, 0, sizeof(*out));

    uint8_t hdr[L1_HEADER_LEN];
    if (read_fn(ctx, hdr, 0, sizeof(hdr)) != 0)
        return LUKS_IO;

    if (memcmp(hdr, LUKS_MAGIC, LUKS_MAGIC_LEN) != 0)
        return LUKS_NOT_LUKS;

    uint16_t version = rd16be(hdr + L1_VERSION);
    if (version == 1)
        return probe_luks1(hdr, out);
    if (version == 2)
        return probe_luks2(ctx, read_fn, out);

    out->version = version;
    snprintf(out->unsupported, sizeof(out->unsupported),
             "LUKS version %u is not a format this driver knows", version);
    return LUKS_UNSUPPORTED;
}

/* ---------------------------------------------------------- LUKS2 header -- */
/*
 * LUKS2 keeps a 4096-byte binary header followed by a JSON metadata area, and
 * two complete copies of both: the primary at offset 0, the secondary
 * immediately after it with its magic reversed to "SKUL". Each copy carries a
 * sequence id and a checksum over itself, so an update that is interrupted
 * leaves one good copy and one that fails its own checksum -- which is how the
 * newer *valid* copy is chosen below.
 */
#define L2_MAGIC_SECONDARY  "SKUL\xba\xbe"
#define L2_BIN_LEN          4096

#define L2_HDR_SIZE         8      /* uint64 BE, binary header + JSON area */
#define L2_SEQID            16     /* uint64 BE                            */
#define L2_CHECKSUM_ALG     72     /* 32 bytes                             */
#define L2_UUID             168    /* 40 bytes                             */
#define L2_CSUM             448    /* 64 bytes                             */

#define L2_MAX_HDR          (1u << 22)   /* 4 MiB; real headers are 16 KiB */
#define L2_MAX_TOKENS       4096

static uint64_t rd64be(const uint8_t *p)
{
    uint64_t v = 0;
    for (int i = 0; i < 8; i++)
        v = (v << 8) | p[i];
    return v;
}

/* One decoded copy of the header. */
typedef struct {
    uint64_t seqid;
    uint64_t hdr_size;
    char     uuid[LUKS_UUID_LEN + 1];
    char    *json;        /* NUL-terminated copy of the metadata area */
    size_t   json_len;
} luks2_header;

static void luks2_header_free(luks2_header *h)
{
    if (h && h->json) {
        free(h->json);
        h->json = NULL;
    }
}

/*
 * The checksum covers the binary header with its own csum field zeroed,
 * followed by the JSON area. Verifying it is what makes "the newer copy" a
 * safe rule rather than a hopeful one.
 */
static bool luks2_checksum_ok(const uint8_t *bin, const char *json,
                              size_t json_len, crypto_hash hash)
{
    size_t digest_len = crypto_hash_size(hash);
    if (digest_len == 0 || digest_len > 64)
        return false;

    size_t total = L2_BIN_LEN + json_len;
    uint8_t *buf = malloc(total);
    if (!buf)
        return false;

    memcpy(buf, bin, L2_BIN_LEN);
    memset(buf + L2_CSUM, 0, 64);
    memcpy(buf + L2_BIN_LEN, json, json_len);

    uint8_t got[64];
    bool okay = false;
    if (crypto_hash_compute(hash, buf, total, got) == 0)
        okay = memcmp(got, bin + L2_CSUM, digest_len) == 0;

    free(buf);
    return okay;
}

/* Read one copy of the header from `base`, verifying it before returning it. */
static bool luks2_read_copy(void *ctx, ext4b_read_fn read_fn, uint64_t base,
                            const char *magic, luks2_header *out)
{
    memset(out, 0, sizeof(*out));

    uint8_t bin[L2_BIN_LEN];
    if (read_fn(ctx, bin, base, sizeof(bin)) != 0)
        return false;
    if (memcmp(bin, magic, LUKS_MAGIC_LEN) != 0)
        return false;
    if (rd16be(bin + L1_VERSION) != 2)
        return false;

    uint64_t hdr_size = rd64be(bin + L2_HDR_SIZE);
    if (hdr_size <= L2_BIN_LEN || hdr_size > L2_MAX_HDR)
        return false;

    size_t json_len = (size_t)(hdr_size - L2_BIN_LEN);
    char *json = malloc(json_len + 1);
    if (!json)
        return false;
    if (read_fn(ctx, json, base + L2_BIN_LEN, json_len) != 0) {
        free(json);
        return false;
    }
    json[json_len] = 0;

    char alg[33];
    memcpy(alg, bin + L2_CHECKSUM_ALG, 32);
    alg[32] = 0;
    crypto_hash hash = crypto_hash_by_name(alg);
    if (hash == CRYPTO_HASH_NONE || !luks2_checksum_ok(bin, json, json_len, hash)) {
        free(json);
        return false;
    }

    out->seqid    = rd64be(bin + L2_SEQID);
    out->hdr_size = hdr_size;
    out->json     = json;
    /*
     * The metadata area is a fixed size and the document does not fill it; the
     * remainder is zero padding. The checksum above covers the whole area,
     * padding included, but the parser must stop at the document -- a NUL is
     * not JSON, and treating it as the start of a value is how a perfectly
     * good header gets rejected as unreadable.
     */
    out->json_len = strnlen(json, json_len);
    memcpy(out->uuid, bin + L2_UUID, LUKS_UUID_LEN);
    out->uuid[LUKS_UUID_LEN] = 0;
    return true;
}

/* The newer of the two copies that still passes its own checksum. */
static bool luks2_load(void *ctx, ext4b_read_fn read_fn, luks2_header *out)
{
    luks2_header primary = {0}, secondary = {0};
    bool have_primary = luks2_read_copy(ctx, read_fn, 0,
                                        (const char *)LUKS_MAGIC, &primary);

    bool have_secondary = false;
    if (have_primary) {
        have_secondary = luks2_read_copy(ctx, read_fn, primary.hdr_size,
                                         L2_MAGIC_SECONDARY, &secondary);
    } else {
        /* Without a readable primary its size is unknown, so try the usual
         * one. A header that has moved and lost its primary is beyond us. */
        have_secondary = luks2_read_copy(ctx, read_fn, 16384,
                                         L2_MAGIC_SECONDARY, &secondary);
    }

    if (have_primary && have_secondary) {
        if (secondary.seqid > primary.seqid) {
            luks2_header_free(&primary);
            *out = secondary;
        } else {
            luks2_header_free(&secondary);
            *out = primary;
        }
        return true;
    }
    if (have_primary)   { *out = primary;   return true; }
    if (have_secondary) { *out = secondary; return true; }
    return false;
}

/* "aes-xts-plain64" -> cipher "aes", mode "xts-plain64" */
static bool split_encryption(const char *spec, char *cipher, size_t cipher_len,
                             char *mode, size_t mode_len)
{
    const char *dash = strchr(spec, '-');
    if (!dash)
        return false;
    size_t n = (size_t)(dash - spec);
    if (n >= cipher_len || strlen(dash + 1) >= mode_len)
        return false;
    memcpy(cipher, spec, n);
    cipher[n] = 0;
    snprintf(mode, mode_len, "%s", dash + 1);
    return true;
}

/* Index of the n-th key in an object; values are stepped over wholesale. */
static int json_object_key_at(const json_tok *t, int count, int obj, int n)
{
    if (obj < 0 || obj >= count || t[obj].type != JSON_OBJECT)
        return -1;
    const int limit = t[obj].end;
    int i = obj + 1;
    for (int m = 0; i < count && t[i].start < limit; m++) {
        if (m == n)
            return i;
        i = json_skip(t, count, json_skip(t, count, i));
    }
    return -1;
}

static luks_status probe_luks2(void *ctx, ext4b_read_fn read_fn, luks_info *out)
{
    out->version = 2;

    luks2_header hdr;
    if (!luks2_load(ctx, read_fn, &hdr)) {
        snprintf(out->unsupported, sizeof(out->unsupported),
                 "neither copy of the LUKS2 header passed its checksum");
        return LUKS_CORRUPT;
    }
    snprintf(out->uuid, sizeof(out->uuid), "%s", hdr.uuid);

    json_tok *toks = calloc(L2_MAX_TOKENS, sizeof(*toks));
    if (!toks) { luks2_header_free(&hdr); return LUKS_IO; }

    luks_status status = LUKS_CORRUPT;
    int n = json_parse(hdr.json, hdr.json_len, toks, L2_MAX_TOKENS);
    if (n <= 0) {
        snprintf(out->unsupported, sizeof(out->unsupported),
                 "the LUKS2 metadata is not readable JSON");
        goto done;
    }

    int segments = json_object_get(hdr.json, toks, n, 0, "segments");
    int seg_key  = json_object_key_at(toks, n, segments, 0);
    int seg      = (seg_key >= 0) ? json_skip(toks, n, seg_key) : -1;
    if (seg < 0) {
        snprintf(out->unsupported, sizeof(out->unsupported),
                 "the LUKS2 metadata declares no data segment");
        goto done;
    }

    int type = json_object_get(hdr.json, toks, n, seg, "type");
    if (!json_equals(hdr.json, toks, n, type, "crypt")) {
        char got[32] = "?";
        json_copy(hdr.json, toks, n, type, got, sizeof(got));
        snprintf(out->unsupported, sizeof(out->unsupported),
                 "segment type \"%s\" (only \"crypt\" is implemented)", got);
        status = LUKS_UNSUPPORTED;
        goto done;
    }

    uint64_t offset = 0, sector = 512, tweak = 0;
    char enc[64] = {0};
    if (!json_get_u64(hdr.json, toks, n, json_object_get(hdr.json, toks, n, seg, "offset"), &offset) ||
        !json_copy(hdr.json, toks, n, json_object_get(hdr.json, toks, n, seg, "encryption"), enc, sizeof(enc))) {
        snprintf(out->unsupported, sizeof(out->unsupported),
                 "the LUKS2 data segment is missing its offset or cipher");
        goto done;
    }
    /* sector_size and iv_tweak are optional; the defaults are the common case. */
    json_get_u64(hdr.json, toks, n, json_object_get(hdr.json, toks, n, seg, "sector_size"), &sector);
    json_get_u64(hdr.json, toks, n, json_object_get(hdr.json, toks, n, seg, "iv_tweak"), &tweak);

    if (tweak != 0) {
        snprintf(out->unsupported, sizeof(out->unsupported),
                 "a non-zero iv_tweak (%llu) is not implemented",
                 (unsigned long long)tweak);
        status = LUKS_UNSUPPORTED;
        goto done;
    }
    if (sector == 0 || (sector % 512) != 0 || sector > 65536) {
        snprintf(out->unsupported, sizeof(out->unsupported),
                 "sector size %llu", (unsigned long long)sector);
        status = LUKS_UNSUPPORTED;
        goto done;
    }

    if (!split_encryption(enc, out->cipher, sizeof(out->cipher),
                          out->mode, sizeof(out->mode))) {
        snprintf(out->unsupported, sizeof(out->unsupported),
                 "cipher specification \"%s\"", enc);
        status = LUKS_UNSUPPORTED;
        goto done;
    }

    /* The master key length lives on the key slots, not the segment. */
    int keyslots = json_object_get(hdr.json, toks, n, 0, "keyslots");
    int ks_key   = json_object_key_at(toks, n, keyslots, 0);
    int ks       = (ks_key >= 0) ? json_skip(toks, n, ks_key) : -1;
    uint64_t key_size = 0;
    if (ks < 0 ||
        !json_get_u64(hdr.json, toks, n, json_object_get(hdr.json, toks, n, ks, "key_size"), &key_size)) {
        snprintf(out->unsupported, sizeof(out->unsupported),
                 "the LUKS2 metadata declares no usable key slot");
        goto done;
    }
    /* Bound before the 32-bit cast: 0x100000020 would truncate to 32 and sail
     * through supported_cipher's key-length check while meaning something else
     * entirely. */
    if (key_size == 0 || key_size > LUKS_MAX_MASTER_KEY) {
        snprintf(out->unsupported, sizeof(out->unsupported),
                 "master key length %llu out of range",
                 (unsigned long long)key_size);
        goto done;
    }

    out->payload_offset = offset;
    out->sector_size    = (uint32_t)sector;
    out->key_bytes      = (uint32_t)key_size;
    /* LUKS2 names the digest hash per-digest rather than in the header; the
     * unlock path reads it from there. Nothing above needs it. */
    snprintf(out->hash, sizeof(out->hash), "sha256");

    status = supported_cipher(out) ? LUKS_OK : LUKS_UNSUPPORTED;

done:
    free(toks);
    luks2_header_free(&hdr);
    return status;
}

/* ---------------------------------------------------------------- unlock -- */

static void read_slot(const uint8_t *hdr, unsigned i, luks1_slot *slot)
{
    const uint8_t *p = hdr + L1_KEY_SLOTS + i * L1_SLOT_SIZE;
    slot->active     = rd32be(p);
    slot->iterations = rd32be(p + 4);
    memcpy(slot->salt, p + 8, L1_SALT_LEN);
    slot->key_material_offset = rd32be(p + 40);
    slot->stripes             = rd32be(p + 44);
}

/*
 * Decrypt a run of sectors in place, numbering them from `first_sector`.
 *
 * `iv_scale` is how many tweak units one sector spans -- 1 when the sector and
 * the tweak unit agree, 8 for a 4096-byte sector, because dm-crypt keeps
 * counting the tweak in 512-byte units regardless of sector size. It must
 * multiply the *absolute* sector index, not be folded into the starting value:
 * scaling only the start advances the tweak one unit per sector instead of
 * eight, which decrypts sector zero correctly and everything after it to
 * garbage.
 */
static int decrypt_run(const aes_xts_key *key, uint8_t *buf, size_t len,
                       uint32_t sector_size, uint64_t first_sector,
                       uint32_t iv_scale)
{
    for (size_t off = 0; off < len; off += sector_size) {
        size_t chunk = len - off < sector_size ? len - off : sector_size;
        uint8_t tweak[16];
        aes_xts_plain64_tweak((first_sector + off / sector_size) * iv_scale, tweak);
        int r = aes_xts_crypt_sector(key, false, tweak, buf + off, chunk);
        if (r != 0)
            return r;
    }
    return 0;
}

/* Does this candidate master key match the digest in the header? */
static bool digest_matches(const uint8_t *hdr, crypto_hash hash,
                           const uint8_t *mk, size_t mk_len)
{
    uint8_t want[L1_DIGEST_LEN];
    memcpy(want, hdr + L1_MK_DIGEST, L1_DIGEST_LEN);

    uint32_t iter = rd32be(hdr + L1_MK_DIGEST_ITER);
    if (iter == 0 || iter > LUKS_MAX_PBKDF2_ITER)
        return false;

    uint8_t got[L1_DIGEST_LEN];
    if (crypto_pbkdf2(hash, mk, mk_len,
                      hdr + L1_MK_DIGEST_SALT, L1_SALT_LEN,
                      iter, got, sizeof(got)) != 0)
        return false;

    /* Constant time: this runs once per slot and leaks nothing worth having,
     * but comparing secrets with memcmp is a habit not worth forming. */
    uint8_t diff = 0;
    for (size_t i = 0; i < L1_DIGEST_LEN; i++)
        diff |= (uint8_t)(want[i] ^ got[i]);
    return diff == 0;
}

static luks_status try_slot(void *ctx, ext4b_read_fn read_fn,
                            const uint8_t *hdr, const luks_info *info,
                            const luks1_slot *slot, crypto_hash hash,
                            const uint8_t *passphrase, size_t passphrase_len,
                            uint8_t *master_key)
{
    if (slot->stripes == 0 || slot->stripes > 8192)
        return LUKS_CORRUPT;
    if (slot->iterations == 0 || slot->iterations > LUKS_MAX_PBKDF2_ITER)
        return LUKS_CORRUPT;

    const size_t key_bytes = info->key_bytes;
    const size_t material_len = (size_t)slot->stripes * key_bytes;

    uint8_t *material = malloc(material_len);
    if (!material)
        return LUKS_IO;

    luks_status status = LUKS_BAD_PASSPHRASE;
    aes_xts_key *slot_key = NULL;
    uint8_t derived[LUKS_MAX_MASTER_KEY];

    /* The passphrase stretches into a key of exactly the master key's size,
     * which is then used to decrypt the slot's key material. */
    if (crypto_pbkdf2(hash, passphrase, passphrase_len,
                      slot->salt, L1_SALT_LEN, slot->iterations,
                      derived, key_bytes) != 0) {
        status = LUKS_IO;
        goto out;
    }

    if (read_fn(ctx, material,
                (uint64_t)slot->key_material_offset * L1_SECTOR,
                material_len) != 0) {
        status = LUKS_IO;
        goto out;
    }

    slot_key = aes_xts_key_create(derived, key_bytes);
    if (!slot_key) {
        status = LUKS_UNSUPPORTED;
        goto out;
    }

    /* Key material is numbered from sector 0 of its own area, not of the
     * container. */
    if (decrypt_run(slot_key, material, material_len, L1_SECTOR, 0, 1) != 0) {
        status = LUKS_IO;
        goto out;
    }

    if (af_merge(material, key_bytes, slot->stripes, hash, master_key) != 0) {
        status = LUKS_IO;
        goto out;
    }

    status = digest_matches(hdr, hash, master_key, key_bytes)
           ? LUKS_OK : LUKS_BAD_PASSPHRASE;

out:
    if (status != LUKS_OK)
        /* The whole buffer, not just key_bytes: on failure the caller must be
         * left nothing, and the LUKS2 path already wipes the full width. */
        memset_s(master_key, LUKS_MAX_MASTER_KEY, 0, LUKS_MAX_MASTER_KEY);
    memset_s(derived, sizeof(derived), 0, sizeof(derived));
    memset_s(material, material_len, 0, material_len);
    free(material);
    aes_xts_key_destroy(slot_key);
    return status;
}

/* --------------------------------------------------------- LUKS2 unlock -- */

/*
 * Stretch the passphrase into the key that protects one key slot's area.
 *
 * LUKS2 names the KDF and its cost in the header, so these are not our choices
 * to make -- they are whatever cryptsetup was told when the slot was written.
 * Argon2id at cryptsetup's defaults asks for a gigabyte of memory, which is
 * the reason this work is worth doing somewhere that can afford it rather than
 * inside a sandboxed extension.
 */
static int derive_slot_key(const char *js, const json_tok *t, int n, int kdf,
                           const uint8_t *pass, size_t pass_len,
                           uint8_t *out, size_t out_len)
{
    if (kdf < 0)
        return EINVAL;

    char type[32] = {0}, salt_b64[512] = {0};
    if (!json_copy(js, t, n, json_object_get(js, t, n, kdf, "type"), type, sizeof(type)))
        return EINVAL;
    if (!json_copy(js, t, n, json_object_get(js, t, n, kdf, "salt"), salt_b64, sizeof(salt_b64)))
        return EINVAL;

    uint8_t salt[256];
    int salt_len = base64_decode(salt_b64, strlen(salt_b64), salt, sizeof(salt));
    if (salt_len <= 0)
        return EINVAL;

    int rc = ENOTSUP;

    if (strcmp(type, "pbkdf2") == 0) {
        char hname[32] = {0};
        uint64_t iterations = 0;
        if (json_copy(js, t, n, json_object_get(js, t, n, kdf, "hash"), hname, sizeof(hname)) &&
            json_get_u64(js, t, n, json_object_get(js, t, n, kdf, "iterations"), &iterations) &&
            iterations > 0 && iterations <= LUKS_MAX_PBKDF2_ITER) {
            rc = crypto_pbkdf2(crypto_hash_by_name(hname), pass, pass_len,
                               salt, (size_t)salt_len, (uint32_t)iterations,
                               out, out_len);
        } else {
            rc = EINVAL;
        }
    } else if (strcmp(type, "argon2i") == 0 || strcmp(type, "argon2id") == 0) {
        uint64_t time = 0, memory = 0, cpus = 1;
        json_get_u64(js, t, n, json_object_get(js, t, n, kdf, "time"), &time);
        json_get_u64(js, t, n, json_object_get(js, t, n, kdf, "memory"), &memory);
        json_get_u64(js, t, n, json_object_get(js, t, n, kdf, "cpus"), &cpus);

        /* Bounds before allocating: `memory` is attacker-controlled and is in
         * KiB, so an unchecked value is a request to allocate terabytes. 4 GiB
         * is already far past anything cryptsetup writes. */
        if (time == 0 || time > 1024 ||
            memory < 8 || memory > (4ull << 20) ||
            cpus == 0 || cpus > 64)
            return EINVAL;

        /* Individually bounded is not enough: 1024 passes over 4 GiB is a
         * multi-hour, 4 GB-resident derivation from header data alone. Cap the
         * product (time x memory, in KiB-passes) so the two cannot be
         * multiplied into a denial of service. 128 Mi is ~30x cryptsetup's
         * default and still finishes in seconds. */
        if ((uint64_t)time * memory > (128ull << 20))
            return EINVAL;

        argon2_type at = (strcmp(type, "argon2id") == 0) ? Argon2_id : Argon2_i;
        int a = argon2_hash((uint32_t)time, (uint32_t)memory, (uint32_t)cpus,
                            pass, pass_len, salt, (size_t)salt_len,
                            out, out_len, NULL, 0, at, ARGON2_VERSION_13);
        rc = (a == ARGON2_OK) ? 0 : EIO;
    }

    memset_s(salt, sizeof(salt), 0, sizeof(salt));
    return rc;
}

/*
 * Does this candidate master key satisfy a digest that covers `slot_id`?
 *
 * LUKS2 keeps digests separately from key slots and links them by id, so the
 * digest to check against is the one that lists this slot -- not simply the
 * first one.
 */
static bool luks2_digest_ok(const char *js, const json_tok *t, int n,
                            int digests, const char *slot_id,
                            const uint8_t *mk, size_t mk_len)
{
    int count = json_object_count(t, n, digests);
    for (int i = 0; i < count; i++) {
        int key = json_object_key_at(t, n, digests, i);
        int d   = json_skip(t, n, key);
        if (d < 0 || d >= n)
            continue;

        int slots = json_object_get(js, t, n, d, "keyslots");
        bool covers = false;
        for (int e = 0; ; e++) {
            int el = json_array_get(js, t, n, slots, e);
            if (el < 0)
                break;
            if (json_equals(js, t, n, el, slot_id)) { covers = true; break; }
        }
        if (!covers)
            continue;

        char type[32] = {0}, hname[32] = {0};
        char salt_b64[512] = {0}, dig_b64[512] = {0};
        uint64_t iterations = 0;
        if (!json_copy(js, t, n, json_object_get(js, t, n, d, "type"), type, sizeof(type)) ||
            strcmp(type, "pbkdf2") != 0)
            continue;
        if (!json_copy(js, t, n, json_object_get(js, t, n, d, "hash"), hname, sizeof(hname)) ||
            !json_copy(js, t, n, json_object_get(js, t, n, d, "salt"), salt_b64, sizeof(salt_b64)) ||
            !json_copy(js, t, n, json_object_get(js, t, n, d, "digest"), dig_b64, sizeof(dig_b64)) ||
            !json_get_u64(js, t, n, json_object_get(js, t, n, d, "iterations"), &iterations) ||
            iterations == 0 || iterations > LUKS_MAX_PBKDF2_ITER)
            continue;

        uint8_t salt[256], want[128], got[128];
        int salt_len = base64_decode(salt_b64, strlen(salt_b64), salt, sizeof(salt));
        int want_len = base64_decode(dig_b64,  strlen(dig_b64),  want, sizeof(want));
        if (salt_len <= 0 || want_len <= 0)
            continue;

        int prc = crypto_pbkdf2(crypto_hash_by_name(hname), mk, mk_len,
                                salt, (size_t)salt_len, (uint32_t)iterations,
                                got, (size_t)want_len);

        uint8_t diff = (uint8_t)(prc != 0);   /* a failed derive never matches */
        for (int j = 0; j < want_len && prc == 0; j++)
            diff |= (uint8_t)(want[j] ^ got[j]);

        /* got is derived from the master key -- zero it on every path out of
         * this iteration, not only the matching one; the old code left it on
         * the stack whenever the derive failed. */
        memset_s(got, sizeof(got), 0, sizeof(got));
        if (prc == 0 && diff == 0)
            return true;
    }
    return false;
}

static luks_status try_luks2_slot(void *ctx, ext4b_read_fn read_fn,
                                  const char *js, const json_tok *t, int n,
                                  int ks, const char *slot_id, int digests,
                                  const uint8_t *pass, size_t pass_len,
                                  uint8_t *master_key, size_t *mk_len)
{
    char type[32] = {0};
    if (!json_copy(js, t, n, json_object_get(js, t, n, ks, "type"), type, sizeof(type)) ||
        strcmp(type, "luks2") != 0)
        return LUKS_BAD_PASSPHRASE;   /* a slot we do not handle is not an error */

    uint64_t key_size = 0;
    if (!json_get_u64(js, t, n, json_object_get(js, t, n, ks, "key_size"), &key_size) ||
        key_size == 0 || key_size > LUKS_MAX_MASTER_KEY)
        return LUKS_CORRUPT;

    int af = json_object_get(js, t, n, ks, "af");
    uint64_t stripes = 0;
    char af_hash[32] = {0};
    if (!json_get_u64(js, t, n, json_object_get(js, t, n, af, "stripes"), &stripes) ||
        !json_copy(js, t, n, json_object_get(js, t, n, af, "hash"), af_hash, sizeof(af_hash)) ||
        stripes == 0 || stripes > 8192)
        return LUKS_CORRUPT;

    int area = json_object_get(js, t, n, ks, "area");
    uint64_t area_off = 0, area_size = 0, area_key_size = key_size;
    char area_enc[64] = {0};
    if (!json_get_u64(js, t, n, json_object_get(js, t, n, area, "offset"), &area_off) ||
        !json_get_u64(js, t, n, json_object_get(js, t, n, area, "size"), &area_size) ||
        !json_copy(js, t, n, json_object_get(js, t, n, area, "encryption"), area_enc, sizeof(area_enc)))
        return LUKS_CORRUPT;
    json_get_u64(js, t, n, json_object_get(js, t, n, area, "key_size"), &area_key_size);

    /* The key material is stored with the same construction as the data, so
     * the same allow-list applies. */
    if (strcmp(area_enc, "aes-xts-plain64") != 0)
        return LUKS_UNSUPPORTED;
    if (area_key_size != 32 && area_key_size != 64)
        return LUKS_UNSUPPORTED;

    size_t material_len = (size_t)stripes * (size_t)key_size;
    if (material_len > area_size)
        return LUKS_CORRUPT;

    crypto_hash hash = crypto_hash_by_name(af_hash);
    if (hash == CRYPTO_HASH_NONE)
        return LUKS_UNSUPPORTED;

    uint8_t  slot_key[LUKS_MAX_MASTER_KEY];
    uint8_t *material = malloc(material_len);
    aes_xts_key *xts  = NULL;
    luks_status status = LUKS_BAD_PASSPHRASE;

    if (!material)
        return LUKS_IO;

    if (derive_slot_key(js, t, n, json_object_get(js, t, n, ks, "kdf"),
                        pass, pass_len, slot_key, (size_t)area_key_size) != 0) {
        status = LUKS_UNSUPPORTED;
        goto out;
    }

    if (read_fn(ctx, material, area_off, material_len) != 0) {
        status = LUKS_IO;
        goto out;
    }

    xts = aes_xts_key_create(slot_key, (size_t)area_key_size);
    if (!xts) { status = LUKS_UNSUPPORTED; goto out; }

    /* Key material is always in 512-byte sectors numbered from its own start,
     * whatever the data segment uses. */
    if (decrypt_run(xts, material, material_len, L1_SECTOR, 0, 1) != 0) {
        status = LUKS_IO;
        goto out;
    }

    if (af_merge(material, (size_t)key_size, (unsigned)stripes, hash, master_key) != 0) {
        status = LUKS_IO;
        goto out;
    }

    if (luks2_digest_ok(js, t, n, digests, slot_id, master_key, (size_t)key_size)) {
        *mk_len = (size_t)key_size;
        status = LUKS_OK;
    }

out:
    if (status != LUKS_OK)
        memset_s(master_key, LUKS_MAX_MASTER_KEY, 0, LUKS_MAX_MASTER_KEY);
    memset_s(slot_key, sizeof(slot_key), 0, sizeof(slot_key));
    memset_s(material, material_len, 0, material_len);
    free(material);
    aes_xts_key_destroy(xts);
    return status;
}

static luks_status unlock_luks2(void *ctx, ext4b_read_fn read_fn,
                                const uint8_t *pass, size_t pass_len,
                                uint8_t *master_key, size_t *mk_len)
{
    luks2_header hdr;
    if (!luks2_load(ctx, read_fn, &hdr))
        return LUKS_CORRUPT;

    json_tok *toks = calloc(L2_MAX_TOKENS, sizeof(*toks));
    if (!toks) { luks2_header_free(&hdr); return LUKS_IO; }

    luks_status status = LUKS_CORRUPT;
    int n = json_parse(hdr.json, hdr.json_len, toks, L2_MAX_TOKENS);
    if (n <= 0)
        goto done;

    int keyslots = json_object_get(hdr.json, toks, n, 0, "keyslots");
    int digests  = json_object_get(hdr.json, toks, n, 0, "digests");
    if (keyslots < 0 || digests < 0)
        goto done;

    status = LUKS_BAD_PASSPHRASE;
    int slots = json_object_count(toks, n, keyslots);
    for (int i = 0; i < slots; i++) {
        int key = json_object_key_at(toks, n, keyslots, i);
        char slot_id[24] = {0};
        if (!json_copy(hdr.json, toks, n, key, slot_id, sizeof(slot_id)))
            continue;

        int ks = json_skip(toks, n, key);
        luks_status s = try_luks2_slot(ctx, read_fn, hdr.json, toks, n,
                                       ks, slot_id, digests,
                                       pass, pass_len, master_key, mk_len);
        if (s == LUKS_OK) { status = LUKS_OK; break; }
        if (s != LUKS_BAD_PASSPHRASE)
            status = s;
    }

done:
    free(toks);
    luks2_header_free(&hdr);
    return status;
}

luks_status luks_unlock(void *ctx, ext4b_read_fn read_fn,
                        const luks_info *info,
                        const uint8_t *passphrase, size_t passphrase_len,
                        uint8_t *master_key, size_t *mk_len)
{
    if (!read_fn || !info || !master_key || !mk_len)
        return LUKS_CORRUPT;
    if (info->version == 2)
        return unlock_luks2(ctx, read_fn, passphrase, passphrase_len,
                            master_key, mk_len);
    if (info->version != 1)
        return LUKS_UNSUPPORTED;

    crypto_hash hash = crypto_hash_by_name(info->hash);
    if (hash == CRYPTO_HASH_NONE)
        return LUKS_UNSUPPORTED;

    uint8_t hdr[L1_HEADER_LEN];
    if (read_fn(ctx, hdr, 0, sizeof(hdr)) != 0)
        return LUKS_IO;
    if (memcmp(hdr, LUKS_MAGIC, LUKS_MAGIC_LEN) != 0)
        return LUKS_NOT_LUKS;

    /* Any slot may hold the passphrase, so all of them are tried. A disabled
     * slot is skipped rather than attempted, which also keeps the cost of a
     * wrong passphrase proportional to the slots actually in use. */
    luks_status last = LUKS_BAD_PASSPHRASE;
    for (unsigned i = 0; i < L1_NUM_SLOTS; i++) {
        luks1_slot slot;
        read_slot(hdr, i, &slot);
        if (slot.active != L1_SLOT_ENABLED)
            continue;

        luks_status s = try_slot(ctx, read_fn, hdr, info, &slot, hash,
                                 passphrase, passphrase_len, master_key);
        if (s == LUKS_OK) {
            *mk_len = info->key_bytes;
            return LUKS_OK;
        }
        if (s != LUKS_BAD_PASSPHRASE)
            last = s;
    }
    return last;
}

/* ---------------------------------------------------------------- device -- */

struct luks_device {
    void           *ctx;
    ext4b_read_fn   read_fn;
    ext4b_write_fn  write_fn;
    ext4b_flush_fn  flush_fn;

    aes_xts_key    *key;
    uint64_t        payload_offset;
    uint32_t        sector_size;
    /*
     * How many tweak units one encryption sector spans.
     *
     * dm-crypt numbers the XTS tweak in 512-byte units even when the
     * encryption sector is larger. Getting this wrong is not a loud failure:
     * sector 0 decrypts correctly either way -- its tweak is zero in both
     * conventions -- so the superblock reads, the label looks right, and every
     * other byte on the volume is garbage.
     */
    uint32_t        iv_scale;
};

luks_device *luks_device_open(void *ctx,
                              ext4b_read_fn read_fn,
                              ext4b_write_fn write_fn,
                              ext4b_flush_fn flush_fn,
                              const luks_info *info,
                              const uint8_t *master_key, size_t mk_len)
{
    if (!read_fn || !info || !master_key)
        return NULL;
    if (info->sector_size == 0 || (info->sector_size % 512) != 0)
        return NULL;

    luks_device *d = calloc(1, sizeof(*d));
    if (!d)
        return NULL;

    d->key = aes_xts_key_create(master_key, mk_len);
    if (!d->key) {
        free(d);
        return NULL;
    }

    d->ctx            = ctx;
    d->read_fn        = read_fn;
    d->write_fn       = write_fn;
    d->flush_fn       = flush_fn;
    d->payload_offset = info->payload_offset;
    d->sector_size    = info->sector_size;
    d->iv_scale       = info->sector_size / 512;
    return d;
}

void luks_device_close(luks_device *d)
{
    if (!d)
        return;
    aes_xts_key_destroy(d->key);
    memset_s(d, sizeof(*d), 0, sizeof(*d));
    free(d);
}

uint64_t luks_payload_size(const luks_device *d, uint64_t container_size)
{
    if (!d || container_size <= d->payload_offset)
        return 0;
    uint64_t avail = container_size - d->payload_offset;
    return avail - (avail % d->sector_size);
}

/*
 * lwext4 does not read in whole sectors -- the very first thing it does is
 * fetch the 1024-byte superblock at offset 1024 -- but the cipher only works
 * in whole sectors. Requests are therefore widened to sector boundaries and
 * the caller's slice copied out, the same shape as the alignment window in
 * BlockDeviceBridge.
 */
int luks_device_read(void *ctx, void *buf, uint64_t offset, size_t count)
{
    luks_device *d = ctx;
    if (!d || !buf)
        return EINVAL;
    if (count == 0)
        return 0;

    const uint32_t ss = d->sector_size;
    uint64_t first = offset / ss;
    uint64_t last  = (offset + count - 1) / ss;
    size_t   span  = (size_t)(last - first + 1) * ss;

    uint8_t *window = malloc(span);
    if (!window)
        return ENOMEM;

    int r = d->read_fn(d->ctx, window, d->payload_offset + first * ss, span);
    if (r == 0)
        r = decrypt_run(d->key, window, span, ss, first, d->iv_scale);
    if (r == 0)
        memcpy(buf, window + (offset - first * ss), count);

    memset_s(window, span, 0, span);
    free(window);
    return r;
}

int luks_device_write(void *ctx, const void *buf, uint64_t offset, size_t count)
{
    luks_device *d = ctx;
    if (!d || !buf)
        return EINVAL;
    if (!d->write_fn)
        return EROFS;
    if (count == 0)
        return 0;

    const uint32_t ss = d->sector_size;
    uint64_t first = offset / ss;
    uint64_t last  = (offset + count - 1) / ss;
    size_t   span  = (size_t)(last - first + 1) * ss;
    size_t   shift = (size_t)(offset - first * ss);

    uint8_t *window = malloc(span);
    if (!window)
        return ENOMEM;

    int r = 0;
    /* A partial sector has to be read and decrypted first: the bytes we are
     * not changing still have to re-encrypt to what they were. */
    if (shift != 0 || count != span) {
        r = d->read_fn(d->ctx, window, d->payload_offset + first * ss, span);
        if (r == 0)
            r = decrypt_run(d->key, window, span, ss, first, d->iv_scale);
        if (r != 0)
            goto out;
    }

    memcpy(window + shift, buf, count);

    for (size_t off = 0; off < span; off += ss) {
        uint8_t tweak[16];
        aes_xts_plain64_tweak((first + off / ss) * d->iv_scale, tweak);
        r = aes_xts_crypt_sector(d->key, true, tweak, window + off, ss);
        if (r != 0)
            goto out;
    }

    r = d->write_fn(d->ctx, window, d->payload_offset + first * ss, span);

out:
    memset_s(window, span, 0, span);
    free(window);
    return r;
}

int luks_device_flush(void *ctx)
{
    luks_device *d = ctx;
    if (!d)
        return EINVAL;
    return d->flush_fn ? d->flush_fn(d->ctx) : 0;
}
