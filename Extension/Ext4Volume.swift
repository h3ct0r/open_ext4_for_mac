//
//  Ext4Volume.swift
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FSKit
import Ext4Core

/// An ext2/ext3/ext4 volume presented to macOS.
///
/// Every method here is reached from the kernel's VFS layer via FSKit, and all
/// of them funnel into the C core through `executor` — lwext4 is not thread
/// safe, and FSKit calls us concurrently.
final class Ext4Volume: FSVolume {

    let bridge: BlockDeviceBridge
    let executor: Ext4Executor
    let identity: IdentityMapper

    /// The owning filesystem, so volume lifecycle can drive the container
    /// state machine FSKit requires. Weak: the filesystem owns the volume.
    weak var fileSystem: Ext4FileSystem?
    let probe: ext4b_probe_info

    /// True when the volume is mounted read-only, either because the media is
    /// read-only, because the user asked for it, or because the feature gate
    /// downgraded it.
    let isReadOnly: Bool

    var device: OpaquePointer { bridge.device! }

    /// Items handed out to FSKit, keyed by inode, so that repeated lookups of
    /// the same object return the same instance. FSKit balances these against
    /// `reclaimItem`.
    var liveItems: [UInt32: Ext4Item] = [:]
    let itemsLock = NSLock()

    init(bridge: BlockDeviceBridge,
         executor: Ext4Executor,
         probe: ext4b_probe_info,
         readOnly: Bool,
         identity: IdentityMapper) {
        self.bridge = bridge
        self.executor = executor
        self.probe = probe
        self.isReadOnly = readOnly
        self.identity = identity

        let name = Self.volumeName(from: probe)
        let uuid = Self.volumeUUID(from: probe)
        super.init(volumeID: FSVolume.Identifier(uuid: uuid),
                   volumeName: FSFileName(string: name))
    }

    // MARK: - Naming

