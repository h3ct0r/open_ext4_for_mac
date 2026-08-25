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

- **File data** does not pass through the extension at all. `blockmapFile`
  packs ext4's extents into an `FSExtentPacker` and the kernel moves the bytes
  itself. ext4 is natively extent-based, so this is nearly a direct
  translation, and it is what keeps throughput competitive with a kext.

  Inodes the kernel cannot map — ext2/ext3 indirect-block files, inline-data
  inodes — set `inhibitKernelOffloadedIO` and fall back to the byte-copy path.

### Serialisation

FSKit issues volume operations concurrently. lwext4 keeps global mount-point
state and its block cache has no locking, so every call into the core funnels
through `Ext4Executor`'s serial queue. This is a correctness requirement.
Bulk data throughput is unaffected because file data bypasses it entirely.

### The feature gate

`ext4b_probe()` parses the superblock by hand — no mounting, no writes, full
bounds checking — and gates on an **allow-list**. An unknown INCOMPAT bit means
the on-disk layout may differ in ways we cannot see, so the volume is refused
rather than risked.

One case is worth calling out. `metadata_csum_seed` (INCOMPAT 0x2000) stores an
explicit checksum seed so `tune2fs` can change a volume's UUID without
rewriting every checksum. lwext4 has no notion of that field — its
`ext4_sblock` struct does not even declare it — and always derives the seed
from the UUID. `mke2fs` sets the two equal at creation, so they agree until
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
