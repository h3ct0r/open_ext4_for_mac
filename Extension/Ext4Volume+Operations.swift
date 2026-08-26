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

    /// Ask FSKit to mark the mount read-only when the volume must not be
    /// written, so the restriction is enforced at the VFS layer rather than
    /// only by our own operations returning EROFS.
    ///
    /// The setter exists because the protocol declares this read-write and a
    /// get-only property does not satisfy it -- the compiler says so, as
    /// "nearly matches optional requirement", and the property is then simply
    /// never read. FSKit only reads this once, just after `mount` replies, and
    /// the header says changing it later has no effect, so there is nothing
    /// for a setter to do.
    @available(macOS 26.4, *)
    var requestedMountOptions: FSVolume.MountOptions {
        get { isReadOnly ? .readOnly : [] }
        set { }
    }

    //
    // FSKit's own open-unlink emulation is deliberately *not* enabled.
    //
    // It works by keeping the file in the namespace under a hidden name until
    // its last close, which is the right answer for a filesystem that has no
    // way to describe "deleted but still in use" on the medium -- FAT, for
    // instance. ext4 does have one: the orphan list, which this driver now
    // maintains (see ext4b_unlink_ex and ext4b_orphan_cleanup).
    //
    // Two mechanisms would be worse than either alone. The emulation leaves a
    // real directory entry behind if the machine loses power mid-way, and it
    // is an entry only FSKit knows to clean up -- a Linux box would find a
    // stray hidden file on the volume and no reason to remove it. An orphan
    // record is invisible, and Linux, e2fsck and this driver all know what it
    // means.
    //
    // Not implementing the property at all is how the emulation stays off; the
    // header is explicit that this is the default.
    //

    /// The one core call that does not go through the executor.
    ///
    /// FSKit declares this as a synchronous property, so there is nowhere to
    /// await; blocking a kernel thread on the executor here would deadlock any
    /// time the executor is busy. It is safe because `ext4_mount_point_stats`
    /// only reads fields out of the in-memory superblock -- no block cache, no
    /// I/O. The worst outcome is a free-block count one transaction stale.
    var volumeStatistics: FSStatFSResult {
        let result = FSStatFSResult(fileSystemTypeName: "ext\(probe.generation)")
        var stats = ext4b_statfs_info()
        guard let dev = deviceIfOpen, ext4b_statfs(dev, &stats) == 0 else {
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
        // Ready -> Active: the volume now has a live root.
        fileSystem?.containerStatus = FSContainerStatus.active
        return item(for: UInt32(EXT4B_ROOT_INO))
    }

    func deactivate(options: FSDeactivateOptions = []) async throws {
        Ext4Log.volume.info("deactivating volume")
        // Active -> Ready: still loaded, but no live volume.
        fileSystem?.containerStatus = FSContainerStatus.ready
        // Belt and braces: if unmount() did not run, close here instead.
        await fileSystem?.closeVolume()
        forgetAllItems()
    }

    func mount(options: FSTaskOptions) async throws {
        // The resource was already mounted during loadResource, where the
        // feature gate ran. Nothing further is required here.
        Ext4Log.volume.debug("mount()")
    }

    func unmount() async {
        Ext4Log.volume.info("unmount()")
        // Flush, then close the volume properly. FSKit never calls
        // unloadResource for umount(8), so this is the last chance to stop the
        // journal and write back the superblock.
        // Anything unlinked but still held open has to be freed before the
        // volume closes, or it stays allocated with no name pointing at it.
        await releaseAllPending()
        try? await executor.run { [self] in
            _ = ext4b_sync(try device)
        }
        await fileSystem?.closeVolume()
    }

    func synchronize(flags: FSSyncFlags) async throws {
        guard !isReadOnly else { return }
        try await executor.run { [self] in
            // FSKit issues this after unmount() has already closed the volume.
            // Everything was flushed on the way out, so there is nothing left
            // to do and nothing to report.
            guard let dev = deviceIfOpen else { return }
            try Ext4Error.check(ext4b_sync(dev), "sync")
        }
    }

    // MARK: - Attributes

    func attributes(_ desired: FSItem.GetAttributesRequest,
                    of item: FSItem) async throws -> FSItem.Attributes {
        guard let ext4Item = item as? Ext4Item else { throw Ext4Error.invalid }
        let wanted = desired.wantedAttributes
        // populate() is a core call too -- it reads ".." to answer parentID --
        // so it belongs inside the executor block, not after it.
        return try await executor.run { [self] in
            let attrs = try fetchAttributes(inode: ext4Item.inode)
            let out = FSItem.Attributes()
            populate(out, from: attrs, requested: wanted)
            return out
        }
    }

    func setAttributes(_ request: FSItem.SetAttributesRequest,
                       on item: FSItem) async throws -> FSItem.Attributes {
        guard let ext4Item = item as? Ext4Item else { throw Ext4Error.invalid }
        try requireWritable()

        var mask: UInt32 = 0
        var attrs = ext4b_attrs()
        let wanted = request.consumedAttributes

        if wanted.contains(.mode) { mask |= EXT4B_SET_MODE.rawValue;  attrs.mode = request.mode }
        if wanted.contains(.uid)  { mask |= EXT4B_SET_UID.rawValue;   attrs.uid  = request.uid }
        if wanted.contains(.gid)  { mask |= EXT4B_SET_GID.rawValue;   attrs.gid  = request.gid }
        if wanted.contains(.size) { mask |= EXT4B_SET_SIZE.rawValue;  attrs.size = request.size }
        if wanted.contains(.accessTime) {
            mask |= EXT4B_SET_ATIME.rawValue; attrs.atime = Int64(request.accessTime.tv_sec)
        }
        if wanted.contains(.modifyTime) {
            mask |= EXT4B_SET_MTIME.rawValue; attrs.mtime = Int64(request.modifyTime.tv_sec)
        }

        // Flags can be read but not written. lwext4 offers no way to rewrite
        // the inode's flags word, and on Linux only root may clear immutable or
        // append-only in any case. A request that asks for the flags already
        // there costs nothing and is allowed through -- macOS sends those while
        // copying files. One that would really change something is refused,
        // because reporting a success that did not happen is how a user ends up
        // believing a file is unlocked when it is not.
        if wanted.contains(.flags) {
            let current = try await executor.run { [self] in
                Ext4Volume.bsdFlags(from: try fetchAttributes(inode: ext4Item.inode))
            }
            guard request.flags == current else { throw Ext4Error.posix(EPERM) }
        }

        if mask != 0 {
            let finalMask = mask
            let finalAttrs = attrs
            try await executor.run { [self] in
                var a = finalAttrs
                try Ext4Error.check(
                    ext4b_setattr(try device, ext4Item.inode,
                                  ext4b_setattr_mask(rawValue: finalMask), &a),
                    "setattr(\(ext4Item.inode))")
            }
            ext4Item.invalidate()
        }

        return try await self.attributes(FSItem.GetAttributesRequest(), of: item)
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
            let rc = try nameData.withUnsafeBytes { raw -> Int32 in
                ext4b_lookup(try device, dir.inode,
                             raw.baseAddress!.assumingMemoryBound(to: CChar.self),
                             raw.count, &found, &type)
            }
            try Ext4Error.check(rc)
            return found
        }
        let found = self.item(for: inode)
        found.parent = dir.inode
        return (found, name)
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
                                  wanted: attributes?.wantedAttributes,
                                  parent: dir.inode)
            let rc = try withUnsafeMutablePointer(to: &state) { statePtr -> Int32 in
                ext4b_readdir(try device, dir.inode,
                              UInt64(cookie.rawValue), packEntry, statePtr)
            }
            if let error = state.thrown { throw error }
            try Ext4Error.check(rc, "readdir(\(dir.inode))")
        }
        return verifier
    }

    func reclaimItem(_ item: FSItem) async throws {
        guard let ext4Item = item as? Ext4Item else { return }
        // Both this and deactivateItem can be the last word on an item,
        // depending on how it was used; releaseIfPending is idempotent so
        // whichever arrives first does the work.
        await releaseIfPending(ext4Item.inode)
        forget(ext4Item)
    }

    // MARK: - Symlinks

    func readSymbolicLink(_ item: FSItem) async throws -> FSFileName {
        guard let ext4Item = item as? Ext4Item else { throw Ext4Error.invalid }
        let target = try await executor.run { [self] in
            var buffer = [CChar](repeating: 0, count: 4096)
            var length = 0
            let rc = ext4b_readlink(try device, ext4Item.inode,
                                    &buffer, buffer.count, &length)
            try Ext4Error.check(rc, "readlink(\(ext4Item.inode))")
            return String(cString: buffer)
        }
        return FSFileName(string: target)
    }

    // MARK: - Mutating operations

    func createItem(named name: FSFileName,
                    type: FSItem.ItemType,
                    inDirectory directory: FSItem,
                    attributes: FSItem.SetAttributesRequest) async throws -> (FSItem, FSFileName) {
        guard let dir = directory as? Ext4Item else { throw Ext4Error.invalid }
        try requireWritable()

        let coreType: ext4b_item_type
        switch type {
        case .file:        coreType = EXT4B_TYPE_FILE
        case .directory:   coreType = EXT4B_TYPE_DIR
        case .fifo:        coreType = EXT4B_TYPE_FIFO
        case .socket:      coreType = EXT4B_TYPE_SOCKET
        default:           throw Ext4Error.notSupported
        }

        let nameData = try Self.nameBytes(name)
        let (mode, uid, gid) = identity.onDiskCreationAttributes(
            requested: attributes, isDirectory: type == .directory)

        let inode = try await executor.run { [self] in
            var created: UInt32 = 0
            let rc = try nameData.withUnsafeBytes { raw -> Int32 in
                ext4b_create(try device, dir.inode,
                             raw.baseAddress!.assumingMemoryBound(to: CChar.self),
                             raw.count, coreType, mode, uid, gid, &created)
            }
            try Ext4Error.check(rc, "create(\(name.debugDescription))")
            return created
        }

        dir.invalidate()
        let created = item(for: inode)
        created.parent = dir.inode
        return (created, name)
    }

    func createSymbolicLink(named name: FSFileName,
                            inDirectory directory: FSItem,
                            attributes: FSItem.SetAttributesRequest,
                            linkContents contents: FSFileName) async throws -> (FSItem, FSFileName) {
        guard let dir = directory as? Ext4Item else { throw Ext4Error.invalid }
        try requireWritable()

        let nameData = try Self.nameBytes(name)
        guard let targetData = contents.data as Data?, !targetData.isEmpty else {
            throw Ext4Error.invalid
        }
        let (_, uid, gid) = identity.onDiskCreationAttributes(
            requested: attributes, isDirectory: false)

        let inode = try await executor.run { [self] in
            let dev = try device
            var created: UInt32 = 0
            let rc = nameData.withUnsafeBytes { n -> Int32 in
                targetData.withUnsafeBytes { t -> Int32 in
                    ext4b_symlink(dev, dir.inode,
                                  n.baseAddress!.assumingMemoryBound(to: CChar.self), n.count,
                                  t.baseAddress!.assumingMemoryBound(to: CChar.self), t.count,
                                  uid, gid, &created)
                }
            }
            try Ext4Error.check(rc, "symlink")
            return created
        }

        dir.invalidate()
        let link = item(for: inode)
        link.parent = dir.inode
        return (link, name)
    }

    func createLink(to item: FSItem,
                    named name: FSFileName,
                    inDirectory directory: FSItem) async throws -> FSFileName {
        guard let target = item as? Ext4Item,
              let dir = directory as? Ext4Item else { throw Ext4Error.invalid }
        try requireWritable()

        let nameData = try Self.nameBytes(name)
        try await executor.run { [self] in
            let rc = try nameData.withUnsafeBytes { raw -> Int32 in
                ext4b_hardlink(try device, dir.inode,
                               raw.baseAddress!.assumingMemoryBound(to: CChar.self),
                               raw.count, target.inode)
            }
            try Ext4Error.check(rc, "hardlink")
        }

        target.invalidate()
        dir.invalidate()
        return name
    }

    func removeItem(_ item: FSItem,
                    named name: FSFileName,
                    fromDirectory directory: FSItem) async throws {
        guard let victim = item as? Ext4Item,
              let dir = directory as? Ext4Item else { throw Ext4Error.invalid }
        try requireWritable()

        let nameData = try Self.nameBytes(name)
        //
        // Do not free the inode here even when this was its last name.
        //
        // The kernel can still hold the file open, and it will keep sending
        // reads and writes for it afterwards. Freeing the inode now means those
        // writes allocate blocks onto an inode nothing references: the data
        // reads back correctly for the life of the descriptor, so nothing looks
        // wrong, but the blocks are never recovered and e2fsck reports
        // "Block bitmap differences" once the volume is unmounted.
        //
        // The release is deferred to deactivateItem/reclaimItem, which is when
        // FSKit tells us the last user is gone.
        //
        // Defer only for a file something still has open. Everything else is
        // freed here and now, which keeps the crash window at zero for the
        // overwhelmingly common case.
        let defer_ = isOpen(victim.inode)
        let unreferenced = try await executor.run { [self] in
            let dev = try device
            var orphaned = false
            let rc = nameData.withUnsafeBytes { raw -> Int32 in
                ext4b_unlink_ex(dev, dir.inode,
                                raw.baseAddress!.assumingMemoryBound(to: CChar.self),
                                raw.count, defer_, &orphaned)
            }
            try Ext4Error.check(rc, "unlink")
            return orphaned
        }

        if unreferenced {
            notePendingRelease(victim.inode)
        }

        victim.invalidate()
        dir.invalidate()
    }

    func renameItem(_ item: FSItem,
                    inDirectory sourceDirectory: FSItem,
                    named sourceName: FSFileName,
                    to destinationName: FSFileName,
                    inDirectory destinationDirectory: FSItem,
                    overItem: FSItem?) async throws -> FSFileName {
        guard let src = sourceDirectory as? Ext4Item,
              let dst = destinationDirectory as? Ext4Item else { throw Ext4Error.invalid }
        try requireWritable()

        let srcData = try Self.nameBytes(sourceName)
        let dstData = try Self.nameBytes(destinationName)

        try await executor.run { [self] in
            let dev = try device
            let rc = srcData.withUnsafeBytes { s -> Int32 in
                dstData.withUnsafeBytes { d -> Int32 in
                    ext4b_rename(dev,
                                 src.inode, s.baseAddress!.assumingMemoryBound(to: CChar.self), s.count,
                                 dst.inode, d.baseAddress!.assumingMemoryBound(to: CChar.self), d.count)
                }
            }
            try Ext4Error.check(rc, "rename")
        }

        (item as? Ext4Item)?.invalidate()
        (overItem as? Ext4Item)?.invalidate()
        src.invalidate()
        dst.invalidate()
        return destinationName
    }

    // MARK: - Helpers

    func requireWritable() throws {
        guard !isReadOnly, ext4b_is_writable(try device) else {
            throw Ext4Error.readOnly
        }
    }

    /// ext4 names are raw byte strings, not Unicode. Take the bytes FSKit gives
    /// us verbatim rather than round-tripping through String, so names that are
    /// not valid UTF-8 still work.
    static func nameBytes(_ name: FSFileName) throws -> Data {
        guard let data = name.data as Data?, !data.isEmpty else {
            throw Ext4Error.invalid
        }
        guard data.count <= 255 else { throw Ext4Error.posix(ENAMETOOLONG) }
        // A name containing '/' or NUL cannot exist in a directory entry.
        guard !data.contains(0x2F), !data.contains(0x00) else { throw Ext4Error.invalid }
        return data
    }
}

