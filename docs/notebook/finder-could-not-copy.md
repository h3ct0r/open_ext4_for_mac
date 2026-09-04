<!-- Moved from docs/STATUS.md on 2026-09-04; content unchanged apart from heading levels. -->

# Finder could not copy files off an ext4 volume

`cp` worked. `ditto` and Finder did not, with *Input/output error*.

Between them, two bugs in the same call. macOS probes `com.apple.FinderInfo`
and `com.apple.ResourceFork` on essentially every file it copies, so
"this attribute is not set" is the most common extended-attribute answer a
driver gives — and this one was giving the wrong answer twice over.

**`EIO` for an inode that had never carried an attribute.** lwext4's
`ext4_xattr_is_ibody_valid()` folds "there is no header here" together with
"the header here is malformed" and reports `EIO` for both. The first is the
ordinary state of almost every file. Fixed by `patches/lwext4/0013`, which
separates them — absence is "not found", corruption is still `EIO`.

That error turned out to be **load-bearing**: `ext4_xattr_set()` used it as the
signal to initialise a header before writing the first attribute. Removing it
left the search context zeroed and the set path dereferenced NULL — a real
crash, found by the extension dying mid-copy on a live volume. It now asks
whether the header exists rather than inferring it from an error.

**`ENODATA` once the file did have a header.** That is Linux's name for the
condition, and lwext4 is right to use it. macOS calls it `ENOATTR` and gives
it a different number — 93 against 96. `getxattr(2)` on macOS never returns
`ENODATA`, so a caller switching on the errno falls through to its error path,
which is exactly what Finder does. Translated at the bridge, since lwext4 is
correct about Linux.

Both are covered in the write suite, and reverting 0013 turns the first red
with the original *Input/output error*.
