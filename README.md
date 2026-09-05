# open_ext4_for_mac

[![ci](https://github.com/h3ct0r/open_ext4_for_mac/actions/workflows/ci.yml/badge.svg)](https://github.com/h3ct0r/open_ext4_for_mac/actions/workflows/ci.yml)
[![licence](https://img.shields.io/github/license/h3ct0r/open_ext4_for_mac)](LICENSE)
[![platform](https://img.shields.io/badge/macOS-15.4%2B%20%C2%B7%20Apple%20Silicon-black)](#three-things-to-know)

**Native ext2 / ext3 / ext4 for macOS, read and write, built on Apple's FSKit.**

No kernel extension, no FUSE, no SIP changes, no proprietary binaries. Plug in
a Linux disk and it appears in Finder like any other volume — encrypted LUKS
containers included, which macOS otherwise cannot open at all.

<!-- hero: docs/images/finder-mounted.png — Finder showing an ext4 volume
     mounted, with the menu-bar agent visible. Added with the first release. -->

```
/dev/disk6 on /Volumes/AUTOMOUNT (ext4, local, journaled, fskit, mounted by h3ct0r)
```

## Install

1. Download `Ext4Mac-x.y.z.dmg` from [Releases](https://github.com/h3ct0r/open_ext4_for_mac/releases)
   and drag **Ext4Mac** to `/Applications`. *(The first release is in
   preparation; until it is published, [build from source](#building-from-source).)*
2. Open Ext4Mac once. It registers the filesystem extension and asks you to
   approve it.
3. Approve it in **System Settings → General → Login Items & Extensions →
   File System Extensions**. macOS grants this by hand only; no app can do it.
4. Plug in an ext4 disk. It mounts. Encrypted ones ask for a passphrase from
   the menu bar.

The step-by-step with screenshots, and what to do when it looks broken but
is not, is in [docs/INSTALL.md](docs/INSTALL.md).

## What it does

| | |
|---|---|
| **ext2, ext3, ext4** | mount, read and write; volumes written on macOS read back byte-for-byte on Linux |
| **Journal** | replayed before any read-write mount; an unreplayed log is never written over |
| **LUKS1 and LUKS2** | `aes-xts-plain64`; PBKDF2 and Argon2; unlock from the menu bar or `Ext4Mac unlock`; the passphrase never enters the sandboxed extension |
| **Formatting** | `newfs_fskit -t ext4 /dev/diskN`; Disk Utility after `sudo make install-diskutil` |
| **Files** | extended attributes, hard links, symlinks, rename, preallocation; `chattr +i` / `+a` honoured as `uchg` / `uappnd` |
| **Refused by name** | `bigalloc`, `inline_data`, `meta_bg`, `casefold`, `large_dir`, `ea_inode`, fscrypt, compression, external journals — each with a message that says which |
| **Read-only** | `quota`, `project`, `verity`, any unknown RO_COMPAT bit, and read-only media |
| **Not yet** | kernel-offloaded I/O (every byte is copied through the extension), LUKS detached headers, ciphers other than XTS |

The full policy table is [docs/ENVELOPE.md](docs/ENVELOPE.md); it is diffed
against the driver's own table on every test run, so it cannot drift.

## Three things to know

- **Eject before unplugging.** FSKit gives a third-party module no way to
  flush a drive's cache, so the journal's ordering guarantee stops at the
  drive. Twenty mid-write pulls across five drives all recovered cleanly, but
  a pull mid-write can also panic macOS itself — the storage stack's problem,
  not one this driver can prevent. Details and numbers: [ENVELOPE.md](docs/ENVELOPE.md#the-barrier-what-this-driver-cannot-promise).
- **Apple Silicon, macOS 15.4 or later.** No Intel or universal build is
  produced or tested.
- **Building a copy that mounts needs a paid Apple Developer account.**
  FSKit's entitlement is restricted and macOS honours it only under a
  provisioning profile. Building and running every test suite does not need
  one; only mounting does.

## Command line

`/Applications/Ext4Mac.app/Contents/MacOS/Ext4Mac` — or put it on your `PATH`.

| verb | what it does |
|---|---|
| `status` | is the extension enabled, and every volume with something to report |
| `last-error /dev/diskN` | why a disk did not mount, and what to do about it |
| `events [n]` | the last *n* volume events |
| `unlock /dev/diskN` | prompt for a passphrase, derive the master key, keep it in the keychain |
| `mount /dev/diskN` | mount a volume whose key is stored |
| `forget /dev/diskN` | forget that key; `forget --all` lists them, `--yes` removes them |
| `list` | which encrypted volumes are unlocked |
| `login-item on\|off` | start at login so the extension stays registered across reboots |
| `version` | which build the installed bundles are |

## When it looks broken

| symptom | do this |
|---|---|
| "The disk you inserted was not readable" | `Ext4Mac last-error /dev/diskN` — it says whether the volume is locked, refused, damaged or degraded, and why |
| The extension shows *disabled*, or mounts fail with "Unable to invoke task" | Approve it in System Settings (path above), then `make check-extension` |
| Nothing mounts and Paragon ExtFS is installed | Its driver wins the probe. Disable it. |

More in [docs/INSTALL.md](docs/INSTALL.md).

## Building from source

Requirements: macOS 15.4+, Apple Silicon, Xcode Command Line Tools,
`brew install e2fsprogs`; Docker for the Linux-kernel stages.

```bash
git submodule update --init
make            # Ext4Mac.app with the extension inside
make test       # read + write suites against disk images
make validate   # everything, including the Linux-kernel and mounted stages
make help       # every target
```

The ext4 core is decoupled from FSKit, so `make test` and `make validate`
exercise the real filesystem code with no Apple account, no signing and no
mounting. To mount you need a Developer ID certificate and a provisioning
profile for the extension's App ID with the FSKit capability — both
gitignored, both yours. Then:

```bash
make sign SIGN_ID="Developer ID Application: Your Name (TEAMID)"
make install
```

The failure mode is silent: a wrongly provisioned extension is killed by AMFI
the instant it launches, with no crash report, and looks exactly like one
that is merely disabled. `make sign` checks every claimed entitlement against
the profile for that reason. Everything about certificates, profiles and
`errSecInternalComponent` is in [docs/SIGNING.md](docs/SIGNING.md).

## How it is tested

The oracle is never this driver: every volume it writes is handed to
`e2fsck`, `debugfs`, `cryptsetup` and the Linux kernel's own ext4, which
replays each crash cut and reads back each byte. `make validate` runs the
whole chain unattended in about ten minutes on a recent Mac (longer the first time, while Docker images build):

| stage | what it proves |
|---|---|
| read, write, bounds | every read against `debugfs`; `e2fsck` after **every** write; overflow refusals and hostile geometry |
| format, orphans, preallocation, revokes | `e2fsck`-clean across a geometry sweep; open-unlink recovery; journal revoke records |
| crypto, error injection, checksums | AES-XTS against OpenSSL; a medium that answers EIO surfaces every failure; checksums that act |
| fuzzing | an in-process libFuzzer harness with a structure-aware mutator, a mutation campaign, and 21 hostile fixtures — one per finding, each shown to fail before its fix |
| crash consistency, reordered writes, differential | every cut of the write stream and a reordering medium, replayed by the Linux kernel; both directions byte-exact |
| replay speed | a deep dirty journal must mount inside DiskArbitration's budget on a modelled USB stick |
| mounted driver | a live FSKit mount: crash snapshots, kill recovery with a timed remount, encrypted volumes, newfs, user-visible events |

CI runs the offline suites on macOS, the same core under AddressSanitizer
and UBSan, a fuzz smoke with a coverage gate, and the oracle suites on Ubuntu
where the Linux kernel judges. A nightly fuzzes for an hour each way. The
mounted stages and the pull test need an approved extension and a stick, so
they stay local — recorded in [docs/HARDWARE.md](docs/HARDWARE.md).

Testing has found more than twenty genuine bugs in the vendored lwext4 —
one replayed stale journal records over live metadata, one hung the driver
forever instead of failing — carried as 79 numbered patches, each with its
reason in [patches/lwext4/README.md](patches/lwext4/README.md).

## Documentation

| | |
|---|---|
| [docs/INSTALL.md](docs/INSTALL.md) | installing, approving, upgrading, uninstalling — for users |
| [docs/ENVELOPE.md](docs/ENVELOPE.md) | what is supported, refused, read-only, and measured; the barrier |
| [docs/STATUS.md](docs/STATUS.md) | what works today, the known gaps, the record |
| [docs/notebook/](docs/notebook/README.md) | the engineering record: every investigation, dated and unedited |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | how it fits together and the decisions that shaped it |
| [docs/SIGNING.md](docs/SIGNING.md) | certificates, entitlements, profiles, releasing from CI |
| [docs/HARDWARE.md](docs/HARDWARE.md) | the runbook for a day with real media |
| [patches/lwext4/README.md](patches/lwext4/README.md) | every change to lwext4 and why |
| [Tests/fuzz/README.md](Tests/fuzz/README.md) | the fuzzing instruments |
| [CHANGELOG.md](CHANGELOG.md) | what changed, by version |

## Contributing, security, licence

Contributions are welcome under the rules in [CONTRIBUTING.md](CONTRIBUTING.md)
— every fix arrives with a test shown failing first. Data-loss or memory-safety
findings go through [SECURITY.md](SECURITY.md) rather than a public issue.

**GPL-3.0-or-later.** This project vendors [lwext4](https://github.com/gkostka/lwext4),
whose `ext4_extent.c` and `ext4_xattr.c` are GPL-2.0-or-later and whose
remainder is BSD-3-Clause; the combined work is distributed under
GPL-3.0-or-later. See [LICENSE](LICENSE).