// MARK: - Directory packing

/// Carried through the C readdir callback. A struct rather than a class so it
/// lives on the stack for exactly the lifetime of the enumerate call.
private struct PackState {
    let packer: FSDirectoryEntryPacker
    unowned let volume: Ext4Volume
    let wanted: FSItem.Attribute?
    /// The directory being enumerated: every entry's parent, known for free.
    let parent: UInt32
    var thrown: Error?
}

private let packEntry: @convention(c) (UnsafeMutableRawPointer?,
                                       UnsafePointer<CChar>?,
                                       Int, UInt32, ext4b_item_type, UInt64) -> Bool = {
    ctx, namePtr, nameLen, inode, type, nextCookie in

    guard let ctx, let namePtr else { return false }
    let state = ctx.assumingMemoryBound(to: PackState.self)

    // ext4 stores "." and ".." as real directory entries, but the VFS layer
    // above FSKit synthesises them. Packing them as well makes every listing
    // show each twice.
    if nameLen == 1, namePtr[0] == 0x2E { return true }                       // "."
    if nameLen == 2, namePtr[0] == 0x2E, namePtr[1] == 0x2E { return true }   // ".."

    let name = FSFileName(data: Data(bytes: namePtr, count: nameLen))

    // Attributes are only fetched when the kernel actually asked for them;
    // a readdir that does not need them should not pay for an inode read each.
    var attributes: FSItem.Attributes?
    if let wanted = state.pointee.wanted {
        if let a = try? state.pointee.volume.fetchAttributes(inode: inode) {
            let out = FSItem.Attributes()
            state.pointee.volume.populate(out, from: a, requested: wanted,
                                          parentHint: state.pointee.parent)
            attributes = out
        }
    }

    return state.pointee.packer.packEntry(name: name,
                                          itemType: type.fsItemType,
                                          itemID: FSItem.Identifier(rawValue: UInt64(inode))!,
                                          nextCookie: FSDirectoryCookie(rawValue: nextCookie),
                                          attributes: attributes)
}
