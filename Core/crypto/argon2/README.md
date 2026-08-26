# Argon2 — vendored, unmodified

The reference implementation from
[P-H-C/phc-winner-argon2](https://github.com/P-H-C/phc-winner-argon2),
release **20190702**, dual-licensed CC0-1.0 / Apache-2.0 (see `LICENSE`). Both
are compatible with this project's GPL-3.0.

## Why it is here

LUKS2 derives its key-slot keys with Argon2id, and macOS ships nothing that can
do it. CommonCrypto has PBKDF2 and no more. `libsodium` has Argon2id but fixes
the parallelism at one lane, and `cryptsetup` writes four by default — so it
cannot derive the keys for an ordinary LUKS2 header.

Writing this by hand was the alternative, and was rejected. A subtle error here
does not corrupt anything — a wrong key fails the header's own digest check and
reports a bad passphrase — but it would make correct passphrases silently
unusable, and "our own Argon2" is not a sentence worth writing when the
reference implementation is public domain.

## What was taken

Only what is needed to compute a raw hash:

    argon2.h  argon2.c  core.c/.h  ref.c  thread.c/.h  encoding.c/.h
    blake2/

Left behind: `opt.c` (SSE/AVX intrinsics, x86-only — `ref.c` is the portable
path and the one that matters on Apple Silicon), and the CLI, tests, benchmarks
and documentation.

`encoding.c` is kept only because `argon2.c` references it; the encoded
`$argon2id$...` string form is not used here. LUKS stores its parameters in its
own header.

**The sources are unmodified.** If they ever need patching, do it the way
`patches/lwext4/` does — as a recorded patch against pristine upstream, not an
edit in place, so the next update is a merge rather than an archaeology
exercise.

## Updating

    brew fetch --build-from-source argon2
    tar xf "$(brew --cache --build-from-source argon2)" --strip-components=1
