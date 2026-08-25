# open_ext4_for_mac

A native, open-source **ext2/ext3/ext4** read-write filesystem driver for macOS,
built on Apple's **FSKit**.

No kernel extension. No FUSE. No SIP changes. No proprietary binaries.
Volumes mount in Finder and behave like any other native disk.

## Status

**Reads and writes.** ext2/3/4 volumes mount natively through FSKit:

```
/dev/disk5 on /private/tmp/ext4mnt (ext4, local, nodev, nosuid, journaled,
                                    noowners, noatime, fskit, mounted by h3ct0r)
```

Through a real mount: nested `mkdir`, create and write, multi-MB files, `cp`,
symlinks, hard links, rename, `rm`, `rmdir`, extended attributes, and a clean
unmount that closes the journal. Volumes written entirely on macOS are read
back byte-for-byte by the real Linux kernel, with nothing in its log.

Validation runs unattended in about two minutes:

```bash
make validate
```

| Stage | Coverage |
|---|---|
| read suite | 41 assertions, verified against `debugfs` |
| write suite | 82 assertions, `e2fsck` after **every** mutating operation |
| crash consistency | 256 cut points; the Linux kernel replays each journal |
| differential vs Linux | 28 assertions, both directions |
| mounted driver | 15 assertions against a live FSKit mount |

Testing found six genuine bugs in lwext4 — including one that replayed stale
journal records over live metadata, and one that hung the driver forever
instead of failing — plus several of our own. See
[docs/STATUS.md](docs/STATUS.md) and
[patches/lwext4/README.md](patches/lwext4/README.md).

> **Still young.** It is tested hard, but it has not been run by anyone but its
> author, and two limitations are worth knowing before you point it at data you
> care about: FSKit exposes no write barrier that works here, and it gives the
> module no way to see `-o ro`, so a healthy volume always mounts read-write.
> Both are documented in [docs/STATUS.md](docs/STATUS.md). Keep a backup.

## Requirements

- macOS 15.4 or later (developed and tested on macOS 26)
- Apple Silicon or Intel
- Xcode Command Line Tools (full Xcode is **not** required)

## Building

```bash
git submodule update --init
make            # build Ext4Mac.app with the FSKit extension inside
make test       # read + write suites (needs: brew install e2fsprogs)
make validate   # everything, including the Linux-kernel stages (needs Docker)
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

See `LICENSE`.
