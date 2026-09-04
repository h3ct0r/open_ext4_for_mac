# The notebook

The engineering record: what was measured, what broke, what it turned out to
be, and what changed. These were the sections of `docs/STATUS.md` until
2026-09-04, when that file became a status page and the narrative moved here
unchanged. Nothing has been edited for hindsight; where a later finding
corrected an earlier one, the correction is in the text where it was written.

Roughly in the order the work happened.

| entry | what it is about |
|---|---|
| [The first mounts](first-mounts.md) | the first read and write through a real mount, and the four packaging defects between "signed" and "mounts" |
| [Writing](writing.md) | the write path, mount options measured at the right callback, files Linux marked protected, how the write suite tests |
| [Validation](validation.md) | the validation chain and why there is a second crash suite |
| [Crash safety on the mounted path](crash-safety-on-the-mounted-path.md) | freezing the driver with `SIGSTOP` and imaging the device underneath it |
| [Formatting](formatting.md) | what the volumes look like; `startCheck` is a mountability check |
| [Auto-mount](auto-mount.md) | getting DiskArbitration to route a disk here |
| [Open-unlink](open-unlink.md) | the orphan list, and renaming |
| [Disk Utility and newfs_fskit](disk-utility-and-newfs.md) | the `.fs` bundle, and what `newfs_fskit`'s long failure actually was |
| [Encrypted volumes (LUKS)](encrypted-volumes.md) | what is implemented, the trap worth knowing, how it is tested, the first real drives |
| [Metadata checksums](metadata-checksums.md) | checksums that act rather than warn |
| [Finder could not copy files off an ext4 volume](finder-could-not-copy.md) | `com.apple.FinderInfo`, and an `EIO` that was fatal to a copy |
| [Write ordering is not enforced, and that is not theoretical](write-ordering-and-the-barrier.md) | the pulled stick, the barrier FSKit does not offer, the daemon that closed the gap, and the five-drive verdict that retired it; transaction batching; concurrent core entry; kernel-offloaded I/O discarding writes |
| [Soak](soak.md) | why elapsed time finds what assertions do not, the harness faults, and the round counts |
| [What the extension says when it will not mount](volume-events.md) | the volume-event channel, and three things the mounted cells taught about FSKit |
| [Preallocation](preallocation.md) | `F_PREALLOCATE`, unwritten extents, and the partial tail that corrupted 391 of 408 files |
| [Journal replay speed](journal-replay-speed.md) | the eight-minute replay that DiskArbitration timed out, and the 43k-to-10k command fix |
| [The pre-hardware hardening pass](pre-hardware-hardening-pass.md) | error propagation, the I/O model, the fault knobs, and the fixtures that came out of it |

Two runbooks sit beside the notebook rather than in it, because they are
read before a session rather than after one: [HARDWARE.md](../HARDWARE.md)
for a day with real media and [SIGNING.md](../SIGNING.md) for certificates
and profiles.
