# open_ext4_for_mac

A native, open-source **ext2/ext3/ext4** filesystem driver for macOS on Apple Silicon,
built on Apple's **FSKit**.

No kernel extension. No FUSE. No SIP changes. No proprietary binaries.
Volumes mount in Finder and behave like any other native disk.

## Status

> **Under active development.** See `docs/STATUS.md` for the current phase.
>
> Write support is **disabled by default** and is gated behind a correctness suite
> (`e2fsck` oracle + crash-consistency sweeps). Do not point the write path at data
> you care about until that gate is green.

## Requirements

- macOS 15.4 or later (developed and tested on macOS 26)
- Apple Silicon or Intel
- Xcode Command Line Tools (full Xcode is **not** required)

## Building

```bash
git submodule update --init
make            # build Ext4Mac.app with the FSKit extension inside
make test       # run the correctness suite (needs: brew install e2fsprogs)
```

Loading the extension additionally requires a Developer ID certificate:

```bash
make sign SIGN_ID="Developer ID Application: Your Name (TEAMID)"
make install
```

See [docs/SIGNING.md](docs/SIGNING.md). The ext4 core is deliberately
decoupled from FSKit, so `make test` exercises the real filesystem code
against disk images with no Apple account, no signing and no mounting.

## Documentation

- [Architecture](docs/ARCHITECTURE.md) — how it fits together and why
- [Status](docs/STATUS.md) — what works today
- [Signing](docs/SIGNING.md) — certificates and entitlements

## Licence

**GPL-3.0-or-later.** This project vendors [lwext4](https://github.com/gkostka/lwext4),
whose `ext4_extent.c` and `ext4_xattr.c` are GPL-2.0-or-later; the remainder is
BSD-3-Clause. The combined work is therefore distributed under GPL-3.0-or-later.

See `LICENSE` and `docs/LICENSING.md`.
