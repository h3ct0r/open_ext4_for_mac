# Architecture

```
Ext4Mac.app                        container app; macOS finds FSKit modules
│                                  through an installed application bundle
└── Ext4FS.appex                   sandboxed FSKit extension
    │
    ├── Ext4Extension.swift        @main, UnaryFileSystemExtension
    ├── Ext4FileSystem.swift       probe / load / unload + the feature gate
    ├── Ext4Volume.swift           volume identity, capabilities, attr mapping
    ├── Ext4Volume+Operations      lookup, enumerate, attributes, symlinks
    ├── Ext4Volume+KernelIO        extent maps for kernel-offloaded I/O
    ├── Ext4Volume+ReadWrite       byte-copy fallback, xattrs
    ├── Ext4Item.swift             an inode; explicitly NOT a path
    ├── Ext4Executor.swift         serial queue — lwext4 is not thread safe
    ├── IdentityMapper.swift       Linux uid/gid ⇄ macOS presentation
    └── BlockDeviceBridge.swift    C callbacks → FSBlockDeviceResource
        │
        └── libext4core.a
            ├── ext4_bridge.c      inode-oriented C API
            └── lwext4 (vendored, pinned submodule + patches/)
```

## Decisions that shaped this

### Inode-oriented, not path-oriented

lwext4's public API is path-based (`ext4_fopen("/a/b/c")`). FSKit is
inode-based: it asks "look up name N in directory D" and then hands the
resulting object back on every later call.

Bridging those by caching a path per item is the obvious approach and it is
wrong. A hard-linked inode has several equally valid paths, so any single
cached path is arbitrary; and renaming a directory silently invalidates the
cached path of every descendant. Both produce corruption that only shows up
later.

The bridge is therefore built on lwext4's inode-reference layer
(`ext4_fs_get_inode_ref`, `ext4_dir_find_entry`, `ext4_dir_iterator_*`), which
maps onto FSKit's model directly. `Ext4Item` stores an inode number and
nothing else.

### Callback-driven block I/O

`ext4b_device_create` takes read/write/flush function pointers rather than
calling FSKit itself. In the extension those land on `FSBlockDeviceResource`;
in the test suite they land on a plain file.

This is why `make test` can exercise the real filesystem code with no code
signing, no entitlement, no mounting and no root — and why a contributor
without a paid Apple account can still work on the core.

### Two I/O paths

- **Metadata** — superblock, group descriptors, bitmaps, inode tables,
  directory blocks, journal — goes through FSKit's `metadataRead` /
  `delayedMetadataWrite` / `metadataFlush` family. That is a kernel-managed
  cache, and `metadataFlush` is the write barrier journalling depends on.

- **File data** was meant to bypass the extension entirely: `blockmapFile`
  packs ext4's extents into an `FSExtentPacker` and the kernel moves the bytes
  itself, which is nearly a direct translation from ext4's own extent layout.

  That is **not what runs today.** Conforming to
  `FSVolumeKernelOffloadedIOOperations` makes FSKit route writes through
  `blockmapFile` even for files that report `inhibitKernelOffloadedIO`, and a
  write blockmap has to allocate blocks and journal the extent-tree change
  before returning, with nothing to undo it if the kernel then fails the I/O.
  Until that is built, all I/O goes through `FSVolume.ReadWriteOperations`,
  where allocation stays inside a transaction we control. The code is kept as
  `Ext4Volume+KernelIO.swift.disabled`.

### Serialisation

FSKit issues volume operations concurrently. lwext4 keeps global mount-point
state and its block cache has no locking, so every call into the core funnels
through `Ext4Executor`'s serial queue. This is a correctness requirement, not a
tuning knob, and the boundary is easy to leak across by accident: attribute
translation looks like pure data-shuffling, but resolving `parentID` reads the
directory's `..` entry, so it is a core call too. Doing it just outside the
executor block was enough to let two kernel threads into lwext4 at once, which
double-freed a block-cache buffer and hung the volume. `Ext4Volume.populate`
now documents that it must run on the executor.

`volumeStatistics` is the single deliberate exception. FSKit declares it
synchronous, so there is nowhere to await, and blocking a kernel thread on the
executor would deadlock whenever the executor was busy. It is safe only because
`ext4_mount_point_stats` reads fields out of the in-memory superblock and
touches neither the cache nor the device.

Serialisation is not the same as liveness. FSKit delivers operations after the
volume has been closed — `synchronize` reliably arrives after `unmount` — so
the core handle has to be fallible rather than force-unwrapped.

### The feature gate

`ext4b_probe()` parses the superblock by hand — no mounting, no writes, full
bounds checking — and gates on an **allow-list**. An unknown INCOMPAT bit means
the on-disk layout may differ in ways we cannot see, so the volume is refused
rather than risked.

The gate is a table, not a chain of conditions: one row per feature bit with
its policy (supported, read-only, refused) and the sentence a person sees.
`ext4dump policy` prints it, and `docs/ENVELOPE.md` carries the same table for
readers -- `Tests/run_envelope_tests.sh` diffs the two, so the document cannot
quietly stop describing the code.

One case is worth calling out. `metadata_csum_seed` (INCOMPAT 0x2000) stores an
explicit checksum seed so `tune2fs` can change a volume's UUID without
rewriting every checksum. Upstream lwext4 has no notion of that field and
always derives the seed from the UUID; `patches/lwext4/0012` gives it
`ext4_sb_csum_seed()`, which honours the stored value, so such a volume mounts
read-write here. (An earlier version of this paragraph described the pre-0012
behaviour, and the read-only downgrade it implied is gone.) `mke2fs` sets the
two equal at creation, so they agree until
somebody changes the UUID. The probe compares them and downgrades the volume to
read-only when they diverge, because otherwise every checksum lwext4 wrote
would be wrong. Modern `mke2fs` enables this feature by default, so without
this check the driver would either reject most volumes or quietly corrupt them.

### Ownership mapping

ext4 records Linux uid/gid values that mean nothing locally: a disk from a
Linux box is typically owned by uid 1000, which is not the Mac user, so Finder
would refuse nearly every operation.

The default follows Apple's own msdos/exfat behaviour and presents everything
as owned by the mounting user. On-disk uid/gid are preserved and written back
unchanged, so a volume that round-trips through macOS still looks right on
Linux.
