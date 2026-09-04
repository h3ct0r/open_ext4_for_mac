<!-- Moved from docs/STATUS.md on 2026-09-04; content unchanged apart from heading levels. -->

# Journal replay speed

A real-hardware incident (2026-08-29): a LUKS2+ext4 stick unplugged mid-write
took **over eight minutes** to replay its journal on the next mount, and
DiskArbitration abandons a mount after about twenty seconds (`0x3C`
`ETIMEDOUT`) — so the volume simply never appeared, with a healthy driver
grinding away invisibly behind it. A `sample` of the wedged extension told the
whole story: `jbd_iterate_log → jbd_replay_block_tags` issuing one 4 KiB
`pread` per journal block through the LUKS layer, and 43% of samples inside
`ext4_bcache_free → ext4_block_flush_buf` writing replayed blocks back one
flush at a time. Nearly every sampled instruction was a syscall in flight:
replay was priced entirely in device commands, and a USB stick charges a
fixed setup cost per command.

Patches 0027–0029 restructure recovery around that fact:

* **0027** — the recovery pass reads the log through a 1 MiB read-ahead
  window, one device command per physically-contiguous run. Replay is the one
  reader that knows its access pattern is a strictly forward sweep.
* **0028** — replayed blocks collect in a 4 MiB batch and flush sorted,
  deduplicated (newest copy per block — the state sequential replay ends
  with), and coalesced into one command per contiguous run. A hot metadata
  block logged in two hundred transactions is written once per batch, not two
  hundred times. Replay write errors now fail `jbd_recover` instead of
  vanishing inside a `void` callback with the journal cleared regardless.
* **0029** — a log the scan pass saw no revoke blocks in skips the revoke
  pass, which otherwise re-reads every header block to build an empty tree.
  The common case for removable media: files copied on, nothing deleted.

The red-first test is `Tests/run_replay_speed_tests.sh` (`make
test-replay-speed`). It rebuilds the incident — LUKS2 container, `mkfs.ext4
-J size=128`, our driver killed with `SIGKILL` mid-load, ~1700 transactions
left unreplayed — and prices recovery like the medium that produced it:
ext4dump's media model charges 500 µs per device command plus 40 MB/s of
transfer (`EXT4DUMP_IO_LATENCY_US` / `EXT4DUMP_IO_BW_MBS`), with
`EXT4DUMP_IO_STATS` counting commands so the access-pattern claim is asserted
without timing flakiness. Before the patches that fixture cost **43,038 reads
+ 29,464 writes = 72,502 device commands, 44 s modelled — timeout**. After:
**~6,900 reads + ~4,100 writes, 14 s modelled — mounts**. On a revoke-free
journal, 7,451 commands. Replay correctness is checked the way every other
suite checks it: `e2fsck -fn` over the decrypted payload, files created
before the kill still present, and the full battery (image crash sweep at 274
cut points, reorder, revoke, orphan, LUKS, ASan) green on the patched tree.

Two questions the incident raised, answered:

*Can the mount path report progress?* No. FSKit's `loadResource` reply is
all-or-nothing and DiskArbitration exposes no way for an extension to extend
or feed its timeout. The fix has to be speed, not communication.

*Should recovery be bounded against the ~20 s budget?* Deliberately not.
Replay is now bounded by media **bandwidth** (the physical floor — the dirty
span must be read once) instead of command latency; a 128 MiB journal fits
the budget with margin on an ordinary stick, and ~256 MiB fits on anything
USB3. A maximal journal on a very slow stick can still exceed 20 s, but
every alternative bound is worse: mounting read-only without replay serves
stale, torn metadata; replaying after mount shows the same; and refusing the
mount is what the timeout already does. Replay is idempotent, so a mount DA
abandons leaves the journal intact and the next attempt starts clean — with
batches landing as they fill, a retry also redoes no *durable* harm. If the
pathological tail ever matters in practice, the next step is checkpointed
replay (advance the durable log tail after each flushed batch, behind a
barrier), so consecutive attempts make forward progress; jbd2 does not do
this either, and it is not worth the risk until a real journal needs it.
