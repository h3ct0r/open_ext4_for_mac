# Installing Ext4Mac

For people who want to plug in a Linux disk and have it mount. If you are
building from source, the README's *Building from source* section and
[SIGNING.md](SIGNING.md) are for you; come back here for the approval step,
which is the same either way.

## 1. Install

Download `Ext4Mac-x.y.z.dmg` from the
[Releases page](https://github.com/h3ct0r/open_ext4_for_mac/releases), open
it, and drag **Ext4Mac** into `/Applications`. It must live in
`/Applications`: macOS discovers filesystem extensions through an installed
application bundle, and one run from `~/Downloads` is not installed.

<!-- screenshot: docs/images/install-dmg.png -->

## 2. Open it once

Open Ext4Mac. It has no window — it lives in the menu bar as a small drive
icon — and on first launch it does two things: registers the filesystem
extension with macOS, and asks whether to start at login.

Say yes to starting at login. The extension stays registered only while the
app has run since boot; without the login item, ext4 disks stop mounting
after a restart until you open Ext4Mac again. You can change it later with
`Ext4Mac login-item on|off`.

## 3. Approve the extension

macOS never lets an app approve its own filesystem extension. Ext4Mac opens
the right pane for you; if it did not, go to

**System Settings → General → Login Items & Extensions → File System
Extensions**

and turn on **open_ext4 (ext2/3/4)**.

<!-- screenshot: docs/images/approve-extension.png -->

Until this switch is on, every ext4 disk you plug in is reported by macOS as
*"The disk you inserted was not readable by this computer."* — the same
sentence it uses for a genuinely broken disk. Check with:

```bash
/Applications/Ext4Mac.app/Contents/MacOS/Ext4Mac status
```

which prints `status: enabled` when the switch is on and `registered but
DISABLED` when it is not.

## 4. Plug in a disk

An ext2, ext3 or ext4 disk mounts by itself and appears in Finder under its
own label. Encrypted (LUKS) disks show up as *LUKS Encrypted Volume* and the
menu-bar icon asks for the passphrase; after that the volume mounts by
itself every time, under the name of the filesystem inside.

<!-- screenshot: docs/images/luks-prompt.png -->

**Eject before unplugging.** Finder's eject, or `diskutil eject`. The driver
keeps a journal, but FSKit gives it no way to flush the drive's own cache,
and a pull mid-write can panic macOS itself. The reasons and measurements are
in [ENVELOPE.md](ENVELOPE.md#the-barrier-what-this-driver-cannot-promise).

## When it looks broken

Every one of these looks like "the disk is not readable" from the outside.
They are told apart in one command:

```bash
Ext4Mac last-error /dev/disk6        # or the volume's UUID
```

It prints what the extension decided about that disk and what to do:

| what it says | meaning | next step |
|---|---|---|
| `locked` | an encrypted volume with no key stored | `Ext4Mac unlock /dev/disk6`, or click the menu-bar icon |
| `keyRejected` | a stored key no longer opens it (passphrase changed?) | `Ext4Mac forget /dev/disk6`, then unlock again |
| `refused` | a feature this driver will not touch, or a damaged superblock; the message names which | run `e2fsck` on a Linux machine; see [ENVELOPE.md](ENVELOPE.md) for the feature policy |
| `degradedReadOnly` | mounted, but read-only, and it says why | usually read-only media or a feature this driver reads but will not write |
| `unformatted` | nothing recognisable on the disk | format it if that is what you meant: `newfs_fskit -t ext4 /dev/disk6` |
| `no event recorded` | the extension was never asked about this disk | the extension is probably disabled — see below |

Other things that produce the same symptom:

- **The extension is disabled.** `Ext4Mac status` says so. Turn it on in
  System Settings (step 3). A fresh install, a wholesale reinstall, or an
  app update by drag-and-drop can each reset this switch; it is macOS's
  switch, and no command can flip it.
- **Paragon ExtFS (or another ext driver) is installed.** Its driver claims
  the disk first and this one never sees it. Disable or uninstall the other
  driver.
- **DiskArbitration is wedged.** After a lot of unplugging and replugging, or
  a driver crash, macOS can start refusing to mount anything through FSKit
  even though the extension is fine — `mount` works, Finder does not. Replug
  the disk; if that does not clear it, a reboot does. (`sudo launchctl
  kickstart` on the responsible daemons is blocked by SIP.)

## Upgrading

Replace the app in `/Applications` with the new one and open it once. Expect
to approve the extension again: replacing the whole bundle changes every
file's identity and macOS treats it as a new extension. Volumes mounted by
the old version keep being served by it until you eject and replug them.

## Uninstalling

Everything an install creates, named and removed:

```bash
DRY_RUN=1 bash scripts/uninstall.sh              # shows what would go
EXT4_UNINSTALL_FOR_REAL=1 bash scripts/uninstall.sh
```

or `make uninstall` from a checkout (a dry run unless
`EXT4_UNINSTALL_FOR_REAL=1`). It ejects mounted ext volumes, turns the login
item off, forgets every stored LUKS key, deregisters the extension, and
removes the app, its two containers, its preferences, the Disk Utility
bundle under `/Library/Filesystems`, and the retired barrier daemon if an
older build left one.

If you only have the DMG and no checkout: eject your ext volumes, run
`Ext4Mac forget --all --yes` and `Ext4Mac login-item off`, then delete
`/Applications/Ext4Mac.app`. The two containers under
`~/Library/Containers/dev.h3ct0r.ext4mac*` can go too.

## Command reference

`/Applications/Ext4Mac.app/Contents/MacOS/Ext4Mac <verb>`:

| verb | |
|---|---|
| `status` | extension state; every volume with something to report |
| `last-error <disk\|uuid>` | why a disk did not mount, and what to do |
| `events [n]` | the last *n* events across all volumes |
| `unlock <disk>` | prompt for a passphrase; keep the master key in the keychain |
| `mount <disk>` | mount an unlocked volume now |
| `forget <disk>` | forget its key; `forget --all` lists, `--yes` removes |
| `list` | which encrypted volumes are unlocked |
| `login-item on\|off` | start at login |
| `version` | which build is installed |
| `selftest` | what this build can check about itself (key locking) |
