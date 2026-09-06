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

## 2. Open it once, and let the Setup Assistant do the rest

Open Ext4Mac. It has no window of its own — it lives in the menu bar as a
small drive icon — and on first launch the **Setup Assistant** appears and
walks the whole thing:

<!-- screenshot: docs/images/setup-assistant.png -->

| step | what it does |
|---|---|
| Approve the extension | opens the right pane and then watches for the switch, telling you when it lands |
| Keep it working after a restart | starts Ext4Mac at login, which is what keeps the extension registered |
| Let Ext4Mac tell you things | notification permission, so a locked or refused volume is reported when it happens |
| Disk Utility (optional) | adds ext2/3/4 to the Erase menu, with the standard administrator prompt. See the note below on what it can and cannot erase |
| Try it on a real volume | mounts a small ext4 volume that ships inside the app, so you see the driver working before risking a disk |
| Where Ext4Mac lives | points at the menu-bar icon and opens its menu |

Nothing in it is compulsory except the approval, and every step can be done
later from the menu-bar icon → **Setup Assistant…**. From a terminal:

```bash
/Applications/Ext4Mac.app/Contents/MacOS/Ext4Mac setup           # open it
/Applications/Ext4Mac.app/Contents/MacOS/Ext4Mac setup --check   # just the checklist
```

`setup --check` prints one line per item and exits 1 when something is
missing, which makes it usable from a script.

## 3. Approve the extension

macOS never lets an app approve its own filesystem extension. The Setup
Assistant opens the right pane for you and watches for the switch; if it did
not, go to

**System Settings → General → Login Items & Extensions → File System
Extensions**

and turn on **open_ext4 (ext2/3/4)**.

<!-- screenshot: docs/images/approve-extension.png -->

If the list is EMPTY rather than showing an unlit switch, the extension is not
registered at all: macOS registers it when the app runs, so open Ext4Mac from
`/Applications` and look again. The assistant tells these two apart and says
which one you have.

Until this switch is on, every ext4 disk you plug in is reported by macOS as
*"The disk you inserted was not readable by this computer."* — the same
sentence it uses for a genuinely broken disk. Check with:

```bash
/Applications/Ext4Mac.app/Contents/MacOS/Ext4Mac status
```

which prints `status: enabled` when the switch is on and `registered but
DISABLED` when it is not.

### What Disk Utility can erase as ext4

Disk images: yes. A physical disk: no, and no amount of authenticating
changes it. The erase ends with

```
newfs_fskit: Operation ended with error: Permission denied
File system formatter failed. : (-69832)
```

because macOS runs the formatter as the logged-in user while a physical
disk's device node belongs to `root:operator` with mode 0640 — group members
may read it, nobody but root may write it. `fskitd` refuses before this
driver is ever asked.

Ownership is the whole obstacle, and you can lift it for one disk. Take the
two nodes for the partition you are erasing, then erase as usual:

```bash
sudo chown $(id -u) /dev/disk4s2 /dev/rdisk4s2   # your disk's numbers
```

Measured on 2026-09-06: the same Disk Utility erase that had failed then
succeeded, the volume mounted immediately with no replug, and `e2fsck -fn`
found nothing wrong. Two things to understand before using it. While you own
the node, anything running as you can write to that whole partition, so name
the exact disk and do it only when you mean to erase it. And the ownership
reverts the moment the disk is replugged or the Mac reboots, which makes this
a way to erase one disk, not a change to how your system works.

The alternative, which needs no such thing: format it on a Linux machine, or
from a source checkout of this project, which writes the raw node directly as
root:

```bash
sudo make prepare-device DEVICE=diskN CONFIRM=ERASE
```

Then unplug the disk and plug it in again. DiskArbitration caches its verdict
and will keep reporting "no file system" until the device reappears — a direct
format is invisible to it until then. An erase through Disk Utility does not
need the replug, because it went through FSKit and DiskArbitration watched it
happen.

## 3a. Prove it without a disk

The app carries a small ext4 volume of its own. The **Try it** step of the
assistant mounts it, or from a terminal:

```bash
/Applications/Ext4Mac.app/Contents/MacOS/Ext4Mac selftest --mount
```

It attaches the image, lets macOS mount it through the extension, reads a file
back and ejects it. Exit 0 means the install works end to end; 77 means the
extension is not approved yet.

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

An upgrade that loses the approval is what the Setup Assistant is for: it
opens by itself on the next launch, at the approval step, and closes again
when the switch is back on. If macOS has forgotten the module entirely — an
empty File System Extensions list rather than an unlit switch — opening
Ext4Mac from `/Applications` re-registers it, and the assistant says which of
the two happened.

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
