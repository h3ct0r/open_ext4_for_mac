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
            let rc = try buffer.withUnsafeMutableBytes { raw -> Int32 in
                ext4b_read(try device, ext4Item.inode,
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
        guard let ext4Item = item as? Ext4Item else { throw Ext4Error.invalid }
        try requireWritable()
        guard !contents.isEmpty else { return 0 }

        let written = try await executor.run { [self] in
            var count = 0
            let rc = try contents.withUnsafeBytes { raw -> Int32 in
                ext4b_write(try device, ext4Item.inode, UInt64(offset),
                            raw.baseAddress!, raw.count, &count)
            }
            try Ext4Error.check(rc, "write(\(ext4Item.inode) @\(offset))")
            return count
        }

        // Size and mtime just changed on disk; the cached snapshot is stale.
        ext4Item.invalidate()
        return written
    }
}

extension Ext4Volume: FSVolume.XattrOperations {

    func xattr(named name: FSFileName, of item: FSItem) async throws -> Data {
        guard let ext4Item = item as? Ext4Item else { throw Ext4Error.invalid }
        guard let attrName = name.string else { throw Ext4Error.invalid }

        return try await executor.run { [self] in
            var buffer = [UInt8](repeating: 0, count: Int(bridge.blockSize))
            var length = 0
            let rc = ext4b_getxattr(try device, ext4Item.inode,
                                    attrName, &buffer, buffer.count, &length)
            try Ext4Error.check(rc)
            return Data(buffer.prefix(length))
        }
    }

    func setXattr(named name: FSFileName,
                  to value: Data?,
                  on item: FSItem,
                  policy: FSVolume.SetXattrPolicy) async throws {
        guard let ext4Item = item as? Ext4Item else { throw Ext4Error.invalid }
        try requireWritable()
        guard let attrName = name.string else { throw Ext4Error.invalid }

        // Honour the create/replace policy before touching the volume, so a
        // policy violation never leaves a partial change behind.
        let existing = try? await xattr(named: name, of: item)
        switch policy {
        case .mustCreate where existing != nil:
            throw Ext4Error.posix(EEXIST)
        case .mustReplace where existing == nil:
            // ENOATTR, not ENODATA: macOS names this condition differently
            // from Linux and gives it a different number. See xattr_errno()
            // in the bridge.
            throw Ext4Error.posix(ENOATTR)
        default:
            break
        }

        try await executor.run { [self] in
            let rc: Int32
            if let value {
                rc = try value.withUnsafeBytes { raw -> Int32 in
                    ext4b_setxattr(try device, ext4Item.inode, attrName,
                                   raw.baseAddress, raw.count)
                }
            } else {
                // A nil value means remove.
                rc = ext4b_removexattr(try device, ext4Item.inode, attrName)
            }
            try Ext4Error.check(rc, "setxattr(\(attrName))")
        }
        ext4Item.invalidate()
    }

    func xattrs(of item: FSItem) async throws -> [FSFileName] {
        guard let ext4Item = item as? Ext4Item else { throw Ext4Error.invalid }

        return try await executor.run { [self] in
            var names: [FSFileName] = []
            let rc = try withUnsafeMutablePointer(to: &names) { ptr -> Int32 in
                ext4b_listxattr(try device, ext4Item.inode,
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
