//
//  IdentityMapper.swift
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Presents Linux ownership in terms macOS can work with.
///
/// An ext4 volume records Linux uid/gid values that mean nothing on this Mac:
/// a disk from a Linux box will typically be owned by uid 1000, which is not
/// the local user, so Finder would refuse almost every operation and the volume
/// would appear broken.
///
/// The default therefore follows Apple's own msdos/exfat behaviour: present
/// everything as owned by the user who mounted the volume. The real on-disk
/// uid/gid are preserved and written back unchanged, so a disk that round-trips
/// through macOS still looks correct when it is plugged back into Linux.
struct IdentityMapper {

    /// Ownership presented to macOS.
    let presentedUID: UInt32
    let presentedGID: UInt32

    /// When true, report the true on-disk uid/gid instead of the mapped ones.
    let honorOwners: Bool

    /// Permission bits OR-ed into what is reported, so the mounting user can
    /// always traverse and read their own volume.
    private let minimumMode: UInt32 = 0o700

    init(uid: UInt32 = UInt32(getuid()),
         gid: UInt32 = UInt32(getgid()),
         honorOwners: Bool = false) {
        self.presentedUID = uid
        self.presentedGID = gid
        self.honorOwners = honorOwners
    }

    func uid(onDisk: UInt32) -> UInt32 { honorOwners ? onDisk : presentedUID }
    func gid(onDisk: UInt32) -> UInt32 { honorOwners ? onDisk : presentedGID }

    func mode(onDisk: UInt32, isDirectory: Bool) -> UInt32 {
        guard !honorOwners else { return onDisk }
        // Grant the owner full access, but keep the group/other bits so the
        // original Linux permissions remain visible.
        var m = onDisk | minimumMode
        if isDirectory { m |= 0o100 }   // a readable directory must be traversable
        return m
    }
}
