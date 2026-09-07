<!-- Moved from docs/STATUS.md on 2026-09-04; content unchanged apart from heading levels. -->

# Disk Utility and newfs_fskit
## Disk Utility

`diskutil listFilesystems` and Disk Utility's Erase menu are driven by `.fs`
bundles in `/Library/Filesystems`, not by FSKit — which is how Paragon's extFS
appears in that list. `Packaging/ext4.fs` is such a bundle, and **it works**:

```
EXT2                            ext2
EXT3                            ext3
EXT4                            ext4
```

A plist plus two shell wrappers was enough — no probe helper, no
`FSMediaTypes`, no signing. `diskutil info` on a mounted ext4 volume now
reports its name and mount point instead of `File System: None`.

One cosmetic flaw: it reports `File System Personality: EXT2` for an ext4
volume. All three personalities share the `Linux` content mask and the bundle
has no prober of its own, so DiskArbitration picks the first match.



```bash
sudo make install-diskutil      # sudo make uninstall-diskutil to remove
diskutil listFilesystems | grep -i ext
```

It carries no filesystem logic. `FSFormatExecutable` points at a shell wrapper
that calls `newfs_fskit -t ext4 -g N`, so there is still exactly one
implementation, in the extension. It deliberately declares no
`FSProbeExecutable` or `FSMediaTypes` — DiskArbitration already probes through
FSKit, and a second prober would race it for the same media — and no
`FSMountExecutable`, because mounting goes through FSKit.

The `FSRepair` entry is a half-truth worth knowing about: First Aid passes
`-y`, meaning "repair without asking", and the wrapper prints that it can
verify but not repair rather than reporting a repair that never happened.

Formatting *through* Disk Utility's Erase runs the wrapper as **root**
(diskmanagementd invokes formatters that way), and FSKit module enablement is
per user — root has no modules, so a direct exec fails with "No extension
with fsShortName found" and Erase reports "File system formatter failed".
Both wrappers therefore re-dispatch when run as root: `launchctl asuser`
into the console user's bootstrap context, `sudo -n` to their uid, and the
enablement that exists is the one consulted. The device stays accessible
because fskit_helper (root) opens it, not the calling user.

