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
