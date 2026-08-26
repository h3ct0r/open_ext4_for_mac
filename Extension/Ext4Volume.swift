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

    /// The live core handle.
    ///
    /// FSKit can still deliver operations after `unmount()` has closed the
    /// volume — `synchronize` reliably arrives afterwards — so this has to be
    /// able to fail. Force-unwrapping here turned every one of those late
    /// calls into a SIGTRAP that killed the extension. The volume was already
    /// safely on disk by then, which is exactly why it went unnoticed: the
    /// only visible trace was a crash report per unmount.
    var device: OpaquePointer {
        get throws {
            guard let dev = bridge.device else { throw Ext4Error.gone }
            return dev
        }
    }

    /// Non-throwing form, for the two places FSKit gives us no way to fail.
    var deviceIfOpen: OpaquePointer? { bridge.device }

    /// Items handed out to FSKit, keyed by inode, so that repeated lookups of
    /// the same object return the same instance. FSKit balances these against
    /// `reclaimItem`.
    var liveItems: [UInt32: Ext4Item] = [:]
    let itemsLock = NSLock()

    /// Take `itemsLock` for the duration of a synchronous body.
    ///
    /// Not a convenience: `NSLock.lock()` is unavailable from an async context
    /// -- an error in Swift 6 -- because a suspension while holding it can
    /// resume on a different thread and unlock from the wrong one. Every
    /// critical section here is a handful of dictionary accesses with no
    /// `await` in it, and this makes that structurally true rather than a
    /// convention.
    @inline(__always)
    func withItems<T>(_ body: () -> T) -> T {
        itemsLock.lock()
        defer { itemsLock.unlock() }
        return body()
    }

    /// Inodes whose last name is gone but which are still allocated, because
    /// the kernel may still have the file open. Guarded by `itemsLock`.
    ///
    /// This set is the *live* half of the bookkeeping and exists only in
    /// memory; the durable half is ext4's own orphan list, which the core puts
    /// the inode on for as long as it is in this state. So an unclean shutdown
    /// with entries still here is recoverable rather than a leak -- the next
    /// mount settles them. Every ordinary path -- last close, deactivation,
    /// reclaim, and unmount -- drains this set first.
    private var pendingRelease: Set<UInt32> = []

    /// How many times each inode is currently open. Guarded by `itemsLock`.
    var openCounts: [UInt32: Int] = [:]

    /// Whether anything holds this inode open right now.
    func isOpen(_ inode: UInt32) -> Bool {
        withItems { (openCounts[inode] ?? 0) > 0 }
    }

    func notePendingRelease(_ inode: UInt32) {
        withItems { _ = pendingRelease.insert(inode) }
    }

    /// Free the inode if it was waiting for its last user to go away.
    /// Returns true when a release actually happened.
    @discardableResult
    func releaseIfPending(_ inode: UInt32) async -> Bool {
        let waiting = withItems { pendingRelease.remove(inode) != nil }
        guard waiting else { return false }

        do {
            try await executor.run { [self] in
                try Ext4Error.check(ext4b_release_inode(try device, inode),
                                    "release inode \(inode)")
            }
            return true
        } catch {
            // Put it back: a failure here means the inode is still allocated,
            // and unmount gets another attempt.
            withItems { _ = pendingRelease.insert(inode) }
            Ext4Log.error("could not release inode \(inode): \(error.localizedDescription)")
            return false
        }
    }

    /// Drain everything still waiting. Called on the way out, so that a clean
    /// unmount never leaves an unreferenced inode behind.
    func releaseAllPending() async {
        let waiting = withItems { () -> Set<UInt32> in
            let snapshot = pendingRelease
            pendingRelease.removeAll()
            return snapshot
        }

        for inode in waiting {
            do {
                try await executor.run { [self] in
                    try Ext4Error.check(ext4b_release_inode(try device, inode),
                                        "release inode \(inode)")
                }
            } catch {
                Ext4Log.error("could not release inode \(inode) at unmount: "
                              + error.localizedDescription)
            }
        }
        if !waiting.isEmpty {
            Ext4Log.volume.info("released \(waiting.count) deferred inode(s)")
        }
    }

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
        withItems {
            if let existing = liveItems[inode] { return existing }
            let fresh = Ext4Item(inode: inode)
            liveItems[inode] = fresh
            return fresh
        }
    }

    /// Drop every cached item.
    func forgetAllItems() {
        withItems { liveItems.removeAll() }
    }

    func forget(_ item: Ext4Item) {
        withItems { _ = liveItems.removeValue(forKey: item.inode) }
    }

    /// ext4's inode flags, in the BSD `st_flags` vocabulary macOS speaks.
    ///
    /// Two of ext4's flags mean exactly what two BSD flags mean, and they are
    /// the two this driver enforces: `chattr +i` is `UF_IMMUTABLE` and
    /// `chattr +a` is `UF_APPEND`. Reporting them is what turns a refusal into
    /// something the user can see — Finder shows the file as locked, `ls -lO`
    /// names the flag — instead of an unexplained "Operation not permitted".
    ///
    /// The rest of ext4's flags word describes on-disk layout (extents, inline
    /// data, hashed directories) and has no BSD counterpart, so it is not
    /// reported here.
    static func bsdFlags(from a: ext4b_attrs) -> UInt32 {
        var flags: UInt32 = 0
        if a.flags & EXT4B_INODE_IMMUTABLE != 0   { flags |= UInt32(UF_IMMUTABLE) }
        if a.flags & EXT4B_INODE_APPEND_ONLY != 0 { flags |= UInt32(UF_APPEND) }
        return flags
    }

    /// Synchronous attribute fetch. Callers must already be on the executor.
    func fetchAttributes(inode: UInt32) throws -> ext4b_attrs {
        var attrs = ext4b_attrs()
        try Ext4Error.check(ext4b_getattr(device, inode, &attrs),
                            "getattr(\(inode))")
        return attrs
    }

    // MARK: - Attribute translation

    /// Translate on-disk attributes into an `FSItem.Attributes`.
    ///
    /// **Must run on the executor.** Resolving `parentID` reads the directory's
    /// ".." entry, which is another call into the core. Calling this after the
    /// executor block rather than inside it lets two kernel threads enter
    /// lwext4 at once; they corrupt the block cache's LRU list and spin
    /// forever inside `ext4_bcache_free`, wedging the whole volume.
    ///
    /// `parentHint` supplies the parent when the caller already knows it —
    /// during enumeration every entry's parent is the directory being read —
    /// which avoids the ".." lookup entirely.
    func populate(_ target: FSItem.Attributes,
                          from a: ext4b_attrs,
                          requested: FSItem.Attribute,
                          parentHint: UInt32? = nil) {
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
            target.flags = Self.bsdFlags(from: a)
        }
        if requested.contains(.parentID) {
            let parent = parentHint ?? parentInode(of: a)
            target.parentID = FSItem.Identifier(rawValue: UInt64(parent))
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

        if a.type == EXT4B_TYPE_DIR, let dev = deviceIfOpen {
            var found: UInt32 = 0
            var type = EXT4B_TYPE_UNKNOWN
            let rc = "..".withCString { dotdot in
                ext4b_lookup(dev, a.inode, dotdot, 2, &found, &type)
            }
            if rc == 0, found != 0 { return found }
        }

        let hint = withItems { liveItems[a.inode]?.parent }
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
