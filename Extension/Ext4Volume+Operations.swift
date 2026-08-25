//
//  Ext4Volume+Operations.swift
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  The core VFS surface: mount, lookup, enumerate, attributes.
//  Mutating operations deliberately return EROFS until the write path lands.
//

import Foundation
import FSKit
import Ext4Core

extension Ext4Volume: FSVolume.PathConfOperations {

    var maximumLinkCount: Int { 65000 }          // ext4 EXT4_LINK_MAX
    var maximumNameLength: Int { 255 }           // EXT4_NAME_LEN
    var restrictsOwnershipChanges: Bool { true } // read-only for now
    var truncatesLongNames: Bool { false }       // we reject, never silently truncate
    var maximumXattrSize: Int { Int(bridge.blockSize) }
    var maximumFileSize: UInt64 { 16 * 1024 * 1024 * 1024 * 1024 }  // 16 TiB at 4K blocks
}

extension Ext4Volume: FSVolume.Operations {

    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        supportedCapabilities
    }

    var volumeStatistics: FSStatFSResult {
        let result = FSStatFSResult(fileSystemTypeName: "ext\(probe.generation)")
        var stats = ext4b_statfs_info()
        guard bridge.device != nil,
              ext4b_statfs(device, &stats) == 0 else {
            return result
        }
        result.blockSize = Int(stats.block_size)
        result.ioSize = Int(stats.block_size)
        result.totalBlocks = stats.total_blocks
        result.availableBlocks = stats.avail_blocks
        result.freeBlocks = stats.free_blocks
        result.totalFiles = UInt64(stats.total_inodes)
        result.freeFiles = UInt64(stats.free_inodes)
        return result
    }

    // MARK: - Lifecycle

    func activate(options: FSTaskOptions) async throws -> FSItem {
        Ext4Log.volume.info("activating ext\(self.probe.generation, privacy: .public) volume, readOnly=\(self.isReadOnly, privacy: .public)")
        return item(for: UInt32(EXT4B_ROOT_INO))
    }

    func deactivate(options: FSDeactivateOptions = []) async throws {
        Ext4Log.volume.info("deactivating volume")
        try await executor.run { [self] in
            _ = ext4b_sync(device)
        }
        forgetAllItems()
    }

    func mount(options: FSTaskOptions) async throws {
        // The resource was already mounted during loadResource, where the
        // feature gate ran. Nothing further is required here.
        Ext4Log.volume.debug("mount()")
    }

    func unmount() async {
        Ext4Log.volume.info("unmount()")
        try? await executor.run { [self] in
            _ = ext4b_sync(device)
        }
    }

    func synchronize(flags: FSSyncFlags) async throws {
        guard !isReadOnly else { return }
        try await executor.run { [self] in
            try Ext4Error.check(ext4b_sync(device), "sync")
        }
    }

    // MARK: - Attributes

    func attributes(_ desired: FSItem.GetAttributesRequest,
                    of item: FSItem) async throws -> FSItem.Attributes {
        guard let ext4Item = item as? Ext4Item else { throw Ext4Error.invalid }
        let attrs = try await executor.run { [self] in
            try fetchAttributes(inode: ext4Item.inode)
        }
        let out = FSItem.Attributes()
        populate(out, from: attrs, requested: desired.wantedAttributes)
        return out
    }

    func setAttributes(_ request: FSItem.SetAttributesRequest,
                       on item: FSItem) async throws -> FSItem.Attributes {
        throw Ext4Error.readOnly
    }

    // MARK: - Lookup and enumeration

    func lookupItem(named name: FSFileName,
                    inDirectory directory: FSItem) async throws -> (FSItem, FSFileName) {
        guard let dir = directory as? Ext4Item else { throw Ext4Error.invalid }
        guard let nameData = name.data as Data?, !nameData.isEmpty else {
            throw Ext4Error.noEntry
        }

        let inode = try await executor.run { [self] in
            var found: UInt32 = 0
            var type = EXT4B_TYPE_UNKNOWN
            let rc = nameData.withUnsafeBytes { raw -> Int32 in
                ext4b_lookup(device, dir.inode,
                             raw.baseAddress!.assumingMemoryBound(to: CChar.self),
                             raw.count, &found, &type)
            }
            try Ext4Error.check(rc)
            return found
        }
        return (self.item(for: inode), name)
    }

    func enumerateDirectory(_ directory: FSItem,
                            startingAt cookie: FSDirectoryCookie,
                            verifier: FSDirectoryVerifier,
                            attributes: FSItem.GetAttributesRequest?,
                            packer: FSDirectoryEntryPacker) async throws -> FSDirectoryVerifier {
        guard let dir = directory as? Ext4Item else { throw Ext4Error.invalid }

        try await executor.run { [self] in
            // The packer is only valid for the duration of this call, so it is
            // passed through the C callback via an unmanaged context pointer.
            var state = PackState(packer: packer,
                                  volume: self,
                                  wanted: attributes?.wantedAttributes)
            let rc = withUnsafeMutablePointer(to: &state) { statePtr -> Int32 in
                ext4b_readdir(device, dir.inode,
                              UInt64(cookie.rawValue), packEntry, statePtr)
            }
            if let error = state.thrown { throw error }
            try Ext4Error.check(rc, "readdir(\(dir.inode))")
        }
        return verifier
    }

    func reclaimItem(_ item: FSItem) async throws {
        guard let ext4Item = item as? Ext4Item else { return }
        forget(ext4Item)
    }

    // MARK: - Symlinks

    func readSymbolicLink(_ item: FSItem) async throws -> FSFileName {
        guard let ext4Item = item as? Ext4Item else { throw Ext4Error.invalid }
        let target = try await executor.run { [self] in
            var buffer = [CChar](repeating: 0, count: 4096)
            var length = 0
            let rc = ext4b_readlink(device, ext4Item.inode,
                                    &buffer, buffer.count, &length)
            try Ext4Error.check(rc, "readlink(\(ext4Item.inode))")
            return String(cString: buffer)
        }
        return FSFileName(string: target)
    }

    // MARK: - Mutating operations (not yet implemented)

    func createItem(named name: FSFileName,
                    type: FSItem.ItemType,
                    inDirectory directory: FSItem,
                    attributes: FSItem.SetAttributesRequest) async throws -> (FSItem, FSFileName) {
        throw Ext4Error.readOnly
    }

    func createSymbolicLink(named name: FSFileName,
                            inDirectory directory: FSItem,
                            attributes: FSItem.SetAttributesRequest,
                            linkContents contents: FSFileName) async throws -> (FSItem, FSFileName) {
        throw Ext4Error.readOnly
    }

    func createLink(to item: FSItem,
                    named name: FSFileName,
                    inDirectory directory: FSItem) async throws -> FSFileName {
        throw Ext4Error.readOnly
    }

    func removeItem(_ item: FSItem,
                    named name: FSFileName,
                    fromDirectory directory: FSItem) async throws {
        throw Ext4Error.readOnly
    }

    func renameItem(_ item: FSItem,
                    inDirectory sourceDirectory: FSItem,
                    named sourceName: FSFileName,
                    to destinationName: FSFileName,
                    inDirectory destinationDirectory: FSItem,
                    overItem: FSItem?) async throws -> FSFileName {
        throw Ext4Error.readOnly
    }
}

