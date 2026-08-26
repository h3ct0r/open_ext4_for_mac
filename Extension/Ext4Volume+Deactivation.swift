//
//  Ext4Volume+Deactivation.swift
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FSKit
import Ext4Core

/// The last-close notification for items FSKit has been holding on our behalf.
///
/// This is VFS's `VNOP_INACTIVE`: the kernel has stopped making immediate use
/// of an item, but has not necessarily finished with it. It pairs with
/// `enableOpenUnlinkEmulation` — an unlinked-but-open file stays in the
/// namespace until here.
extension Ext4Volume: FSVolume.ItemDeactivation {

    /// Only for open-unlinked files. Asking for `.always` would add a round
    /// trip to every item the kernel finishes with, and we have nothing to do
    /// for the ordinary case that `reclaimItem` does not already handle.
    var itemDeactivationPolicy: FSVolume.ItemDeactivationOptions { .forRemovedItems }

    func deactivateItem(_ item: FSItem) async throws {
        guard let ext4Item = item as? Ext4Item else { return }
        // The point of asking for .forRemovedItems: this is the moment an
        // open-unlinked file's last user goes away, so the inode we held back
        // in removeItem can finally be freed.
        await releaseIfPending(ext4Item.inode)
        // Dropping the cached item here is safe and idempotent: reclaimItem
        // does the same, and a later lookup rebuilds it from the inode.
        forget(ext4Item)
    }
}