Live-verified, both verbs. `diskutil eraseVolume EXT4 <name> diskN` over an
existing volume reformats it and DiskArbitration auto-mounts the result
through this driver, read-write; `diskutil eraseDisk EXT4 <name> GPT diskN`
on blank media builds the partition map, types the partition `Linux
Filesystem` (the personality's `FSFormatContentMask`), formats it through
`startFormat`, and mounts it the same way — e2fsck-clean in both cases, with
the extension's own task messages visible in diskutil's output. One
diskutil-ism worth knowing: `eraseVolume` on a *blank* whole-disk fails
earlier with "Couldn't open disk" (-69879) before any formatter runs — blank
media wants `eraseDisk`, which is also what Disk Utility's GUI does.

## `newfs_fskit` works — and what its long failure actually was

`newfs_fskit -t ext4 [-g 2|3|4] [-b size] [-L label] <device>` formats
through the extension, all three generations, and `fsck_fskit -t ext4` runs
the mountability check. Neither needed an ObjC principal class, a different
entry point, or any of the structural surgery the failure seemed to demand.

For most of this project's history the command failed with `ENOTSUP` and
`startFormat` was never called, and the investigation record accumulated a
table of ruled-out suspects pointing at the Swift `@main` entry point as the
remaining explanation. That hypothesis was wrong, and the tracing that
disproved it is worth keeping:

* fskitd's own log showed the extension **launching** for the format
  (assertion grabbed, user client configured) — the Swift entry point,
  manifest and conformance all worked. The glue's launch log even said so
  outright: `Got delegate conformance ... Maintenance 1`.
* the msdos control's only trace difference was one fskitd line — `Adding
  taskID to resource` — which disassembly places in the *success callback*
  of the load that precedes every format.
* our own appex log then completed the story: `loadResource` ran, probed the
  blank device, logged `refusing to mount`, and returned ENOTSUP. **The
  error `newfs_fskit` printed was this module's own refusal**, relayed back
  through fskitd from a load that was never a mount.

fskitd loads a resource before it will format or check it. Media with no
recognisable filesystem on it — the thing `newfs` exists to fix — must
therefore *load* successfully. `loadResource` now answers unrecognised media
with `Ext4UnformattedVolume`, a shell that can be the target of `startFormat`
and `startCheck` but fails activation with the ENOTSUP the load used to
give; auto-mount is unchanged because the probe still refuses everything the
shell stands in for. Two consequences got fixed in the same motion:
`startFormat` closes any volume the preceding load mounted (or the old
handle would write its superblock over the fresh filesystem on unload), and
foreign-signature wiping moved into `ext4b_format` — FSKit's `wipeResource`
facility turned out to be unreachable from a CLI-initiated format ("no
connector talking to fskitd is available"), and 128 KiB of zeroes over the
signature-bearing head and tail of the partition needs no facility. The
format suite covers the wipe offline: planted FAT and end-anchored
signatures are gone after `ext4dump format`, and the volume is e2fsck-clean.

`EXExtensionPrincipalClass` remains poison for a Swift `@main` module — that
part of the old record stands, the two entry-point mechanisms really are
mutually exclusive — it was just never the reason formatting failed.
`@objc(Ext4FileSystem)` was kept; it costs nothing and pins a name that was
otherwise incidental.

The same core path is fully covered offline: `ext4dump format` builds volumes
across 117 geometries, all `e2fsck`-clean.


## The re-dispatch was half a fix (2026-09-06)

The paragraph above says the wrappers re-dispatch to the console user and that
"the device stays accessible because fskit_helper (root) opens it, not the
calling user". The second half is wrong, and it cost a user an afternoon.

`fskit_helper` is on the MOUNT path. `newfs_fskit` opens the device in its own
process: its entitlements are `com.apple.private.LiveFS.connection` and a
mach-lookup exception for `com.apple.filesystems.fskitd`, and nothing for
disk-device access. So after the re-dispatch dropped to uid 501, the open of a
physical disk's `root:operator` node returned EACCES, and Disk Utility reported
`-69832`. Disk images never showed it, because their nodes belong to whoever
attached them -- which is exactly why every test until now passed.

The report that found it: an erase of a 256 GB stick, `Code=13`. `sudo chown
$(id -u) /dev/disk4s2 /dev/rdisk4s2` made the identical erase succeed, which
located the failure precisely -- and then made ownership look like the answer.
It was not. A design that lends the node and hands it back needs a trap, and a
detached restorer to survive the `SIGKILL` that `storagekitd` cancels with
(`rawTerminate` is `mov w1, #9; bl _kill`), and it leaves a window in which a
user has raw access to a disk.

The actual answer was already inside the tool. `/sbin/newfs_fskit` and
`/sbin/fsck_fskit` both read `SUDO_UID`, and when running as root call
`setreuid(SUDO_UID, -1)` before touching FSKit -- visible in `main` as
`getenv` -> `getuid` -> `strtoul` -> `setreuid`, second argument `-1`. Real uid
becomes the console user, so fskitd's audit-token lookup finds their enabled
module; effective uid stays 0, so the open succeeds. It is what plain `sudo
newfs_fskit` has always done. The wrapper now sets that variable and keeps the
root it was given.

Two other things this corrects. The daemon that runs a `.fs` bundle's formatter
is **`storagekitd`**, not `diskmanagementd` -- there is no such process on
macOS 26; it fork/execs the tool through `DMToolProcess` and waits. And
`fsck_ext4` carried the identical bug: First Aid on a physical ext4 volume
could not even read the node. Nobody had run it.

`Tests/run_diskutil_tests.sh` reproduces all of it without hardware, by
chowning a disk image's nodes to `root:operator`, and asserts the mechanism
from both sides: the string and the symbol are still in the shipped binary,
and without `SUDO_UID` the same command cannot format at all.
