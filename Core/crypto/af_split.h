//
//  af_split.h
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  The LUKS anti-forensic splitter.
//
//  A LUKS key slot does not store the master key directly. It stores the key
//  expanded across many stripes -- 4000 by default -- so that the on-disk
//  material is far larger than the key itself, and *every* stripe is needed to
//  recover it. The point is deletion: overwriting a key slot on media that
//  quietly relocates blocks (SSDs, most of them) may leave the old sectors
//  readable, and this makes a partial recovery worth nothing.
//
//  Only the merge direction is needed to open a volume. Splitting is what
//  cryptsetup does when it writes a slot, which this driver does not do.
//

#ifndef AF_SPLIT_H
#define AF_SPLIT_H

#include <stddef.h>
#include <stdint.h>

#include "crypto_hash.h"

#ifdef __cplusplus
extern "C" {
#endif

/// Recover `key_len` bytes from `stripes * key_len` bytes of slot material.
///
/// `src` must hold exactly `stripes * key_len` bytes and `out` must have room
/// for `key_len`. Returns 0, or an errno value.
int af_merge(const uint8_t *src, size_t key_len, unsigned stripes,
             crypto_hash hash, uint8_t *out);

#ifdef __cplusplus
}
#endif

#endif /* AF_SPLIT_H */
