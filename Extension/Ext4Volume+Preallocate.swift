//
//  Ext4Volume+Preallocate.swift
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FSKit
import Ext4Core

/// `fcntl(F_PREALLOCATE)`, answered the way ext4 answers it: UNWRITTEN
/// extents. Allocated and counted, excluded from reads (they see zeros), and
/// converted to ordinary written extents by the first write into them. The
/// file's size does not move -- only its allocation does.
extension Ext4Volume: FSVolume.PreallocateOperations {

    func preallocateSpace(for item: FSItem,
                          at offset: off_t,
                          length: size_t,
                          flags: FSVolume.PreallocateFlags) async throws -> Int {
        guard let ext4Item = item as? Ext4Item else { throw Ext4Error.invalid }
        try requireWritable()
        guard length > 0 else { return 0 }

        // The SDK is explicit: FromEOF "is currently set for all
        // preallocateSpace calls", and with it the offset is to be ignored --
        // the space goes at the file's physical end. Physical, not logical:
        // repeated calls must not re-cover the same already-preallocated
        // range, and allocated-past-EOF is exactly what alloc_size tracks.
        let allocated = try await executor.run { [self] in
            var a = ext4b_attrs()
            try Ext4Error.check(ext4b_getattr(try device, ext4Item.inode, &a),
                                "getattr(\(ext4Item.inode))")
            let start = max(a.size, a.alloc_size)
            var got: UInt64 = 0
            try Ext4Error.check(
                ext4b_preallocate(try device, ext4Item.inode,
                                  start, UInt64(length), &got),
                "preallocate(\(ext4Item.inode) +\(length))")
            return Int(got)
        }

        // Without the persist flag the space is on loan: FSKit deactivates
        // the item when its last user goes, and the trim there returns it.
        notePreallocation(ext4Item.inode, persistent: flags.contains(.persist))

        // alloc_size changed; the cached attributes are stale.
        ext4Item.invalidate()
        return allocated
    }
}
