//
//  Ext4Volume+Rename.swift
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FSKit
import Ext4Core

/// Renaming the volume, as Finder's "Rename" and `diskutil rename` do it.
///
/// The label lives in a fixed 16-byte superblock field, so this is a single
/// block write rather than anything the journal needs to be involved in. It is
/// written through immediately: a rename the user can see in Finder but that
/// disappears on power loss is worse than one that fails outright.
extension Ext4Volume: FSVolume.RenameOperations {

    /// A read-only volume cannot be renamed, and FSKit is better off knowing
    /// that up front than discovering it when the user has already typed a new
    /// name.
    var isVolumeRenameInhibited: Bool { isReadOnly }

    func setVolumeName(_ name: FSFileName) async throws -> FSFileName {
        try requireWritable()

        guard let data = name.data as Data?, !data.isEmpty else {
            throw Ext4Error.invalid
        }
        // ext4's label is 16 bytes of raw text. Anything longer has to be
        // refused rather than silently truncated -- a volume quietly named
        // something other than what was typed is its own kind of bug.
        guard data.count <= 16 else { throw Ext4Error.posix(ENAMETOOLONG) }
        // A NUL or a slash cannot round-trip through the field.
        guard !data.contains(0x00), !data.contains(0x2F) else {
            throw Ext4Error.invalid
        }

        try await executor.run { [self] in
            let dev = try device
            try data.withUnsafeBytes { raw -> Void in
                // The label is a C string to the core, and Data is not
                // NUL-terminated, so it is copied into a padded buffer.
                var buffer = [CChar](repeating: 0, count: 17)
                raw.withMemoryRebound(to: CChar.self) { src in
                    for i in 0..<src.count { buffer[i] = src[i] }
                }
                try Ext4Error.check(ext4b_set_label(dev, &buffer), "set label")
            }
        }

        Ext4Log.volume.info("volume renamed")
        return name
    }
}
