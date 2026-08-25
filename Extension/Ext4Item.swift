//
//  Ext4Item.swift
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FSKit
import Ext4Core

/// One filesystem object, identified by its ext4 inode number.
///
/// FSKit hands these back to us on every subsequent operation, so the inode
/// number is the only state strictly required. Deliberately *not* stored: the
/// object's path. A path would be wrong for hard links (one inode, many paths)
/// and would silently go stale for every descendant when a directory is
/// renamed. Directory-entry names live on the entry, not the item.
final class Ext4Item: FSItem {

    /// ext4 inode number. Stable for the life of the object on disk, and used
    /// directly as FSKit's `fileID`.
    let inode: UInt32

    /// Cached attribute snapshot, refreshed on demand.
    private var cached: ext4b_attrs?
    private let lock = NSLock()

    /// Best known parent directory inode.
    ///
    /// FSKit insists on a parentID in every attribute response, but ext4 has no
    /// back-pointer for non-directories, and a hard-linked inode genuinely has
    /// several parents. We therefore record the directory an item was reached
    /// through. Directories are exact -- their ".." entry is authoritative and
    /// is resolved on demand.
    private var parentHint: UInt32 = UInt32(EXT4B_ROOT_INO)

    var parent: UInt32 {
        get { lock.lock(); defer { lock.unlock() }; return parentHint }
        set { lock.lock(); parentHint = newValue; lock.unlock() }
    }

    init(inode: UInt32) {
        self.inode = inode
        super.init()
    }

    var fileID: FSItem.Identifier { FSItem.Identifier(rawValue: UInt64(inode))! }

    func attributes(from volume: Ext4Volume) throws -> ext4b_attrs {
        lock.lock()
        if let cached {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let fresh = try volume.fetchAttributes(inode: inode)
        lock.lock()
        cached = fresh
        lock.unlock()
        return fresh
    }

    /// Drop the cached snapshot. Must be called after anything that changes the
    /// inode on disk, otherwise FSKit will keep reporting stale size or times.
    func invalidate() {
        lock.lock()
        cached = nil
        lock.unlock()
    }
}

extension ext4b_item_type {
    /// Map the core's type to FSKit's, which the kernel uses to decide which
    /// vnode operations are even legal on the object.
    var fsItemType: FSItem.ItemType {
        switch self {
        case EXT4B_TYPE_FILE:     return .file
        case EXT4B_TYPE_DIR:      return .directory
        case EXT4B_TYPE_SYMLINK:  return .symlink
        case EXT4B_TYPE_FIFO:     return .fifo
        case EXT4B_TYPE_CHARDEV:  return .charDevice
        case EXT4B_TYPE_BLOCKDEV: return .blockDevice
        case EXT4B_TYPE_SOCKET:   return .socket
        default:                  return .unknown
        }
    }
}
