//
//  Ext4FileSystem+Maintenance.swift
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FSKit
import Ext4Core

//
// Format and check, as reached from the command line through the generic
// drivers macOS ships:
//
//     newfs_fskit -t ext4 [options] /dev/diskNsM
//     fsck_fskit  -t ext4 [options] /dev/diskNsM
//
// `-t ext4` selects the *module* by its FSShortName, not one of our
// personalities, so which of ext2/ext3/ext4 to create is a module option (-g)
// rather than something FSKit tells us.
//
// The option letters below are declared in Info.plist under
// FSFormatOptionSyntax / FSCheckOptionSyntax. FSKit parses them with getopt
// and hands the result over as an argv-shaped array; anything not declared
// there is rejected before it reaches us.
//

extension Ext4FileSystem: FSManageableResourceMaintenanceOperations {

    // MARK: - Format

    func startFormat(task: FSTask, options: FSTaskOptions) throws -> Progress {
        // First statement on purpose. os_log from this extension does not reach
        // `log show`, but FSTask.logMessage is printed by newfs_fskit itself,
        // so this is the only reliable way to tell "we were never called" from
        // "we were called and failed".
        task.logMessage("startFormat entered, options: \(options.taskOptions)")
        let resource = try maintenanceResource()
        let request = try FormatRequest(arguments: options.taskOptions)

        guard resource.isWritable else {
            throw Ext4Error.posix(EROFS)
        }

        // Two units: close any live mount of the device, then build the
        // filesystem. Foreign-signature wiping happens inside ext4b_format --
        // FSKit's wipeResource facility is unreachable from a CLI-initiated
        // format ("no connector talking to fskitd is available"), which was
        // the last failure between newfs_fskit and a working volume.
        let progress = Progress(totalUnitCount: 2)

        Task.detached { [weak self] in
            guard let self else { return }
            do {
                task.logMessage("creating ext\(request.generation) on \(resource.bsdName)")

                // If the load that preceded this format found a mountable
                // filesystem, it mounted it -- journal attached, cache live.
                // That handle must be gone before the new filesystem is
                // written: closing it *afterwards* would write the old
                // superblock over the new volume on unload. Idempotent, and a
                // no-op for the usual case of unformatted media.
                await self.closeVolume()
                progress.completedUnitCount = 1

                try await self.format(resource, request: request)
                progress.completedUnitCount = 2

                task.logMessage("created ext\(request.generation) volume "
                                + "\(request.label.map { "\"\($0)\" " } ?? "")"
                                + "with \(request.blockSize ?? 4096)-byte blocks")
                task.didComplete(error: nil)
            } catch {
                Ext4Log.error("format failed: \(error.localizedDescription)")
                task.didComplete(error: error as NSError)
            }
        }

        return progress
    }

    private func format(_ resource: FSBlockDeviceResource,
                        request: FormatRequest) async throws {
        guard let bridge = BlockDeviceBridge(resource: resource, forceReadOnly: false),
              let dev = bridge.device else {
            throw Ext4Error.ioError
        }
        defer { bridge.close() }

        let handle = UInt(bitPattern: dev)
        let opts = request.bridgeOptions()
        let label = request.label
        try await executor.run {
            var opts = opts
            // The label is a borrowed C string: it has to stay alive for
            // exactly the duration of the call, so it is bound here rather
            // than in bridgeOptions().
            if let label {
                try label.withCString { c in
                    opts.label = c
                    try Ext4Error.check(ext4b_format(OpaquePointer(bitPattern: handle), &opts),
                                        "format")
                }
            } else {
                try Ext4Error.check(ext4b_format(OpaquePointer(bitPattern: handle), &opts),
                                    "format")
            }
        }
    }

    // MARK: - Check

    func startCheck(task: FSTask, options: FSTaskOptions) throws -> Progress {
        task.logMessage("startCheck entered, options: \(options.taskOptions)")
        let resource = try maintenanceResource()
        let request = CheckRequest(arguments: options.taskOptions)
        let progress = Progress(totalUnitCount: 1)

        Task.detached { [weak self] in
            guard let self else { return }
            do {
                try await self.check(resource, request: request, task: task)
                progress.completedUnitCount = 1
                task.didComplete(error: nil)
            } catch {
                task.didComplete(error: error as NSError)
            }
        }

        return progress
    }

    //
    // What this actually verifies -- and what it does not.
    //
    // This is **not** a structural check. It does not walk the inode table,
    // cross-check block bitmaps against extent trees, or repair anything;
    // lwext4 has no fsck and writing one is a much larger job than wrapping a
    // formatter. What it does is decide whether the volume can be mounted
    // safely, which is the question FSKit asks before a mount:
    //
    //   * the superblock parses, and the feature gate accepts every flag on it
    //   * the checksum seed still matches the UUID, if the volume uses one
    //   * a dirty journal is replayed, so the volume is left consistent with
    //     the last committed transaction rather than mid-transaction
    //
    // A volume that passes here can still be corrupt in ways only e2fsck will
    // find. The honest advice is in the README: run e2fsck for a real check.
    // Reporting success on a volume we would refuse to mount would be worse
    // than declining the operation, which is why this exists at all.
    //
    private func check(_ resource: FSBlockDeviceResource,
                       request: CheckRequest,
                       task: FSTask) async throws {
        // FSKit loads the resource *before* calling this -- fskitd says so in
        // its own log -- so by the time a check runs during a mount, the
        // volume is already open and its journal already attached. Opening a
        // second, independent view of the same device here is not a check, it
        // is a second writer: the journal looks unrecovered from the outside,
        // and replaying it underneath the live mount fails with EINVAL at
        // best. DiskArbitration then abandons the mount and falls back to
        // read-only, which is how an encrypted volume ended up mounting
        // read-only through Finder while `mount -F` gave it read-write.
        //
        // A volume that is mounted has answered the only question this check
        // asks.
        if let volume {
            // Mounted is the answer to the mountability question, but it is
            // not the only question worth asking, and until there was a
            // structural check this returned having verified nothing at all --
            // every volume reaching here is mounted, so the early return was
            // the only path.
            //
            // Walking the tree through the *existing* handle is safe in a way
            // that opening a second one is not: it reads, and it reads what
            // the live mount would read.
            task.logMessage("the volume is mounted, so it is mountable")
            try await volume.reportStructuralCheck(to: task)
            return
        }

        let readOnly = request.readOnly || !resource.isWritable
        guard let bridge = BlockDeviceBridge(resource: resource, forceReadOnly: readOnly),
              var dev = bridge.device else {
            throw Ext4Error.ioError
        }
        defer { bridge.close() }

        // An encrypted volume has to be opened through the cipher here too.
        // Without this the probe below reads a LUKS header where it expects a
        // superblock, reports NOT_EXT, and the check fails with ENOTSUP --
        // which DiskArbitration runs before every mount it performs, so it
        // took Finder and `Ext4Mac mount` down with it while `mount -F`, which
        // skips the check, kept working.
        if try Ext4LUKSKeys.openEncryptedIfNeeded(bridge) {
            guard let decrypted = bridge.device else { throw Ext4Error.ioError }
            dev = decrypted
            task.logMessage("volume is inside a LUKS container")
        }

        var info = ext4b_probe_info()
        try Ext4Error.check(ext4b_probe(dev, &info), "probe")

        switch info.verdict {
        case EXT4B_PROBE_NOT_EXT:
            task.logMessage("not an ext2/3/4 volume")
            throw Ext4Error.notSupported
        case EXT4B_PROBE_UNSUPPORTED:
            task.logMessage("cannot check this volume: \(Self.reason(info))")
            throw Ext4Error.notSupported
        default:
            break
        }

        task.logMessage("ext\(info.generation) volume, \(info.block_count) blocks "
                        + "of \(info.block_size) bytes")

        guard info.needs_recovery else {
            task.logMessage("clean; the journal does not need replaying")
            task.logMessage("note: this is a mountability check, not a full "
                            + "structural check -- use e2fsck for that")
            return
        }

        guard !readOnly else {
            // Not a failure. The volume is mountable; the replay simply
            // happens when something opens it for writing, which `loadResource`
            // does before it lets anyone near the filesystem. Reporting EROFS
            // here made DiskArbitration downgrade the mount it was about to
            // perform -- refusing the check is not the same as refusing the
            // volume, and only the second one was ever meant.
            task.logMessage("journal needs replaying; that happens on the next "
                            + "read-write mount, which this check cannot perform")
            return
        }

        let handle = UInt(bitPattern: dev)
        try await executor.run {
            try Ext4Error.check(ext4b_journal_recover(OpaquePointer(bitPattern: handle)),
                                "journal recovery")
        }
        task.logMessage("replayed the journal")
        task.logMessage("note: this is a mountability check, not a full "
                        + "structural check -- use e2fsck for that")
    }

    // MARK: - Finding the resource

    //
    // Neither startFormat nor startCheck is given a resource, and there is no
    // resource property on FSUnaryFileSystem, so the object has to have been
    // handed to us through one of the other entry points first. In practice
    // fskitd probes the device before it asks for maintenance on it, so the
    // resource the probe saw is the one being operated on.
    //
    private func maintenanceResource() throws -> FSBlockDeviceResource {
        // The resolution lives on Ext4FileSystem, where the lock-guarded state
        // is reachable; it prefers the live mount and refuses to guess when
        // more than one device has been probed. ENODEV rather than ENOTSUP so
        // it is distinguishable from "this module does not do formatting".
        try maintenanceTarget()
    }
}

