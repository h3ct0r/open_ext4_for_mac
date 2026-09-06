This is a real ext4 volume.

Ext4Mac mounted it through FSKit, the same way it will mount the Linux disks
you plug in: the same driver, the same journal, the same code that wrote every
byte here. Nothing about this volume is a simulation of the real thing.

Try it. Copy a file in, rename it, make a folder, delete something. It is an
ordinary disk to the Finder and to every program you have.

When you are done, eject it -- from the Setup Assistant, or from the Finder
sidebar, the way you would any other disk. The image itself lives inside
Ext4Mac.app and is copied fresh each time, so nothing you do here can be lost
and nothing you leave behind will come back.

One habit worth keeping, and the only one this driver asks of you: eject a
real drive before you unplug it. macOS gives a file system extension no way to
flush a drive's own cache, so pulling a disk mid-write is the one thing that
can still cost you data. Ejecting waits for the writes to land.
