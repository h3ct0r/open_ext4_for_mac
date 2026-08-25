//
//  Ext4Volume+ReadWrite.swift
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  The byte-copy I/O path. Used for inodes the kernel cannot map directly:
//  ext2/ext3 indirect-block files and inline-data inodes. Everything else goes
//  through the kernel-offloaded extent path instead.
//

import Foundation
import FSKit
import Ext4Core

extension Ext4Volume: FSVolume.ReadWriteOperations {

    func read(from item: FSItem,
              at offset: off_t,
              length: Int,
              into buffer: FSMutableFileDataBuffer) async throws -> Int {
        guard let ext4Item = item as? Ext4Item else { throw Ext4Error.invalid }
        guard length > 0 else { return 0 }

        return try await executor.run { [self] in
            var got = 0
            let rc = buffer.withUnsafeMutableBytes { raw -> Int32 in
                ext4b_read(device, ext4Item.inode,
                           UInt64(offset), raw.baseAddress!,
                           min(length, raw.count), &got)
            }
            try Ext4Error.check(rc, "read(\(ext4Item.inode) @\(offset))")
            return got
        }
    }

    func write(contents: Data,
               to item: FSItem,
               at offset: off_t) async throws -> Int {
        throw Ext4Error.readOnly
    }
}

extension Ext4Volume: FSVolume.XattrOperations {

    func xattr(named name: FSFileName, of item: FSItem) async throws -> Data {
        guard let ext4Item = item as? Ext4Item else { throw Ext4Error.invalid }
        guard let attrName = name.string else { throw Ext4Error.invalid }

        return try await executor.run { [self] in
            var buffer = [UInt8](repeating: 0, count: Int(bridge.blockSize))
            var length = 0
            let rc = ext4b_getxattr(device, ext4Item.inode,
                                    attrName, &buffer, buffer.count, &length)
            try Ext4Error.check(rc)
            return Data(buffer.prefix(length))
        }
    }

    func setXattr(named name: FSFileName,
                  to value: Data?,
                  on item: FSItem,
                  policy: FSVolume.SetXattrPolicy) async throws {
        throw Ext4Error.readOnly
    }

    func xattrs(of item: FSItem) async throws -> [FSFileName] {
        guard let ext4Item = item as? Ext4Item else { throw Ext4Error.invalid }

        return try await executor.run { [self] in
            var names: [FSFileName] = []
            let rc = withUnsafeMutablePointer(to: &names) { ptr -> Int32 in
                ext4b_listxattr(device, ext4Item.inode,
                                collectXattr, ptr)
            }
            try Ext4Error.check(rc)
            return names
        }
    }
}

private let collectXattr: @convention(c) (UnsafeMutableRawPointer?,
                                          UnsafePointer<CChar>?, Int) -> Bool = {
    ctx, namePtr, nameLen in
    guard let ctx, let namePtr else { return false }
    let list = ctx.assumingMemoryBound(to: [FSFileName].self)
    list.pointee.append(FSFileName(data: Data(bytes: namePtr, count: nameLen)))
    return true
}
