//
//  IdentityMapper.swift
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FSKit

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

    /// Minimum owner permissions reported, so the mounting user can always
    /// reach their own volume. Note this differs by type: granting execute on
    /// a regular file would make every file on the volume look runnable, so
    /// files get rw and only directories get the traverse bit.
    private let minimumFileMode: UInt32 = 0o600
    private let minimumDirMode: UInt32  = 0o700

    init(uid: UInt32 = UInt32(getuid()),
         gid: UInt32 = UInt32(getgid()),
         honorOwners: Bool = false) {
        self.presentedUID = uid
        self.presentedGID = gid
        self.honorOwners = honorOwners
    }

    func uid(onDisk: UInt32) -> UInt32 { honorOwners ? onDisk : presentedUID }
    func gid(onDisk: UInt32) -> UInt32 { honorOwners ? onDisk : presentedGID }

    /// Decide what actually gets stored on disk for a newly created object.
    ///
    /// The uid/gid written are the *presented* ones, so a file this Mac creates
    /// is owned by this Mac's user when the disk goes back to Linux. That is
    /// the least surprising outcome: the alternative, inheriting the parent
    /// directory's Linux owner, would create files the local user then could
    /// not modify under honorOwners.
    func onDiskCreationAttributes(requested: FSItem.SetAttributesRequest,
                                  isDirectory: Bool) -> (mode: UInt32, uid: UInt32, gid: UInt32) {
        let defaultMode: UInt32 = isDirectory ? 0o755 : 0o644
        let mode = requested.isValid(.mode) ? (requested.mode & 0o7777) : defaultMode
        let uid = requested.isValid(.uid) ? requested.uid : presentedUID
        let gid = requested.isValid(.gid) ? requested.gid : presentedGID
        return (mode, uid, gid)
    }

    func mode(onDisk: UInt32, isDirectory: Bool) -> UInt32 {
        guard !honorOwners else { return onDisk }
        // Grant the owner access, but keep the group/other bits so the original
        // Linux permissions stay visible.
        return onDisk | (isDirectory ? minimumDirMode : minimumFileMode)
    }
}
