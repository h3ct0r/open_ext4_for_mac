# Feedback to Apple: FSKit's metadata I/O family returns EIO to a third-party module

**Status: draft, not yet filed.** When it is filed, the Feedback ID goes here
and in `docs/ENVELOPE.md`: `FB________ (filed YYYY-MM-DD)`.

Area: FSKit (macOS). Type: incorrect behaviour. Affects: an FSUnaryFileSystem
module using `FSBlockDeviceResource`, signed with the
`com.apple.developer.fskit.fsmodule` entitlement via a provisioning profile.

## Summary

Every call in `FSBlockDeviceResource`'s metadata I/O family --
`metadataRead`, `metadataWrite`, `delayedMetadataWrite`, `metadataFlush`,
`asynchronousMetadataFlush` -- fails with `EIO` for this module, during probe
and after load alike, while a plain `read` of the same offset and length into
the same buffer, microseconds apart, succeeds. `metadataFlush`, which takes no
buffer and no range, fails the same way. The family is gated as a whole.

Because `metadataFlush` is the only write barrier the `FSResource` API
offers, a module in this state has no supported way to ask the device to
commit its volatile write cache. A journaling filesystem's durability
guarantee stops at the drive's cache.

## What was measured

- Apple's own `msdos` module references the entire metadata family; the
  `exfat` module references none of it and reads directly, as this module
  does. So the family works in production for Apple's modules, and nothing
  observable from outside explains why it is closed for this one.
- Entitlements: Apple's `exfat` module carries strictly fewer than this one.
  Manifest keys: no FSKit key Apple's modules declare is absent from ours.
- Nothing appears in fskitd's log or the kernel's; every probe fails within
  the same millisecond, so the call is refused before it reaches a device.
- The module's process holds the device open itself (`/dev/rdiskN`, a real
  descriptor). `ioctl(DKIOCSYNCHRONIZE)`, `DKIOCSYNCHRONIZECACHE` and even the
  pure getter `DKIOCGETBLOCKSIZE` on that descriptor return `EPERM` from the
  sandbox, so the barrier cannot be issued directly either.

## Steps to reproduce

1. Build and install the module at
   https://github.com/h3ct0r/open_ext4_for_mac (`make app sign install`),
   enable it in System Settings > General > Login Items & Extensions.
2. Attach an ext4 volume. Watch `log stream --predicate 'subsystem ==
   "dev.h3ct0r.ext4"'`.
3. `metadataRead` in `probeResource` returns `EIO`; the same offset via `read`
   returns the superblock. `metadataFlush` after `loadResource` returns `EIO`.

## Expected

The metadata I/O family, or at minimum `metadataFlush`, works for a signed,
entitled third-party module as it does for Apple's `msdos` module -- or the
documentation states what additional entitlement or manifest key gates it.

## Actual

`EIO` from every call in the family, with no log line explaining the refusal.

## Why it matters

Without a barrier, the ordering of a journal commit against the data it
protects is only as good as the drive's write cache. This project measured
that on five USB drives with power-cut pulls and found no synced file lost,
which is a statement about those drives on this OS version, not a guarantee
the API could give. Users of removable media deserve the guarantee.
