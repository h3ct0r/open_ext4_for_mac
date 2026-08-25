# lwext4 patches

Applied automatically by the build (`make patch`, and as a prerequisite of every
object file). Idempotent — a clean checkout builds with a plain `make`.

| Patch | What it does |
|---|---|
| `0001-guard-EXT_FINCOM_IGNORED` | Lets the build extend the INCOMPAT bits lwext4 tolerates, so we can accept `metadata_csum_seed` (which modern `mke2fs` enables by default) after the bridge has verified the seed still matches the UUID. |
| `0002-fix-xattr-remove-ibody-finder` | **Bug fix.** NULL dereference (SIGSEGV) when removing an xattr stored in the inode body — the common case. |
| `0003-avoid-null-pointer-arithmetic-in-xattr-list` | Replaces a `sizeof`-via-null-pointer idiom that UBSan flags on every `listxattr`. |
| `0004-fix-htree-leaf-block-init-and-checksum-order` | **Bug fix.** New HTree leaf blocks were never cleared (stale buffer contents written into a directory block) and were checksummed before the last field was written, so `e2fsck` reported `directory passes checks but fails checksum`. |

0002 and 0004 are genuine upstream defects, both found by running the write
suite under `-fsanitize=address,undefined` (`make test-asan`). They are worth
sending upstream.

0004 is a good illustration of why the suite runs `e2fsck` after *every*
operation and why it runs under sanitizers: in an ordinary optimised build the
bug is invisible, because the freshly-allocated block happens to be zeroed and
the stale checksum still matches.