// MARK: - Directory packing

/// Carried through the C readdir callback. A struct rather than a class so it
/// lives on the stack for exactly the lifetime of the enumerate call.
private struct PackState {
    let packer: FSDirectoryEntryPacker
    unowned let volume: Ext4Volume
    let wanted: FSItem.Attribute?
    var thrown: Error?
}

private let packEntry: @convention(c) (UnsafeMutableRawPointer?,
                                       UnsafePointer<CChar>?,
                                       Int, UInt32, ext4b_item_type, UInt64) -> Bool = {
    ctx, namePtr, nameLen, inode, type, nextCookie in

    guard let ctx, let namePtr else { return false }
    let state = ctx.assumingMemoryBound(to: PackState.self)

    let name = FSFileName(data: Data(bytes: namePtr, count: nameLen))

    // Attributes are only fetched when the kernel actually asked for them;
    // a readdir that does not need them should not pay for an inode read each.
    var attributes: FSItem.Attributes?
    if let wanted = state.pointee.wanted {
        if let a = try? state.pointee.volume.fetchAttributes(inode: inode) {
            let out = FSItem.Attributes()
            state.pointee.volume.populate(out, from: a, requested: wanted)
            attributes = out
        }
    }

    return state.pointee.packer.packEntry(name: name,
                                          itemType: type.fsItemType,
                                          itemID: FSItem.Identifier(rawValue: UInt64(inode))!,
                                          nextCookie: FSDirectoryCookie(rawValue: nextCookie),
                                          attributes: attributes)
}
