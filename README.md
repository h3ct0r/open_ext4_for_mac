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
make            # build the extension bundle
make sign       # sign with your Developer ID (see docs/SIGNING.md)
make install    # install to /Applications
```

## Licence

**GPL-3.0-or-later.** This project vendors [lwext4](https://github.com/gkostka/lwext4),
whose `ext4_extent.c` and `ext4_xattr.c` are GPL-2.0-or-later; the remainder is
BSD-3-Clause. The combined work is therefore distributed under GPL-3.0-or-later.

See `LICENSE` and `docs/LICENSING.md`.
