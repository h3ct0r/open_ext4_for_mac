# Manual QA: the Setup Assistant

What `make test-setup` cannot check. The suite drives the checklist from stated
facts and mounts the sample volume, but nobody has ever seen the window in
those runs: no dot changes colour, no administrator prompt appears, and the
menu-bar icon never blinks. This is the list a person walks before a release
that touched the first-run path.

Run it on a **fresh macOS user account** — not the development one. A
development account has the extension approved, the login item set and the
Disk Utility bundle installed, which is exactly the state the assistant is
written for and the one state it is never seen in by a new user.

## Setting up the account

1. System Settings → Users & Groups → Add User (Standard is fine).
2. Log in as that user. Do **not** copy anything across.
3. Mount the release DMG and drag Ext4Mac to `/Applications`.

## The walk

| # | do | expect |
|---|---|---|
| 1 | Open Ext4Mac from Applications | the Setup Assistant opens; **Approve** is the first red dot; the menu-bar icon is already there |
| 2 | Click **Open System Settings** | the File System Extensions pane opens; the window says "Watching for the switch… (n s)" and the seconds climb |
| 3 | Turn on **open_ext4 (ext2/3/4)** | within about two seconds the dot goes green and the window says ext4 is ready |
| 4 | Continue → **Start at Login** | dot green; System Settings → General → Login Items lists Ext4Mac |
| 5 | Continue → **Allow Notifications** | exactly ONE system dialog; allowing turns the dot green |
| 6 | Continue → **Skip** on Disk Utility | dot grey, no error, and the wizard moves on |
| 7 | Continue → **Mount the sample volume** | the Finder opens on *Ext4Mac Sample* with README.txt in it; the window says where it is mounted |
| 8 | Copy a file into it, then **Eject the sample volume** | it disappears from the Finder; `hdiutil info` lists no `ext4mac-sample` image |
| 9 | Continue → **Show me** | the menu-bar icon blinks three times and takes the accent colour, a callout appears beside it, and the menu opens when you click the callout's button |
| 10 | Close the menu | the second callout appears; **Done** moves to the last step |
| 11 | **Finish** | the window closes with no further question |
| 11a | Reopen it, stop on any middle step, and close the window | a dialog: "Finish setting up Ext4Mac?", naming the steps not seen yet, with **Keep Setting Up** as the default button |
| 11b | Reopen, turn the extension OFF in System Settings, then close the window | the same dialog, headed "Ext4Mac will not mount anything yet" and listing the approval |
| 11c | Click **Keep Setting Up**, mount the sample volume, then close the window again | the dialog names the mounted sample volume as something that will be ejected |
| 11d | Walk to the last step, press **Finish**, reopen from the menu and close it | no dialog: a setup finished once is not asked about again |
| 11e | While the window is open, press ⌘-Tab and look at the Dock | Ext4Mac is in both, with its own icon. It is an accessory app the rest of the time, so this is the one moment it should appear |
| 11f | Close the window and look again | the Dock tile is gone and only the menu-bar icon remains |

Then the parts that are about not being a nuisance:

| # | do | expect |
|---|---|---|
| 12 | Quit and reopen Ext4Mac | no window. It is done. |
| 13 | Menu-bar icon → **Setup Assistant…** | it opens again, everything green |
| 14 | Menu-bar icon → **Add to Disk Utility…** step, then open Disk Utility | ext4 appears in the Erase menu's format list |
| 15 | Turn the extension OFF in System Settings, quit and reopen Ext4Mac | the window opens at the approval step |
| 16 | Close it without approving, then quit and reopen | no window — dismissed for this build — and the menu header says "registered, not approved" |
| 17 | `defaults delete dev.h3ct0r.ext4mac`, re-approve, quit and reopen | no window: a working install is never walked through |
| 18 | `make install` (a new build), quit and reopen with the extension approved | still no window |

## Disk Utility, if a disposable disk is to hand

Erasing a physical disk as ext4 failed until 2026-09-07, so it is worth one
pass on every release that touches the `.fs` bundle. **This erases the disk.**

| # | do | expect |
|---|---|---|
| 19 | Setup Assistant → Disk Utility step | "Add to Disk Utility…" on a clean machine, "Update Disk Utility Support…" if an older copy is installed |
| 20 | Click it and authenticate once | `diskutil listFilesystems` lists EXT2, EXT3 and EXT4 |
| 21 | In Disk Utility, select a disposable **physical** disk, Erase, choose ext4 | it succeeds and mounts by itself, with no terminal and no second prompt |
| 22 | `ls -l /dev/diskNsM` afterwards | still `root:operator`: the fix changes no ownership |
| 23 | First Aid on that volume | it runs instead of failing to open the device |
| 24 | `e2fsck -fn /dev/diskNsM` after unmounting | clean |

If step 21 fails with `-69832`, the installed bundle is older than the app.
That is what step 19's "Update" button is for, and `Ext4Mac setup --check`
says so in words.

## Everything twice

- **Dark mode.** System Settings → Appearance → Dark, then walk steps 1–11
  again. Look for text on a background it does not contrast with, and for the
  green/amber banners.
- **VoiceOver** (⌘F5). Every button must be reachable by Tab and announce
  something that says what it does. The checklist dots are decoration: the row
  must read as its step name, not "image".

## What to do with what you find

A step that reads badly is a docs bug and a wording fix, not a code change:
edit the copy, rebuild, walk that step again. A step that lies about the
machine is a checklist bug — reproduce it with `Ext4Mac setup --check --given
…` first, add the cell to `Tests/run_setup_tests.sh`, watch it fail, then fix
it. That is the rule for this repository and this window is not an exception.
