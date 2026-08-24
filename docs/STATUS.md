# Status

| Phase | State |
|---|---|
| 0 — pipeline / signing | in progress (needs Developer ID cert) |
| 1 — read-only ext2/3/4 core | **core complete, 41 tests green** |
| 2 — kernel-offloaded I/O | extent mapping implemented in core |
| 3 — write path | not started |
| 4 — correctness harness | read-side suite in place |
| 5 — polish / distribution | not started |

## What works today

`make test` builds the core and runs 41 assertions against real ext2/ext3/ext4
images, verifying every content read byte-for-byte against `debugfs`:

- probe + feature gating (including refusing volumes whose UUID was changed
  after creation, where lwext4's derived checksum seed would be wrong)
- mount, statfs
- inode attributes, hard links, symlinks
- directory enumeration including HTree-indexed directories
- file reads across 1 KiB and 4 KiB block sizes, ext2 (indirect) and ext4 (extents)
- logical→physical extent mapping (the kernel-offloaded I/O primitive)
- extended attributes
- proof that read-only operation never modifies the image

## Not yet done

- The Swift FSKit extension (`FSUnaryFileSystem` / `FSVolume`) wrapping the core
- Bundle packaging, entitlements and code signing
- All write operations
