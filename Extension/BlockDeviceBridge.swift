//
//  BlockDeviceBridge.swift
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FSKit
import Ext4Core

/// Connects the C core's block-I/O callbacks to an `FSBlockDeviceResource`.
///
/// The core deliberately knows nothing about FSKit: it asks for byte ranges
/// through function pointers. In production those land here; in the test
/// harness they land on a plain file. That indirection is what lets the entire
/// ext4 core be tested without code signing or mounting.
///
/// Metadata versus data
/// --------------------
/// Everything lwext4 reads or writes is filesystem *metadata* — superblock,
/// group descriptors, bitmaps, inode tables, directory blocks, the journal.
/// It therefore goes through FSKit's `metadataRead`/`delayedMetadataWrite`
/// family, which is backed by a kernel-managed cache and gives us
/// `metadataFlush` as an explicit write barrier for journal ordering.
///
/// Bulk file data does *not* pass through here. That is mapped into extents and
/// transferred by the kernel itself (see `Ext4Volume+KernelIO`).
final class BlockDeviceBridge {

    let resource: FSBlockDeviceResource
    private(set) var device: OpaquePointer?

    let blockSize: UInt32
    let blockCount: UInt64
    let isWritable: Bool

    init?(resource: FSBlockDeviceResource, forceReadOnly: Bool) {
        self.resource = resource
        // Never trust a zero or non-power-of-two block size from the device.
        let bs = UInt32(truncatingIfNeeded: resource.blockSize)
        guard bs >= 512, bs.nonzeroBitCount == 1 else {
            Ext4Log.error("refusing device with block size \(resource.blockSize)")
            return nil
        }
        self.blockSize = bs
        self.blockCount = resource.blockCount
        self.isWritable = resource.isWritable && !forceReadOnly

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        guard let dev = ext4b_device_create(ctx, bs, resource.blockCount,
                                            !isWritable,
                                            bridgeRead, bridgeWrite, bridgeFlush) else {
            return nil
        }
        self.device = dev
    }

    deinit {
        if let device {
            ext4b_device_destroy(device)
        }
    }

    func close() {
        if let device {
            ext4b_device_destroy(device)
            self.device = nil
        }
    }

    // MARK: - I/O actually performed against the resource

    fileprivate func read(into buffer: UnsafeMutableRawPointer,
                          offset: UInt64, count: Int) -> Int32 {
        let dst = UnsafeMutableRawBufferPointer(start: buffer, count: count)
        do {
            try resource.metadataRead(into: dst,
                                      startingAt: off_t(offset),
                                      length: count)
            return 0
        } catch {
            Ext4Log.io.error("read \(count)B @\(offset) failed: \(error.localizedDescription, privacy: .public)")
            return EIO
        }
    }

    fileprivate func write(from buffer: UnsafeRawPointer,
                           offset: UInt64, count: Int) -> Int32 {
        guard isWritable else { return EROFS }
        let src = UnsafeRawBufferPointer(start: buffer, count: count)
        do {
            // Delayed writes let the kernel coalesce; ordering is imposed
            // explicitly by flush() at journal commit points.
            try resource.delayedMetadataWrite(from: src,
                                              startingAt: off_t(offset),
                                              length: count)
            return 0
        } catch {
            Ext4Log.io.error("write \(count)B @\(offset) failed: \(error.localizedDescription, privacy: .public)")
            return EIO
        }
    }

    fileprivate func flush() -> Int32 {
        guard isWritable else { return 0 }
        do {
            try resource.metadataFlush()
            return 0
        } catch {
            Ext4Log.io.error("metadata flush failed: \(error.localizedDescription, privacy: .public)")
            return EIO
        }
    }
}

// MARK: - C callback trampolines
//
// These must be capture-free @convention(c) functions; the instance travels
// through the void* context pointer the core hands back to us.

private let bridgeRead: @convention(c) (UnsafeMutableRawPointer?,
                                        UnsafeMutableRawPointer?,
                                        UInt64, Int) -> Int32 = { ctx, buf, offset, count in
    guard let ctx, let buf else { return EIO }
    let bridge = Unmanaged<BlockDeviceBridge>.fromOpaque(ctx).takeUnretainedValue()
    return bridge.read(into: buf, offset: offset, count: count)
}

private let bridgeWrite: @convention(c) (UnsafeMutableRawPointer?,
                                         UnsafeRawPointer?,
                                         UInt64, Int) -> Int32 = { ctx, buf, offset, count in
    guard let ctx, let buf else { return EIO }
    let bridge = Unmanaged<BlockDeviceBridge>.fromOpaque(ctx).takeUnretainedValue()
    return bridge.write(from: buf, offset: offset, count: count)
}

private let bridgeFlush: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { ctx in
    guard let ctx else { return EIO }
    let bridge = Unmanaged<BlockDeviceBridge>.fromOpaque(ctx).takeUnretainedValue()
    return bridge.flush()
}
