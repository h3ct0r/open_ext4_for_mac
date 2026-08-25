# Status

| Phase | State |
|---|---|
| 0 — pipeline & packaging | complete except signing (needs a Developer ID cert) |
| 1 — read-only ext2/3/4 | **complete; 41 tests green** |
| 2 — kernel-offloaded I/O | implemented (read path) |
| 3 — write path | **complete; 82 tests green, opt-in via `-o rw`** |
| 4 — correctness harness | image-level complete; **crash-consistency still pending** |
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

## Writing

Implemented and passing: create, mkdir, symlink, hard link, unlink, rmdir,
rename (including across directories, over an existing file, and moving a
non-empty directory), write, append, multi-block writes, truncate both
directions, sparse regions, chmod/chown/times, and xattr set/remove.

Each operation is a single JBD2 transaction that either commits or aborts
leaving the volume untouched.

**Writes are opt-in.** Mounts are read-only unless `-o rw` is passed. The
image-level suite is green, but the write path has not been through
crash-consistency testing, and defaulting to writable on somebody's only copy
of a disk is not defensible until it has.

### How it is tested

`e2fsck` runs after **every** mutating operation, not once at the end — a write
path that corrupts and then repairs two operations later still loses data on
power failure. Results are cross-checked against `debugfs`, an independent
implementation, so the suite cannot agree with a bug in our own reader.

`make test-asan` reruns everything under AddressSanitizer and UBSan. That is
how two genuine lwext4 defects were found; see `patches/lwext4/README.md`.

## Not yet done

- **Crash-consistency testing** — truncate the write stream at randomised
  points, replay the journal, verify with `e2fsck`. This is the gate for making
  writes the default.
- Differential testing against Linux ext4 in a VM
- Kernel-offloaded I/O for writes (reads already use it)
- `startCheck` / `startFormat` for Disk Utility integration
- Notarised DMG
