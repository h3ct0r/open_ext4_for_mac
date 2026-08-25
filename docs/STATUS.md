# Status

| Phase | State |
|---|---|
| 0 — pipeline & packaging | complete except signing (needs a Developer ID cert) |
| 1 — read-only ext2/3/4 | **complete; 41 tests green** |
| 2 — kernel-offloaded I/O | implemented |
| 3 — write path | not started |
| 4 — correctness harness | read-side complete; crash-consistency suite pending |
| 5 — polish & distribution | not started |

## What works today

```bash
make          # builds Ext4Mac.app with the FSKit extension inside
make test     # 41 assertions against real ext2/3/4 images
```

The whole project builds with the **Command Line Tools** — full Xcode is not
required.

**Core (verified):** probe and feature gating; mount and statfs; inode
attributes, hard links and symlinks; directory enumeration including
HTree-indexed directories; file reads across 1 KiB and 4 KiB block sizes on
both ext2 indirect-block and ext4 extent layouts; logical→physical extent
mapping; extended attributes. Every content read is compared byte-for-byte
against `debugfs`, and every fixture is checked with `e2fsck`.

**Extension (builds, not yet loadable):** the full FSKit surface —
`FSUnaryFileSystem` probe/load/unload, `FSVolume.Operations`,
`FSVolumeKernelOffloadedIOOperations`, `FSVolume.ReadWriteOperations`,
`FSVolume.XattrOperations` — plus Info.plist, entitlements and bundle layout
matching what shipping FSKit modules use.

## The one blocker

Loading the extension needs a **Developer ID certificate and a provisioning
profile** carrying `com.apple.developer.fskit.fsmodule`. That requires a paid
Apple Developer account and cannot be worked around; see `docs/SIGNING.md`.

Until then the extension can be built and structurally verified, but macOS
will not load it. The ext4 core is unaffected — it is tested independently of
FSKit.

## Not yet done

- All write operations (`createItem`, `removeItem`, `renameItem`, `write`,
  `setAttributes`, `setXattr`) currently return `EROFS`
- Journal replay wiring for read-write mounts
- Crash-consistency and differential-vs-Linux test suites
- `startCheck` / `startFormat` for Disk Utility integration
- Notarised DMG
