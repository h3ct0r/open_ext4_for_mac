<!-- Moved from docs/STATUS.md on 2026-09-04; content unchanged apart from heading levels. -->

# Validation

```bash
make validate           # the full chain (18 stages), unattended
make validate-asan      # the same under AddressSanitizer + UBSan
make test-format        # stage 3 on its own
make test-orphan        # stage 4 on its own
make test-mount-crash   # stage 7 on its own
make test-scale         # volumes and files past 4 GiB (writes ~4.5 GiB)
```

`test-scale` is not in `validate`: it writes 4.5 GiB through a real mount and
takes a minute of pure I/O, and a suite that costs a minute stops being run.
It is behind `SLOW=1`, which that target sets.

| Stage | What it proves |
|---|---|
| 0 / 0b — patches, ship surface | the patch set reproduces the vendored tree; the shipping core reads no environment |
| 1 — read suite | content verified byte-for-byte against `debugfs` |
| 2 / 2b — write suite, bounds | `e2fsck` after **every** mutating operation; overflow and POSIX-semantics refusals, including hostile journal geometry under deadlines |
| 3 — format | a size/block-size/generation sweep must be `e2fsck`-clean and round-trip through the Linux kernel; big formats and lazy-init mounts are bounded in device *commands* |
| 4 / 4b / 4c — orphans, prealloc, revoke | every cut point of a deferred delete recovers by *mounting*; unwritten-extent lifecycle; every revoke entry names a real block |
| 5 / 5b — crypto, error injection | AES-XTS known answers; a medium that answers EIO must surface every failure (exit codes, kept journals, e2fsck-clean end states) |
| 5c — checksums that act | a bitmap corrupted from outside the driver must make the write fail **and** leave the checksum untouched; healthy and checksum-less volumes unaffected |
| 5d — fragmentation | the same bytes to the same files in two allocation orders: interleaving must not cost more extents than a reservation can absorb, the reservation must come back, and the volume must still fill to the last block |
| 6 — LUKS | fixtures made by real cryptsetup, read back by the Linux kernel |
| 7 / 7b — crash, reordered writes | the write stream severed at every cut point, replayed by the **real Linux kernel**; then the same on a medium that also **reorders** what was in flight |
| 8 / 8b — differential, replay speed | round-trips between our driver and Linux ext4 with a silent kernel log; a deep dirty journal must mount inside DiskArbitration's ~20 s budget on a modelled USB stick |
| 9–12 — mounted stages | the real FSKit mount: crash sweeps, encrypted volumes, kill recovery (now with a timed deep-journal remount), newfs/fsck |

The per-suite assertion counts drift as suites grow; the suites print their
own tallies and the validation driver records PASS/FAIL/SKIP per stage —
those, not this table, are the record.

Stages 5–7 use Docker, which on Apple Silicon is a real Linux VM — so the
oracle is the actual ext4 implementation, not another copy of our assumptions.
They skip with a warning if Docker is not running; stage 7 also skips if the
signed extension is not installed and enabled. Stages 3 and 4 run either way —
only one section of each needs Docker.

The power-failure model matters: after the cut point, writes are **silently
discarded while still reporting success**. A real power loss does not hand the
filesystem an errno it can react to. Returning `EIO` would exercise error
handling instead, which is a far easier test to pass.

## Why a second crash suite

The crash sweep above has always passed, and for a long time that was not
evidence of anything. A disk image's writes reach the host filesystem in issue
order and stay there, so a torn image is always a clean prefix of the write
stream — the one state that is safe by construction. Forty-two cut points
across two image sizes: all clean. The same driver against a USB stick:
damaged five times out of five.

`make test-reorder` closes that gap by modelling the medium instead of trusting
it. With `EXT4DUMP_WRITE_CACHE` set, `ext4dump` behaves like a drive rather
than a file: reads are served from the cache, only a barrier makes a write
durable, a full cache evicts a seeded-random half **out of order**, and at the
cut whatever is still pending is permuted and only a prefix of that permutation
is committed. The seed is the whole reproduction recipe.

The suite is a matrix now — geometries × workloads × batch sizes — because
its worst failure was structural: every cell it had ran on a 16 MB journal
that never wrapped during a workload, and the wrap path is where lwext4's
ordering bugs lived (patches 0017–0020). The 64 MB fixtures carry the 4 MB
minimum journal; the wrap-heavy workloads cycle creates and deletes so
revokes and log laps actually happen; `--quick` runs the load-bearing cells
in under thirty seconds for the dev loop. Every torn image is replayed by the
Linux kernel; a trace classifier (`Tests/classify_trace.sh`, fed by
`EXT4DUMP_TRACE`) attributes any failure to the write class that landed out
of order — filesystem superblock, journal superblock, log, or home metadata —
which is how the tail-advance bug was diagnosed rather than guessed at.

Two things are asserted, and the second matters as much as the first:

```
236 cut points, 15 cells                 every one clean
barriers ignored (three controls)        every one damaged
```

A crash-consistency test that cannot be made to fail is not evidence. This
project has shipped one check that could only report success — it reported it
on a volume the driver had never touched — which is why the negative control is
part of the suite rather than a thing someone remembers to run.

The knobs, following the existing `EXT4DUMP_*` idiom:

| variable | meaning |
|---|---|
| `EXT4DUMP_WRITE_CACHE` | cache size in bytes; unset leaves behaviour exactly as before |
| `EXT4DUMP_REORDER_SEED` | permutation used for eviction and for the crash |
| `EXT4DUMP_REORDER_DROP` | percentage of the pending queue lost at the cut |
| `EXT4DUMP_IGNORE_BARRIERS` | a drive that reports a cache flush and does not perform one |

One trap, since it invalidated a whole run before anyone noticed: counting the
workload's writes must be done against a *copy* of the fixture. Run against the
fixture itself it mutates it, every later clone starts with the workload's
directories already present, the script aborts on its first `mkdir`, and the
suite reports that a filesystem nobody touched recovered perfectly.
