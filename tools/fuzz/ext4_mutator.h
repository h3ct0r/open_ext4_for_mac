/*
 * ext4_mutator.h — structure-aware mutation of an ext4 image in memory.
 *
 * The point of aiming. A byte-at-a-time mutator spends its budget on the
 * 99.9% of a filesystem image that is file data and unallocated space, and
 * the few edits that do land on metadata are refused by a checksum before
 * anything parses them. This picks a structure, changes a field in it to a
 * value chosen to break arithmetic, and re-stamps the checksums that would
 * otherwise refuse it -- so the edit reaches the code that reads the field.
 *
 * It re-stamps most of the time, not all of the time: the checksum gate is
 * code too, and a mutant that fails it exercises the refusal path.
 */
#ifndef EXT4_FUZZ_MUTATOR_H
#define EXT4_FUZZ_MUTATOR_H

#include <stdint.h>
#include <stddef.h>

/* Loads tools/fuzz/mutweights.json if it can be found; falls back to the
 * compiled-in weights, saying so. Safe to call more than once. */
void ext4_mutator_init(void);

/* Mutate in place. Returns the new size (which may differ: one strategy
 * truncates or extends by a block). Never returns more than max_size. */
size_t ext4_mutate(uint8_t *data, size_t size, size_t max_size, unsigned seed);

/* Splice two images at block granularity, then re-stamp the superblock. */
size_t ext4_crossover(const uint8_t *a, size_t alen,
                      const uint8_t *b, size_t blen,
                      uint8_t *out, size_t max_out, unsigned seed);

/* Names, in the order the weights table lists them. For -print stats. */
const char *ext4_mutator_strategy_name(int i);
int         ext4_mutator_strategy_count(void);
void        ext4_mutator_dump_counts(void);

#endif /* EXT4_FUZZ_MUTATOR_H */
