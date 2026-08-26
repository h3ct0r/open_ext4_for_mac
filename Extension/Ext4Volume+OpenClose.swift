//
//  Ext4Volume+OpenClose.swift
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FSKit
import Ext4Core

/// Tracking which files are open, so that `removeItem` knows whether it is
/// safe to free an inode immediately.
///
/// ext4 frees an inode the moment its last link goes away. That is right for a
/// file nobody has open and wrong for one that is: the kernel keeps using the
/// descriptor afterwards, and writes through it would allocate blocks onto an
/// inode nothing references.
///
/// Deferring *every* delete would fix that and cost something worse: the inode
/// would sit with no links and no owner for as long as it takes FSKit to
/// reclaim it, widening the window in which a power cut leaves blocks marked in
/// use with nothing pointing at them. So the deferral is confined to the case
/// that actually needs it — a file nobody has open is freed immediately.
///
/// The window that remains is covered on the medium rather than in memory: a
/// deferred inode goes on ext4's orphan list, so a crash while one exists is
/// recoverable by the next mount (see `ext4b_orphan_cleanup`), by `e2fsck`, or
/// by Linux.
extension Ext4Volume: FSVolume.OpenCloseOperations {

    func openItem(_ item: FSItem, modes: FSVolume.OpenModes) async throws {
        guard let ext4Item = item as? Ext4Item else { throw Ext4Error.invalid }
        withItems { openCounts[ext4Item.inode, default: 0] += 1 }
    }

    func closeItem(_ item: FSItem, modes: FSVolume.OpenModes) async throws {
        guard let ext4Item = item as? Ext4Item else { throw Ext4Error.invalid }

        let remaining = withItems { () -> Int in
            let left = (openCounts[ext4Item.inode] ?? 0) - 1
            if left > 0 {
                openCounts[ext4Item.inode] = left
            } else {
                openCounts.removeValue(forKey: ext4Item.inode)
            }
            return left
        }

        // Last close of a file that was unlinked while open: this is the moment
        // its inode can finally go.
        if remaining <= 0 {
            await releaseIfPending(ext4Item.inode)
        }
    }
}