    private static func volumeName(from probe: ext4b_probe_info) -> String {
        var label = probe.label
        let text = withUnsafeBytes(of: &label) { raw -> String in
            let bytes = raw.bindMemory(to: CChar.self)
            return String(cString: bytes.baseAddress!)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return "ext\(probe.generation) Volume"
    }

    private static func volumeUUID(from probe: ext4b_probe_info) -> UUID {
        var raw = probe.uuid
        return withUnsafeBytes(of: &raw) { buf in
            UUID(uuid: (buf[0], buf[1], buf[2],  buf[3],  buf[4],  buf[5],  buf[6],  buf[7],
                        buf[8], buf[9], buf[10], buf[11], buf[12], buf[13], buf[14], buf[15]))
        }
    }

    // MARK: - Item bookkeeping

    func item(for inode: UInt32) -> Ext4Item {
        itemsLock.lock()
        defer { itemsLock.unlock() }
        if let existing = liveItems[inode] { return existing }
        let fresh = Ext4Item(inode: inode)
        liveItems[inode] = fresh
        return fresh
    }

    /// Drop every cached item. Synchronous by design: NSLock must not be held
    /// across a suspension point.
    func forgetAllItems() {
        itemsLock.lock()
        liveItems.removeAll()
        itemsLock.unlock()
    }

    func forget(_ item: Ext4Item) {
        itemsLock.lock()
        liveItems.removeValue(forKey: item.inode)
        itemsLock.unlock()
    }

    /// Synchronous attribute fetch. Callers must already be on the executor.
    func fetchAttributes(inode: UInt32) throws -> ext4b_attrs {
        var attrs = ext4b_attrs()
        try Ext4Error.check(ext4b_getattr(device, inode, &attrs),
                            "getattr(\(inode))")
        return attrs
    }

    // MARK: - Attribute translation

    func populate(_ target: FSItem.Attributes,
                          from a: ext4b_attrs,
                          requested: FSItem.Attribute) {
        let isDir = a.type == EXT4B_TYPE_DIR

        if requested.contains(.type)      { target.type = a.type.fsItemType }
        if requested.contains(.mode)      { target.mode = identity.mode(onDisk: a.mode, isDirectory: isDir) }
        if requested.contains(.uid)       { target.uid  = identity.uid(onDisk: a.uid) }
        if requested.contains(.gid)       { target.gid  = identity.gid(onDisk: a.gid) }
        if requested.contains(.linkCount) { target.linkCount = a.link_count }
        if requested.contains(.size)      { target.size = a.size }
        if requested.contains(.allocSize) { target.allocSize = a.alloc_size }
        if requested.contains(.fileID)    { target.fileID = FSItem.Identifier(rawValue: UInt64(a.inode))! }

        // FSKit rejects the whole response if any requested attribute is
        // missing ("Reported attributes are incomplete"), which then stops it
        // reading inhibitKernelOffloadedIO and sends every write down the
        // blockmap path. Both of these must always be answered.
        if requested.contains(.flags) {
            // BSD flags (UF_HIDDEN, UF_IMMUTABLE, ...). ext4's own inode flags
            // are a different space and are reported separately; nothing here
            // maps onto them, so report none set.
            target.flags = 0
        }
        if requested.contains(.parentID) {
            target.parentID = FSItem.Identifier(rawValue: UInt64(parentInode(of: a)))
                ?? FSItem.Identifier.parentOfRoot
        }

        if requested.contains(.accessTime) { target.accessTime = timespec(tv_sec: Int(a.atime), tv_nsec: Int(a.atime_ns)) }
        if requested.contains(.modifyTime) { target.modifyTime = timespec(tv_sec: Int(a.mtime), tv_nsec: Int(a.mtime_ns)) }
        if requested.contains(.changeTime) { target.changeTime = timespec(tv_sec: Int(a.ctime), tv_nsec: Int(a.ctime_ns)) }
        if requested.contains(.birthTime)  { target.birthTime  = timespec(tv_sec: Int(a.crtime), tv_nsec: Int(a.crtime_ns)) }

        // Which I/O path the kernel uses for this file.
        //
        // Kernel-offloaded I/O hands the kernel an extent map and lets it move
        // the bytes itself. That is only safe for *reads* today: a write
        // blockmap would have to allocate blocks and journal the extent-tree
        // changes before returning, and there is no way to roll that back if
        // the kernel then fails the I/O. Until that is implemented, any file
        // opened for writing must use the byte-copy path, where allocation
        // happens inside a transaction we control.
        //
        // ext2/ext3 indirect-block and inline-data inodes have no extent tree
        // at all, so they always take the byte-copy path.
        if requested.contains(.inhibitKernelOffloadedIO) {
            // The volume does not vend kernel-offloaded I/O at all right now,
            // so every file takes the byte-copy path.
            target.inhibitKernelOffloadedIO = true
        }
    }

    /// Resolve an item's parent. A directory's ".." is authoritative; for
    /// anything else the best available answer is the directory it was reached
    /// through, since a hard-linked inode has no single parent.
    private func parentInode(of a: ext4b_attrs) -> UInt32 {
        if a.inode == UInt32(EXT4B_ROOT_INO) { return UInt32(EXT4B_ROOT_INO) }

        if a.type == EXT4B_TYPE_DIR {
            var found: UInt32 = 0
            var type = EXT4B_TYPE_UNKNOWN
            let rc = "..".withCString { dotdot in
                ext4b_lookup(device, a.inode, dotdot, 2, &found, &type)
            }
            if rc == 0, found != 0 { return found }
        }

        itemsLock.lock()
        let hint = liveItems[a.inode]?.parent
        itemsLock.unlock()
        return hint ?? UInt32(EXT4B_ROOT_INO)
    }

    // MARK: - Capabilities

    var supportedCapabilities: FSVolume.SupportedCapabilities {
        let caps = FSVolume.SupportedCapabilities()
        caps.supportsPersistentObjectIDs = true
        caps.supportsSymbolicLinks = true
        caps.supportsHardLinks = true
        caps.supportsSparseFiles = true
        caps.supports2TBFiles = true
        caps.supports64BitObjectIDs = true
        caps.supportsJournal = probe.has_journal
        caps.supportsActiveJournal = probe.has_journal && !isReadOnly
        caps.supportsHiddenFiles = false
        caps.supportsFastStatFS = true
        // ext4 filenames are byte strings compared exactly; there is no case
        // folding unless the casefold feature is set, which we refuse to mount.
        caps.caseFormat = .sensitive
        caps.doesNotSupportImmutableFiles = true
        caps.doesNotSupportSettingFilePermissions = false
        return caps
    }
}
