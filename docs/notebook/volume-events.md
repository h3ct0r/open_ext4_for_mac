<!-- Moved from docs/STATUS.md on 2026-09-04; content unchanged apart from heading levels. -->

# What the extension says when it will not mount

FSKit's whole failure vocabulary reaches the person as one sentence -- "The
disk you inserted was not readable by this computer." -- whether the volume
uses a feature this driver refuses, carries a journal it would not replay, is
damaged, or is a LUKS container nobody has unlocked. The last of those is not
a fault at all, and it looks exactly like a broken disk.

The extension cannot say anything itself: no window, no notification, and
`os_log` lines that only somebody streaming the log on purpose will see. So
it writes down what happened, and the app reads it. One JSON file per volume
under the extension's own container
(`…/Containers/dev.h3ct0r.ext4mac.Ext4FS/Data/Library/Application Support/events/`,
keyed by UUID, or by BSD name when the volume could not be read that far),
plus `events.log`, one line per event, rotated at 256 KiB. Written inside the
sandbox, read from outside -- the channel `LUKSKeyStore` already proved. No
IPC, on purpose: it works when the agent was not running at the time, because
the file is still there.

Kinds, each a different next step: `refused` (a feature in the table as
refused, or a superblock whose checksum does not match), `degradedReadOnly`
(mounted, but not read-write, with the reason), `replayRefused` (a read-write
mount whose journal would not replay), `mountFailed`, `unmountFailed` (the
final write-back failed -- the one that says "do not pull the stick yet"),
`locked` (a LUKS container with no key), `keyRejected` (a stored key that no
longer opens it), `unformatted`. Each record carries the probe verdict, the
last eight error-level lines from the C core -- which is where "read-only
mount of an unreplayed journal: contents predate the last crash" now ends up
-- and the build that wrote it.

Reading it: `Ext4Mac last-error <disk|uuid>` prints the record and what to do
about it; `Ext4Mac events [n]` the recent history; `Ext4Mac status` lists
every volume with something to report. The menu-bar agent watches the
directory and turns a new record into a notification, and keeps the last ten
under "Recent Issues".

Three things the mounted cells taught, none of them visible offline:

- **fskitd loads every volume read-only once before it mounts it** -- the
  check pass -- in a process of its own, and that load never activates.
  Reporting "read-only" at load time recorded a degraded event for every
  normal mount of every dirty stick, moments before the real mount replayed
  the journal and succeeded. The report now happens in `activate`, which
  only an actual mount reaches.
- **A declined volume could not be ejected** for as long as the idle probe
  process lived, minutes, with "Resource busy" -- for a disk this driver had
  just refused to touch. The resource arrives with the device open and the
  descriptor lives as long as the object; `lastSeen`, kept for `startFormat`,
  kept a declined one alive. `lsof` on the extension process showed
  `/dev/rdiskN`; the descriptor went away with the reference, and
  `FSResource.revoke()` on its own freed nothing. Dropped on decline now; a
  format or check arrives after a load, which brings a resource of its own.
- **An unmount failure cannot be provoked from outside on this platform.**
  Three tries: `hdiutil detach -force` (the kernel unmounts cleanly first),
  a shadow file on a full volume (the writes were absorbed), and the image's
  backing volume force-detached from under it (a real pull: every read got
  EIO). Even then `ext4b_unmount` returned 0, because a revoked block device
  reports success for writes and fails only reads. The `unmountFailed` site
  fires on a non-zero return -- it did, once, unprovoked, when a concurrent
  check-load made the mounted process's device return EIO during the newfs
  suite -- but no cell can make it happen on demand, so there is none.

`Tests/run_events_tests.sh` (stage 5e) has the offline half -- the store,
the schema, the sanitising, rotation, torn-read protection, the reader -- and
the mounted half, which attaches an inline_data image, an unstamped
superblock edit, a dirty journal on read-only media and a LUKS container with
no key, and reads what the installed extension wrote through the installed
app with no directory argument. It runs only where the extension is enabled
and says so where it is not. Against the extension before this work the
mounted cells failed 11 of 11, with no file to read; after it, 36 of 36 pass.
