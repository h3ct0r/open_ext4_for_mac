<!-- Moved from docs/STATUS.md on 2026-09-04; content unchanged apart from heading levels. -->

# Auto-mount

ext4 volumes now mount by themselves, the way any native disk does:

```
/dev/disk6 on /Volumes/AUTOMOUNT (ext4, local, nodev, nosuid, journaled,
                                  noowners, noatime, fskit, mounted by h3ct0r)
```

No `mount -F -t ext4` needed. Attach a disk and it appears in Finder under its
own label; writes, symlinks and extended attributes all work through it, and
the Linux kernel reads the result back byte-for-byte with a silent log.

This was blocked on Paragon's ExtFS, which was winning the probe. With it out
of the way our module claims the media.

**`diskutil eject` fails on whole-disk images** — but so does Apple's own
exFAT module on the same kind of device, while a *partitioned* exFAT ejects
fine. It is a property of whole-disk raw images, not this driver. `umount(8)`
works either way.
