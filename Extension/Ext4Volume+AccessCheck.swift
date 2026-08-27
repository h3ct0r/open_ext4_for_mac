//
//  Ext4Volume+AccessCheck.swift
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FSKit
import Ext4Core

/// Answering "may I?" before the operation is attempted.
///
/// The driver already refuses the things below — a write to an immutable file
/// returns `EPERM`, a write to a read-only volume returns `EROFS` — but it
/// refuses them at the point of the write. Without this protocol `access(2)`
/// has nothing to consult and answers yes, so Finder offers to rename a locked
/// file and only discovers otherwise when the rename fails, and a shell script
/// guarding with `[ -w file ]` guards nothing.
///
/// What is *not* checked here is ownership, and that is deliberate rather than
/// missing. These volumes mount `noowners`: macOS applies it to foreign and
/// removable media because a uid written on someone else's Linux box means
/// nothing here, so VFS presents every file as owned by the mounting user and
/// disregards the mode bits. Re-imposing ext4's uid, gid and mode on top would
/// contradict the mount options the volume is actually mounted with, and would
/// lock the user out of their own disk on the strength of a number that
/// happens to match a different machine's account.
///
/// So this answers only for the things that are true regardless of who is
/// asking: the volume being read-only, and the two ext4 inode flags this
/// driver enforces. Everything else defers to VFS, which is the layer that
/// knows about credentials.
extension Ext4Volume: FSVolume.AccessCheckOperations {

    /// Writes that change a file's contents or its metadata.
    ///
    /// `FSAccessAppendData` is absent on purpose: appending is exactly what an
    /// append-only file permits, and it is handled separately below.
    private static let writeAccess: FSVolume.AccessMask = [
        .writeData, .delete, .deleteChild,
        .writeAttributes, .writeXattr, .writeSecurity, .takeOwnership,
    ]

    func checkAccess(to item: FSItem,
                     requestedAccess access: FSVolume.AccessMask) async throws -> Bool {
        guard let ext4Item = item as? Ext4Item else { throw Ext4Error.invalid }

        let wantsWrite  = !access.isDisjoint(with: Self.writeAccess)
        let wantsAppend = access.contains(.appendData)

        // Nothing that writes is possible on a read-only mount, whatever the
        // inode says. This is also the answer for removable media mounted
        // read-only by policy, which is the common case.
        if isReadOnly && (wantsWrite || wantsAppend) {
            return false
        }
        guard wantsWrite || wantsAppend else {
            return true      // reads, execution and attribute lookups
        }

        // Answer without the core once the volume is closing.
        //
        // FSKit asks this after `unmount` has already closed the volume -- the
        // same ordering that made the `device` accessor fallible in the first
        // place, when `synchronize` was found arriving too late. Throwing here
        // does not just fail the check: it fails the *unmount*, and the volume
        // stays mounted. Costs 24 of 24 freeze/resume cycles to notice, and
        // the symptom is a busy mount rather than anything mentioning access.
        //
        // A closing volume is not the place to enforce a flag. Say yes and let
        // VFS deal with it; the write paths refuse independently anyway.
        guard deviceIfOpen != nil else { return true }

        let attrs = try await executor.run { [self] in
            guard let dev = deviceIfOpen else { throw Ext4Error.invalid }
            var a = ext4b_attrs()
            try Ext4Error.check(ext4b_getattr(dev, ext4Item.inode, &a),
                                "getattr(\(ext4Item.inode))")
            return a
        }

        // `chattr +i`: nothing may change, including an append.
        if attrs.flags & EXT4B_INODE_IMMUTABLE != 0 {
            return false
        }

        // `chattr +a`: appending is allowed, and only appending. A caller
        // asking for both gets refused, because the write half is refused.
        if attrs.flags & EXT4B_INODE_APPEND_ONLY != 0 {
            return !wantsWrite
        }

        return true
    }
}
