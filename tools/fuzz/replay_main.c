/*
 * The fuzz harness without libFuzzer: feed it files, one after another, in
 * one process.
 *
 *   EXT4_FUZZ_MODE=both build/bin/ext4_replay a.img b.img ...
 *
 * libFuzzer is only needed to *generate* inputs. Replaying them needs the
 * harness and nothing else, and building it without libFuzzer means it builds
 * in every configuration this repository has -- CONFIG=debug gives it ASan and
 * UBSan with no Homebrew LLVM -- so the hostile fixtures can go through the
 * same read-only and read-write scripts the fuzzer runs, in CI, on every push.
 * ext4dump drives each fixture through a handful of verbs; the harness drives
 * the whole script, which is how the nightly found what ext4dump never asked.
 *
 * One process on purpose. The harness requires every input to leave lwext4's
 * global tables as it found them, and a leak between inputs is only visible
 * to an input that comes after. Each file's name is printed before it runs,
 * so an abort names the input that caused it.
 *
 * Exit 0 when every file ran; anything else is the abort of the one named
 * last.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

int LLVMFuzzerInitialize(int *argc, char ***argv);
int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size);

/* The harness's custom mutator falls back to libFuzzer's own. Replay never
 * mutates, so this is only here to satisfy the link. */
size_t LLVMFuzzerMutate(uint8_t *data, size_t size, size_t max_size)
{
    (void)data;
    (void)max_size;
    return size;
}

static uint8_t *slurp(const char *path, size_t *len)
{
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    uint8_t *buf = NULL;
    size_t cap = 0, n = 0;
    for (;;) {
        if (n == cap) {
            cap = cap ? cap * 2 : (1u << 20);
            uint8_t *next = realloc(buf, cap);
            if (!next) { free(buf); fclose(f); return NULL; }
            buf = next;
        }
        size_t got = fread(buf + n, 1, cap - n, f);
        n += got;
        if (got == 0) break;
    }
    fclose(f);
    *len = n;
    return buf;
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: EXT4_FUZZ_MODE=ro|rw|both ext4_replay FILE...\n");
        return 2;
    }
    /* No self-test: that needs the seed corpus, and a replay is given its
     * inputs explicitly. */
    LLVMFuzzerInitialize(NULL, NULL);

    for (int i = 1; i < argc; i++) {
        size_t len = 0;
        uint8_t *data = slurp(argv[i], &len);
        if (!data) {
            fprintf(stderr, "ext4_replay: cannot read %s\n", argv[i]);
            return 1;
        }
        fprintf(stderr, "ext4_replay: %s (%zu bytes)\n", argv[i], len);
        LLVMFuzzerTestOneInput(data, len);
        free(data);
    }
    return 0;
}
