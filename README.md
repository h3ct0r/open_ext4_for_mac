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

Validation runs unattended (allow ~20 minutes for the full chain with Docker and the mounted stages; the offline stages alone are a few minutes):

```bash
make validate
```

| Stage | Coverage |
|---|---|
| read suite | verified against `debugfs` |
| write suite | `e2fsck` after **every** mutating operation |
| bounds & semantics | overflow refusals, hostile journal geometry, POSIX edges |
| format | a geometry sweep, all `e2fsck`-clean; big formats bounded in device commands |
| open-unlink recovery | the orphan list, and torn ones |
| crypto & error injection | AES-XTS against OpenSSL; a medium that answers EIO must surface every failure |
| LUKS containers | judged by real `cryptsetup` |
| crash consistency | every cut point of the write stream; the Linux kernel replays each journal |
| reordered writes | the same on a medium that reorders, which is the failure an image cannot produce — and asserts that disabling barriers breaks it |
| differential vs Linux | both directions, with a silent kernel log |
| journal replay speed | a deep dirty journal must mount inside DiskArbitration's budget on a modelled USB stick |
| mounted driver | a live FSKit mount: crash sweeps, encrypted volumes, kill recovery with a timed remount, newfs |

(The suites print their own assertion tallies; the counts grow too often to
be worth restating here.)

A file deleted while something still has it open goes on ext4's own **orphan
list**, so a crash in that window is recoverable by the next mount rather than
a leak — and `chattr +i` / `chattr +a` are honoured, reported to macOS as
`uchg` / `uappnd`.

**ext4 inside LUKS mounts**, LUKS1 and LUKS2 alike — the one thing macOS
otherwise cannot open at all, since `cryptsetup` needs device-mapper and
cannot be ported:

Plug one in and a menu-bar agent asks for the passphrase; after that it mounts
by itself, under its own name, like any other disk. Or without the GUI:

```bash
Ext4Mac unlock /dev/disk6            # prompts; derives the master key
Ext4Mac mount /dev/disk6             # or just plug it in again
Ext4Mac forget /dev/disk6            # locked again
```

The passphrase is typed into the app and never reaches the sandboxed
extension, which only ever sees a master key. Everything macOS writes to an
encrypted volume is handed back to real `cryptsetup` and the Linux kernel to
read; see [docs/STATUS.md](docs/STATUS.md).

Testing has found over twenty genuine bugs in lwext4 — including one that replayed stale
journal records over live metadata, and one that hung the driver forever
instead of failing — plus several of our own. See
[docs/STATUS.md](docs/STATUS.md) and
[patches/lwext4/README.md](patches/lwext4/README.md).

> **Everything writable mounts read-write — USB sticks included — and that
> is a measured decision.** The driver's earliest write path corrupted a
> pulled stick five times out of five, so for a while removable media was
> read-only unless a privileged helper daemon confirmed a device cache-flush.
> Then the question was remeasured on the current direct-I/O write path, as
> an A/B with that daemon as the control arm: twenty mid-write pulls across
> five drives — USB-2 sticks through an NVMe SSD behind a bridge chip,
> fenced and under sustained load — recovered by journal replay to an
> `e2fsck`-clean filesystem every time, barriered and unbarriered alike
> ([Tests/run_pull_tests.sh](Tests/run_pull_tests.sh)). The daemon is gone.
>
> **Eject before unplugging** anyway: a pull mid-write can panic macOS
> itself (an `IOMediaBSDClient` busy timeout in Apple's storage stack,
> observed once during that sweep), and the last seconds of unsynced writes
> are only as durable as any filesystem's. Details in
> [docs/STATUS.md](docs/STATUS.md). Keep a backup.

## Requirements

- macOS 15.4 or later (developed and tested on macOS 26)
- Apple Silicon (the build targets `arm64`; an Intel or universal build is not
  produced or tested)
- Xcode Command Line Tools (full Xcode is **not** required)

To *mount* volumes, additionally:

- A **paid Apple Developer Program** membership — FSKit's
  `com.apple.developer.fskit.fsmodule` is a restricted entitlement and needs a
  provisioning profile to authorise it

