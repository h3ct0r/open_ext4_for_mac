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
    /// `.metadataCache` is the family the design wants, and it is not
    /// available. Every call fails with `EIO`, instantly and identically, on
    /// both a disk image and a physical USB stick. Five explanations have been
    /// ruled out by measurement: block-size alignment, physical-sector
    /// alignment (both are 512 here), request size, request offset, and
    /// lifecycle -- it fails the same during `probeResource`, during
    /// `loadResource`, and with the volume fully active. Nothing appears in
    /// fskitd's log or the kernel's when it happens, and all six probe cases
    /// fail within the same millisecond, so the call is being refused before
    /// it reaches any device.
    ///
    /// The consequence is not performance. `metadataFlush` is the **only**
    /// write barrier in the whole `FSResource` API, and it belongs to this
    /// family -- so with `.direct` there is no barrier at all, and `flush()`
    /// below is a no-op. lwext4 issues its journal barriers faithfully and
    /// nothing enforces them.
    ///
    /// That was documented here as an assumption. It is now known false: a
    /// real USB stick, after an ungraceful teardown, came back with directory
    /// entries whose parent link counts had never landed -- half a
    /// transaction, which a journal exists to make impossible. A disk image
    /// never showed it, because writes reach it through the page cache and
    /// onto APFS in issue order; a USB stick has its own write cache and
    /// reorders freely. See docs/STATUS.md.
    ///
    enum Mode {
        case direct
        case metadataCache
    }

    let mode: Mode
    let resource: FSBlockDeviceResource
    private(set) var device: OpaquePointer?

    /// The decrypting layer, present only for a volume inside a LUKS
    /// container. It sits between `device` and this bridge's own callbacks, so
    /// lwext4 above it sees a plain block device that happens to start at the
    /// container's payload.
    private(set) var luksDevice: OpaquePointer?

    /// True when every byte on the way to the medium passes through the
    /// cipher. Anything that would let the kernel touch the device directly
    /// must consult this first.
    var isEncrypted: Bool { luksDevice != nil }

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

        // Two different block sizes, and the metadata I/O family cares which.
        // Its documentation says requests "must conform to any transfer
        // requirements of the underlying resource. Disk drives typically
        // require sector (physicalBlockSize) addressed operations" -- and this
        // bridge has always aligned to blockSize. That is a candidate
        // explanation for metadataRead failing with EIO here, which is why
        // .direct is what runs and why there is no write barrier.
        Ext4Log.io.info("device \(resource.bsdName, privacy: .public): blockSize=\(resource.blockSize) physicalBlockSize=\(resource.physicalBlockSize) blocks=\(resource.blockCount)")

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        guard let dev = ext4b_device_create(ctx, bs, resource.blockCount,
                                            !isWritable,
                                            bridgeRead, bridgeWrite, bridgeFlush) else {
            return nil
        }
        self.device = dev
    }

    deinit {
        close()
    }

    /// Tear down in the order the layers were built: the filesystem's device
    /// first, since destroying it can still flush through the cipher, then the
    /// decrypting layer, which zeroes its key material as it goes.
    func close() {
        if let device {
            ext4b_device_destroy(device)
            self.device = nil
        }
        if let luksDevice {
            luks_device_close(luksDevice)
            self.luksDevice = nil
        }
    }

    /// Rebuild the device stack with a decrypting layer in the middle.
    ///
    /// Call after `close()`: the plain device created by `init` addresses the
    /// container, header and all, and is not the one the filesystem should
    /// see. This one addresses the payload, and its block count is the payload
    /// size rather than the container size -- a filesystem told it has more
    /// blocks than exist would eventually write past the end of the medium.
    ///
    /// The caller owns `masterKey` and should zero it afterwards; this copies
    /// what it needs into the decrypting layer, which zeroes its copy on
    /// `close()`.
    func openThroughLUKS(info: luks_info, masterKey: [UInt8]) -> Bool {
        guard device == nil, luksDevice == nil else {
            Ext4Log.error("openThroughLUKS on an already-open device")
            return false
        }

        var info = info
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let opened = masterKey.withUnsafeBufferPointer { key in
            luks_device_open(ctx, bridgeRead,
                             isWritable ? bridgeWrite : nil,
                             bridgeFlush,
                             &info, key.baseAddress, key.count)
        }
        guard let opened else {
            Ext4Log.error("could not open the decrypting device")
            return false
        }
        luksDevice = opened

        let payloadBytes = luks_payload_size(opened, blockCount * UInt64(blockSize))
        guard payloadBytes >= UInt64(blockSize) else {
            Ext4Log.error("LUKS payload is smaller than one device block")
            close()
            return false
        }

        guard let dev = ext4b_device_create(UnsafeMutableRawPointer(opened),
                                            blockSize,
                                            payloadBytes / UInt64(blockSize),
                                            !isWritable,
                                            luks_device_read,
                                            luks_device_write,
                                            luks_device_flush) else {
            close()
            return false
        }
        device = dev
        return true
    }

    // MARK: - LUKS

    /// Read a LUKS header from the start of the device, if there is one.
    ///
    /// Deliberately separate from `ext4b_probe`: a LUKS container is not a
    /// filesystem, it is a block layer wrapped around one, so it is recognised
    /// before the filesystem probe ever gets a look at the bytes.
    ///
    /// Returns nil when the device carries no LUKS magic at all -- the common
    /// case, and not an error. A container we recognise but cannot open comes
    /// back with its status set, so the caller can say why.
    /// Turn a passphrase into the container's master key.
    ///
    /// The expensive half of LUKS: LUKS2 defaults ask for a gigabyte of memory
    /// and several seconds of it. Kept separate from opening the device so it
    /// can be done somewhere better suited than a sandboxed extension.
    ///
    /// The caller owns the returned bytes and must zero them.
    func unlockLUKS(info: luks_info, passphrase: [UInt8]) -> [UInt8]? {
        var info = info
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        var key = [UInt8](repeating: 0, count: Int(LUKS_MAX_MASTER_KEY))
        var length = 0

        let status = passphrase.withUnsafeBufferPointer { pass in
            key.withUnsafeMutableBufferPointer { out in
                luks_unlock(ctx, bridgeRead, &info,
                            pass.baseAddress, pass.count,
                            out.baseAddress, &length)
            }
        }
        guard status == LUKS_OK, length > 0, length <= key.count else {
            // Never says which slot, how far it got, or anything derived from
            // the passphrase -- only that it did not open.
            Ext4Log.error("LUKS unlock failed: \(String(cString: luks_strstatus(status)))")
            key.resetBytes(in: 0..<key.count)
            return nil
        }
        let result = Array(key[0..<length])
        key.resetBytes(in: 0..<key.count)
        return result
    }

    /// Raw bytes from the start of the media, below any decryption.
    ///
    /// Only for copying out a LUKS header. It deliberately does not go through
    /// the device stack: at the moment it is called there is no cipher in
    /// place, and there is no filesystem to read through either.
    func readForHeaderExport(into buffer: UnsafeMutableRawPointer,
                             offset: UInt64, count: Int) -> Int32 {
        read(into: buffer, offset: offset, count: count)
    }

    func probeLUKS() -> (status: luks_status, info: luks_info)? {
        var info = luks_info()
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let status = luks_probe(ctx, bridgeRead, &info)
        guard status != LUKS_NOT_LUKS else { return nil }
        return (status, info)
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
