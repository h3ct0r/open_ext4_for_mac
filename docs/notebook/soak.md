<!-- Moved from docs/STATUS.md on 2026-09-04; content unchanged apart from heading levels. -->

# Soak

The number worth quoting about this driver is not how many assertions pass.
It is that four real bugs were found in a single day — a stale extent path, a
misplaced partial tail that corrupted 391 of 408 user files, a format that
never claimed a feature it used, and a `setAttributes` that had never worked
in the driver's life — every one of them in the mounted path, with the offline
suites reporting 114 of 114 throughout. Density like that says the surfaces
nothing exercises are where the bugs are, and no afternoon of writing
assertions brings it down. Elapsed time does.

```bash
make soak
```

runs `scripts/run_full_validation.sh` in a loop and stops dead at the first
failure. Not a pass rate: for a filesystem the question is whether it ever
loses data, and "usually not" is not an answer. `SOAK_ROUNDS=N` bounds it; a
failing round's whole output stays in `.soak/round-N.log` and passing
rounds' logs are deleted, because the failing one is the only one anybody will
read.

The count belongs here, appended as it accumulates, because "no known bugs"
and "none found in N runs" are different claims and only the second one means
anything. What the first few days taught: every stop so far was the harness,
not the driver -- a sleep, a DiskArbitration transient, a wedged app
container, an unchecked unmount -- and a soak is only as good as the scripts
around it. Four of those were found and fixed before the count below became
a number worth quoting:

A round costs about ten minutes, which is worth knowing before deciding how
long to leave it running: soaking overnight is dozens of rounds, not two.

A round of the full set takes about ten minutes. **If one takes three, count
the stages before believing it** -- `run_full_validation.sh` records a missing
prerequisite as SKIP rather than failure, which is right for a laptop without
Docker and wrong for a soak. Twenty rounds once passed in 215 s each because
Docker had not come back after a reboot, and seven stages did not run: every
one that needs the Linux oracle, plus both mounted stages, which are nested
inside that branch. `scripts/soak.sh` refuses to start in that state now, and
does not count a round that skipped anything.

| date | clean rounds | notes |
|---|---|---|
| 2026-09-01 | 1 | 628 s, on the build that closed the fragmentation work |
| 2026-09-01 | 7 + 7 | two runs, each stopped in round 8 by the harness rather than the driver: a laptop sleeping through a wall-clock deadline, then a remount losing a DiskArbitration re-probe. Both fixed. |
| 2026-09-02 | 6 | stopped in round 7 by an unchecked unmount in the newfs suite (`66fabc1`); the fourth harness fault, and the last one found |
| 2026-09-02 | **17** | 20 rounds requested, none failed. Three spanned a lid-close and were excluded by the sleep detection although each also passed. Every counted round 631–647 s: the full set, every time. First run with all four harness faults fixed. |
| 2026-09-01 | 7 | then **round 8 wedged** — see below |

## What the first long soak found

Seven rounds at ~630 s each, then round 8 stopped answering in stage 0 of
`run_mount_crash_tests.sh`: concurrent readers and writers still running after
120 s, and the extension still at 67% CPU three seconds after the load ended.
The suite recovered by killing the extension, which is what it is built to do,
and reported `stopped after stage 0`.

That stage is the regression test for a specific wedge: FSKit issues volume
operations concurrently, lwext4 has no internal locking, and when one entry
escaped the serial executor -- `getAttributes` resolving `parentID` -- two
kernel threads raced in the block cache, corrupted its LRU list and spun in
`ext4_bcache_free` at 200% CPU with `umount` in uninterruptible wait.

**It was the laptop sleeping.** The round took 2293 s where every other took
about 630, and the machine had been closed and carried somewhere in the
middle. A deadline measured in wall-clock expires the moment the machine
wakes, and the six queued readers all resume at once, which is the 67% too.

That is not a satisfying answer to leave as a judgement call, so the soak
detects it now: `kern.waketime` is read either side of every round, and a
round that spanned a sleep is reported as inconclusive and not counted, pass
or fail. Rounds also run under `caffeinate -i`, which keeps idle sleep away
but cannot stop a closed lid -- hence the detection as well.

Worth keeping the shape of the near-miss. Stage 0 is the regression test for a
real wedge, this looked exactly like one, and the first instinct was to
suspect the allocator work of the same week. It could not have been: stage 0
writes only `echo`-sized files, far below the 256 KiB threshold at which a
write reserves space ahead of itself. `scripts/repro_wedge.sh` exists from
that hour -- it runs the same workload in a loop and takes a `sample` of the
stuck process before recovering, because a spin is identified by where it is
spinning and the suite's own recovery destroys that evidence.
