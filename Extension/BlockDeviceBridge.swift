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
/// File data currently passes through here too, via
/// `FSVolume.ReadWriteOperations`. Kernel-offloaded I/O is disabled until the
/// write blockmap is implemented; see the note in the Makefile.
final class BlockDeviceBridge {

    /// Which FSKit I/O family to use.
    ///
    /// `.metadataCache` is the family the design wants: kernel-cached, with
    /// `metadataFlush` as an explicit write barrier for journal ordering. It
    /// does not work here. `metadataRead` fails with EIO both during
    /// `probeResource` *and* after the resource is loaded, so every mount that
    /// tries it dies with "Loading resource: Input/output error". Whatever
    /// additional setup FSKit wants for that family, we have not found it.
    ///
    /// `.direct` is therefore what actually runs. The consequence is that
    /// there is no explicit barrier: durability and ordering rest on
    /// `FSBlockDeviceResource.write` reaching the medium in issue order.
    /// That is very likely true -- it is a synchronous call against the device
    /// -- but it is an assumption, not something FSKit documents, and the
    /// crash-consistency suite has not been run against this path. Revisit
    /// before claiming crash safety for the mounted driver.
    enum Mode {
        case direct
        case metadataCache
    }

    let mode: Mode
    let resource: FSBlockDeviceResource
    private(set) var device: OpaquePointer?

    let blockSize: UInt32
    let blockCount: UInt64
    let isWritable: Bool

    init?(resource: FSBlockDeviceResource, forceReadOnly: Bool, mode: Mode = .direct) {
        self.resource = resource
        self.mode = mode
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

    // MARK: - Alignment
    //
    // FSKit's metadata I/O is block-addressed: offset and length must both be
    // multiples of the device block size. lwext4 does not honour that -- the
    // very first thing it does is read the 1024-byte superblock at offset 1024,
    // which is unaligned on any device with 4 KiB blocks. Requests are
    // therefore widened to block boundaries here and the caller's slice copied
    // out of the aligned window.

    private func alignedWindow(offset: UInt64, count: Int) -> (start: UInt64, length: Int, shift: Int) {
        let bs = UInt64(blockSize)
        let start = (offset / bs) * bs
        let end = offset + UInt64(count)
        let alignedEnd = ((end + bs - 1) / bs) * bs
        return (start, Int(alignedEnd - start), Int(offset - start))
    }

    fileprivate func read(into buffer: UnsafeMutableRawPointer,
                          offset: UInt64, count: Int) -> Int32 {
        let w = alignedWindow(offset: offset, count: count)
        do {
            if w.shift == 0 && w.length == count {
                let dst = UnsafeMutableRawBufferPointer(start: buffer, count: count)
                try readRaw(into: dst, at: off_t(offset), length: count)
            } else {
                var scratch = [UInt8](repeating: 0, count: w.length)
                try scratch.withUnsafeMutableBytes { raw in
                    try readRaw(into: raw, at: off_t(w.start), length: w.length)
                }
                scratch.withUnsafeBytes { raw in
                    buffer.copyMemory(from: raw.baseAddress! + w.shift, byteCount: count)
                }
            }
            return 0
        } catch {
            Ext4Log.io.error("read \(count)B @\(offset) (aligned \(w.length)B @\(w.start)) failed: \(error.localizedDescription, privacy: .public)")
            return EIO
        }
    }

    fileprivate func write(from buffer: UnsafeRawPointer,
                           offset: UInt64, count: Int) -> Int32 {
        guard isWritable else { return EROFS }
        let w = alignedWindow(offset: offset, count: count)
        do {
            if w.shift == 0 && w.length == count {
                let src = UnsafeRawBufferPointer(start: buffer, count: count)
                try writeRaw(from: src, at: off_t(offset), length: count)
            } else {
                // Partial block: read the surrounding blocks, patch in the
                // caller's bytes, write the whole window back. Skipping the
                // read would zero the bytes either side of the update.
                var scratch = [UInt8](repeating: 0, count: w.length)
                try scratch.withUnsafeMutableBytes { raw in
                    try readRaw(into: raw, at: off_t(w.start), length: w.length)
                }
                scratch.withUnsafeMutableBytes { raw in
                    (raw.baseAddress! + w.shift).copyMemory(from: buffer, byteCount: count)
                }
                try scratch.withUnsafeBytes { raw in
                    try writeRaw(from: raw, at: off_t(w.start), length: w.length)
                }
            }
            return 0
        } catch {
            Ext4Log.io.error("write \(count)B @\(offset) (aligned \(w.length)B @\(w.start)) failed: \(error.localizedDescription, privacy: .public)")
            return EIO
        }
    }

    fileprivate func flush() -> Int32 {
        guard isWritable else { return 0 }
        // Direct writes have already been handed to the device; there is no
        // cache to drain and metadataFlush would fail.
        guard mode == .metadataCache else { return 0 }
        do {
            try resource.metadataFlush()
            return 0
        } catch {
            Ext4Log.io.error("metadata flush failed: \(error.localizedDescription, privacy: .public)")
            return EIO
        }
    }

    // MARK: - The two I/O families

    private func readRaw(into buf: UnsafeMutableRawBufferPointer,
                         at offset: off_t, length: Int) throws {
        switch mode {
        case .direct:        _ = try resource.read(into: buf, startingAt: offset, length: length)
        case .metadataCache: try resource.metadataRead(into: buf, startingAt: offset, length: length)
        }
    }

    private func writeRaw(from buf: UnsafeRawBufferPointer,
                          at offset: off_t, length: Int) throws {
        switch mode {
        case .direct:
            _ = try resource.write(from: buf, startingAt: offset, length: length)
        case .metadataCache:
            // Delayed so the kernel can coalesce; ordering is imposed by
            // flush() at journal commit points.
            try resource.delayedMetadataWrite(from: buf, startingAt: offset, length: length)
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
