# open_ext4_for_mac

A native, open-source **ext2/ext3/ext4** read-write filesystem driver for macOS,
built on Apple's **FSKit**.

No kernel extension. No FUSE. No SIP changes. No proprietary binaries.
Volumes mount in Finder and behave like any other native disk.

## Status

**Reads and writes, and mounts by itself.** Attach an ext2/3/4 disk and it
appears in Finder like any native volume:

```
/dev/disk6 on /Volumes/AUTOMOUNT (ext4, local, nodev, nosuid, journaled,
                                  noowners, noatime, fskit, mounted by h3ct0r)
```

Through a real mount: nested `mkdir`, create and write, multi-MB files, `cp`,
symlinks, hard links, rename, `rm`, `rmdir`, extended attributes, and a clean
unmount that closes the journal. Volumes written entirely on macOS are read
back byte-for-byte by the real Linux kernel, with nothing in its log.

It can also create and rename volumes. Formatting goes through the
module-agnostic driver macOS ships:

```bash
newfs_fskit -t ext4 -L MYDISK /dev/disk5      # ext4, or -g 2 / -g 3
sudo make install-diskutil                    # and appear in Disk Utility
```

Validation runs unattended in about two minutes:

```bash
make validate
```

| Stage | Coverage |
|---|---|
| read suite | 41 assertions, verified against `debugfs` |
| write suite | 101 assertions, `e2fsck` after **every** mutating operation |
| format | 29 assertions; 117 geometries, all `e2fsck`-clean |
| open-unlink recovery | 23 assertions; the orphan list, and torn ones |
| crypto primitives | 29 assertions; AES-XTS against OpenSSL, hostile JSON |
| LUKS containers | 27 assertions; judged by real `cryptsetup` |
| crash consistency | 303 cut points; the Linux kernel replays each journal |
| differential vs Linux | 36 assertions, both directions |
| mounted driver | 23 assertions against a live FSKit mount |
| encrypted, mounted | 32 assertions; a LUKS volume through FSKit, judged by Linux |

A file deleted while something still has it open goes on ext4's own **orphan
list**, so a crash in that window is recoverable by the next mount rather than
a leak — and `chattr +i` / `chattr +a` are honoured, reported to macOS as
`uchg` / `uappnd`.

**ext4 inside LUKS mounts**, LUKS1 and LUKS2 alike — the one thing macOS
otherwise cannot open at all, since `cryptsetup` needs device-mapper and
cannot be ported:

```bash
Ext4Mac unlock /dev/disk6            # prompts; derives the master key
mount -F -t ext4 disk6 /tmp/mnt      # immediate
Ext4Mac forget /dev/disk6            # locked again
```

The passphrase is typed into the app and never reaches the sandboxed
extension, which only ever sees a master key. Everything macOS writes to an
encrypted volume is handed back to real `cryptsetup` and the Linux kernel to
read; see [docs/STATUS.md](docs/STATUS.md).

Testing found eight genuine bugs in lwext4 — including one that replayed stale
journal records over live metadata, and one that hung the driver forever
instead of failing — plus several of our own. See
[docs/STATUS.md](docs/STATUS.md) and
[patches/lwext4/README.md](patches/lwext4/README.md).

> **Still young.** It is tested hard, but it has not been run by anyone but its
> author. One limitation is worth knowing before you point it at data you care
> about: FSKit exposes no write barrier that works here, so write ordering
> rests on an observation about this macOS version rather than a guarantee.
> `mount -o ro` is honoured properly if you want to look without touching —
> the volume is not written to at all. Both are documented in
> [docs/STATUS.md](docs/STATUS.md). Keep a backup.

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