That is covered under [Building](#building). It is not needed to build the
driver or to run any of the test suites.

## Building

```bash
git submodule update --init
make            # build Ext4Mac.app with the FSKit extension inside
make test       # read + write suites (needs: brew install e2fsprogs)
make validate   # everything, including the Linux-kernel stages (needs Docker)
```

The ext4 core is deliberately decoupled from FSKit, so `make test` and
`make validate` exercise the real filesystem code against disk images with **no
Apple account, no signing and no mounting**. Everything below is needed only to
*mount* volumes.

### Mounting needs a paid Apple Developer account

Not just a certificate. FSKit modules require the restricted entitlement
`com.apple.developer.fskit.fsmodule`, and macOS only honours a restricted
entitlement when an embedded **provisioning profile** authorises it. Profiles
come from a paid Apple Developer Program membership; there is no free path, and
nothing in this repository can supply one for you.

You need two things of your own:

| | |
|---|---|
| A Developer ID Application certificate | in your login keychain |
| `Extension/Ext4FS.provisionprofile` | for the App ID `<TEAM>.dev.h3ct0r.ext4mac.Ext4FS`, with the FSKit capability enabled |

Both are gitignored, deliberately — a provisioning profile is tied to your team
and your certificate, and committing one would be useless to you and careless
of us. Change `BUNDLE_ID` in the `Makefile` to your own reverse-DNS name and
create the App ID under it.

```bash
make sign SIGN_ID="Developer ID Application: Your Name (TEAMID)"
make install
```

Then enable it in **System Settings → General → Login Items & Extensions →
File System Extensions**, and check with `make check-extension`.

The failure mode is worth knowing in advance, because it is silent: an ad-hoc
or wrongly-provisioned signature does not produce an error. AMFI kills the
extension the instant it launches — no crash report, nothing in the log — and
what you see is a module that will not mount anything, which looks exactly like
a module that is merely disabled. `make sign` runs
`scripts/verify_signing.sh`, which compares every claimed entitlement against
the ones the embedded profile actually authorises, precisely because this
failure has no other symptom. See [docs/SIGNING.md](docs/SIGNING.md).

### Removable media, pulled sticks, and the retired barrier daemon

Removable media mounts **read-write like everything else**. A journal is a
claim about write ordering, and FSKit exposes no way for a third-party module
to flush a drive's cache: `metadataFlush` — the only write barrier in the
whole `FSResource` API — fails with `EIO` here, and the device-level call
underneath it, `DKIOCSYNCHRONIZE`, is denied to the sandbox by name. For a
while that gap was closed by `ext4barrierd`, a root daemon with one verb
(flush this disk's cache), and removable media was read-only without it.

The daemon was retired after the question was remeasured on the current
write path, which hands every write synchronously to the device through
FSKit's raw descriptor. A five-drive pull-test sweep — twenty mid-write
pulls, fenced and under sustained load, with the daemon as the A/B control
arm — recovered identically with and without barriers: `e2fsck` found
nothing to fix, and no synced file was lost
([Tests/run_pull_tests.sh](Tests/run_pull_tests.sh), results in
[docs/STATUS.md](docs/STATUS.md)). The sweep also showed the old policy
never covered the drives most likely to cache: large sticks and USB SSDs
report themselves as *fixed* media, so they wrote unbarriered all along.

If a machine still has the daemon from an earlier build:

```bash
sudo make uninstall-barrier
```

For pull-testing real media, `make preflight EXT4_KILL_DEVICE=diskNs1`
verifies the hand-granted switches and proves the driver owns the volume
before a run spends your time measuring nothing.

## Documentation

- [Architecture](docs/ARCHITECTURE.md) — how it fits together and why
- [Status](docs/STATUS.md) — what works today
- [Signing](docs/SIGNING.md) — certificates and entitlements

## Licence

**GPL-3.0-or-later.** This project vendors [lwext4](https://github.com/gkostka/lwext4),
whose `ext4_extent.c` and `ext4_xattr.c` are GPL-2.0-or-later; the remainder is
BSD-3-Clause. The combined work is therefore distributed under GPL-3.0-or-later.

See `LICENSE`.
