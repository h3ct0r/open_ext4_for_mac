<!-- Moved from docs/STATUS.md on 2026-09-04; content unchanged apart from heading levels. -->

# Writing

Implemented and passing: create, mkdir, symlink, hard link, unlink, rmdir,
rename (including across directories, over an existing file, and moving a
non-empty directory), write, append, multi-block writes, truncate both
directions, sparse regions, chmod/chown/times, and xattr set/remove.

Each operation is a single JBD2 transaction that either commits or aborts
leaving the volume untouched.

**A healthy volume mounts read-write by default, and `-o ro` opts out.**
Read-only is honoured properly — the mount is marked read-only at the VFS
layer, writes are refused, and the volume is not touched at all: no journal
replay, no superblock update. Measured by hashing the image either side of a
mount:

```
before any mount:      clean
while mounted -o ro:   clean          image byte-identical: YES
while mounted (rw):    not clean      image byte-identical: NO
```

One consequence is worth knowing. A volume with an unreplayed journal still
mounts read-only, and stays untouched — which means the journal is *not*
replayed and you are looking at the volume as of the last checkpoint, not the
last committed transaction. Linux replays even on a read-only mount unless you
pass `norecovery`; it can, because it is allowed to write. Mount read-write, or
run `e2fsck`, to see the recovered state.

The reverse — mounting read-write something the driver has rated read-only — is
not offered, and deliberately so. Unsupported features, a dirty journal that
would not replay, or a `metadata_csum_seed` that no longer matches the UUID all
force read-only, and those are exactly the cases where writing is how a volume
gets destroyed.

## Mount options

An earlier version of this document said mount options never reach the module.
That was wrong, and wrong in an instructive way: it was measured at
`mount(options:)`, whose own header says *"there are no defined options
currently"* — which is true of that callback and of no other. `loadResource`
is empty too, despite its header documenting `-f` and `--rdonly`.

They arrive at **`activate(options:)`**, and only because `Info.plist` declares
`FSActivateOptionSyntax` — the same key Apple's `msdos` module uses for its
`-u/-g/-m/-o`. Measured against a live mount:

| `mount -F -t ext4 …` | what `activate` receives |
|---|---|
| *(no options)* | `[]` |
| `-o ro` | `["-o", "ro"]` |
| `-r` | `["-o", "ro"]` — `mount(8)` normalises it |
| `-o rw` | `["-o", "rw"]` |
| `-o ro,noatime` | `["-o", "ro", "-o", "noatime"]` |

So a comma list is split into repeated `-o value` pairs, and everything the
user typed comes through.

What this does **not** buy is a way to change how the volume was opened.
`activate` runs after `loadResource`, and `loadResource` is where the journal
gets replayed and `VALID_FS` cleared — by the time an option is legible, any
writing has happened. Read-only works regardless, because it travels by a
different road: FSKit marks the resource non-writable and `loadResource` reads
*that*.

The options are therefore not acted on today. The one thing they could add is
defence in depth — refusing to activate if `ro` was asked for and the volume
somehow came up writable — which is worth doing but is not a behaviour change.

## Files Linux marked as protected

`chattr +i` and `chattr +a` are how a Linux user says *do not change this*. A
driver that ignores them removes the protection silently, and the user finds
out when the file is gone — so every mutating entry point checks:

| | what is refused |
|---|---|
| immutable | writes, truncate, chmod/chown/times, xattrs, rename, hard link, and removal — and, for a directory, gaining or losing any entry |
| append-only | truncate, removal, rename, xattrs, and any write that lies wholly inside the file |

They are reported to macOS as `UF_IMMUTABLE` and `UF_APPEND`, which are exactly
the same two ideas in the BSD vocabulary, so `ls -lO` shows `uchg` / `uappnd`
and Finder shows the file as locked. That matters more than it sounds: it turns
an unexplained *Operation not permitted* into something the user can see the
reason for. macOS then does the enforcement itself — an append-only file cannot
even be **opened** for ordinary writing.

Which is what makes the obvious rule for append-only the wrong one. Requiring a
write to start at end-of-file refuses real appends: the buffer cache rewrites
whole pages, so appending five bytes to a five-byte file arrives as a ten-byte
write at offset zero. That was measured on a live mount, not reasoned about,
and the check is now the one no cache produces — a write that lies entirely
inside the file and does not reach its end.

Setting or clearing the flags is not supported. lwext4 offers no way to rewrite
the inode's flags word, and on Linux only root may clear either flag in any
case. A `chflags` that would really change something is refused rather than
reported as a success that did not happen; use `chattr -i` on Linux.

## How it is tested

`e2fsck` runs after **every** mutating operation, not once at the end — a write
path that corrupts and then repairs two operations later still loses data on
power failure. Results are cross-checked against `debugfs`, an independent
implementation, so the suite cannot agree with a bug in our own reader.

`make test-asan` reruns everything under AddressSanitizer and UBSan. That is
how two genuine lwext4 defects were found; see `patches/lwext4/README.md`.
