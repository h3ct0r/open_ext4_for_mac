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
/// Deferring *every* delete would fix that and cost something worse. The inode
/// then sits with no links and no owner for as long as it takes FSKit to
/// reclaim it, and a power cut inside that window leaves blocks marked in use
/// with nothing pointing at them — which the crash-consistency suite catches as
/// `Block bitmap differences`. ext4 solves this with an on-disk orphan list;
/// lwext4 has none, and adding one is a larger job than it looks because the
/// modern `orphan_file` feature changes where the list lives.
///
/// So the deferral is confined to the case that actually needs it. A file
/// nobody has open is freed immediately, exactly as before.
extension Ext4Volume: FSVolume.OpenCloseOperations {

    func openItem(_ item: FSItem, modes: FSVolume.OpenModes) async throws {
        guard let ext4Item = item as? Ext4Item else { throw Ext4Error.invalid }
        itemsLock.lock()
        openCounts[ext4Item.inode, default: 0] += 1
        itemsLock.unlock()
    }

    func closeItem(_ item: FSItem, modes: FSVolume.OpenModes) async throws {
        guard let ext4Item = item as? Ext4Item else { throw Ext4Error.invalid }

        itemsLock.lock()
        let remaining = (openCounts[ext4Item.inode] ?? 0) - 1
        if remaining > 0 {
            openCounts[ext4Item.inode] = remaining
        } else {
            openCounts.removeValue(forKey: ext4Item.inode)
        }
        itemsLock.unlock()

        // Last close of a file that was unlinked while open: this is the moment
        // its inode can finally go.
        if remaining <= 0 {
            await releaseIfPending(ext4Item.inode)
        }
    }
}