// MARK: - Options

/// `newfs_fskit -t ext4 [-g 2|3|4] [-b size] [-L label] [-I size] [-N count]
///                      [-J blocks] [-n] device`
struct FormatRequest {
    var generation = 4
    var blockSize: UInt32?
    var inodeSize: UInt32?
    var inodeCount: UInt32?
    var journalBlocks: UInt32?
    var journal: Bool?
    var label: String?

    init(arguments: [String]) throws {
        var it = arguments.makeIterator()
        // FSKit hands the options over argv-style, so a value follows its flag
        // as a separate element.
        func value(_ flag: String) throws -> String {
            guard let v = it.next() else {
                Ext4Log.error("\(flag) needs a value")
                throw Ext4Error.invalid
            }
            return v
        }

        while let arg = it.next() {
            switch arg {
            case "-g":
                let raw = try value("-g")
                guard let g = Int(raw), (2...4).contains(g) else { throw Ext4Error.invalid }
                generation = g
            case "-b":
                let raw = try value("-b")
                guard let b = UInt32(raw), [1024, 2048, 4096].contains(b) else {
                    Ext4Log.error("block size must be 1024, 2048 or 4096")
                    throw Ext4Error.invalid
                }
                blockSize = b
            case "-I":
                guard let v = UInt32(try value("-I")), v >= 128, v.nonzeroBitCount == 1 else {
                    throw Ext4Error.invalid
                }
                inodeSize = v
            case "-N":
                guard let v = UInt32(try value("-N")), v > 0 else { throw Ext4Error.invalid }
                inodeCount = v
            case "-J":
                guard let v = UInt32(try value("-J")), v > 0 else { throw Ext4Error.invalid }
                journalBlocks = v
            case "-n":
                journal = false
            case "-L":
                let raw = try value("-L")
                // ext4's label field is 16 bytes with no terminator.
                guard raw.utf8.count <= 16 else {
                    Ext4Log.error("label must be at most 16 bytes")
                    throw Ext4Error.invalid
                }
                label = raw
            default:
                Ext4Log.error("unrecognised format option \(arg)")
                throw Ext4Error.invalid
            }
        }

        // ext2 predates the journal; ext3 and ext4 are defined by having one.
        if generation == 2 {
            guard journal != true else { throw Ext4Error.invalid }
            journal = false
        }
        if journal == nil { journal = generation != 2 }
        if journalBlocks != nil && journal == false { throw Ext4Error.invalid }
    }

    func bridgeOptions() -> ext4b_format_options {
        var opts = ext4b_format_options()
        opts.generation = Int32(generation)
        opts.block_size = blockSize ?? 0
        opts.inode_size = inodeSize ?? 0
        opts.inode_count = inodeCount ?? 0
        opts.journal_blocks = journalBlocks ?? 0
        opts.journal = journal ?? (generation != 2)
        withUnsafeMutableBytes(of: &opts.uuid) { raw in
            // A volume with a zero UUID is indistinguishable from every other
            // volume we ever format: DiskArbitration keys on it, and lwext4's
            // mkfs copies whatever it is given straight into the superblock
            // without generating one.
            var uuid = UUID().uuid
            withUnsafeBytes(of: &uuid) { raw.copyMemory(from: $0) }
        }
        return opts
    }
}

/// `fsck_fskit -t ext4 [-n] device`. `-n` means "answer no to everything",
/// which for us means "do not write, so do not replay the journal either".
struct CheckRequest {
    var readOnly = false

    init(arguments: [String]) {
        readOnly = arguments.contains("-n")
    }
}
