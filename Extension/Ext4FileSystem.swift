//
//  Ext4FileSystem.swift
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FSKit
import Ext4Core

/// The extension's entry point into FSKit.
///
/// `FSUnaryFileSystem` means one resource presented as exactly one volume,
/// which is what a disk partition is. FSKit calls `probeResource` to ask
/// whether we recognise some media, then `loadResource` to actually open it.
final class Ext4FileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations {

    let executor = Ext4Executor()
    private var bridge: BlockDeviceBridge?
    private var volume: Ext4Volume?

    /// The last resource FSKit presented, whether to probe or to load.
    ///
    /// The maintenance operations -- startFormat and startCheck -- are handed
    /// a task and options but no resource, and FSUnaryFileSystem has no
    /// resource property, so this is the only way to know what to operate on.
    /// fskitd probes a device before asking for maintenance on it.
    private(set) var lastSeenResource: FSBlockDeviceResource?

    // MARK: - Probe

    func probeResource(resource: FSResource) async throws -> FSProbeResult {
        guard let device = resource as? FSBlockDeviceResource else {
            return .notRecognized
        }
        lastSeenResource = device

        guard let bridge = BlockDeviceBridge(resource: device, forceReadOnly: true, mode: .direct),
              let dev = bridge.device else {
            return .notRecognized
        }
        defer { bridge.close() }

        var info = ext4b_probe_info()
        guard ext4b_probe(dev, &info) == 0 else {
            return .notRecognized
        }

        switch info.verdict {
        case EXT4B_PROBE_NOT_EXT:
            return .notRecognized

        case EXT4B_PROBE_UNSUPPORTED:
            Ext4Log.info("declining volume: \(Self.reason(info))")
            return .notRecognized

        case EXT4B_PROBE_READ_ONLY:
            Ext4Log.info("volume usable read-only: \(Self.reason(info))")
            return .usableButLimited(name: Self.name(info),
                                     containerID: Self.containerID(info))

        default:
            return .usable(name: Self.name(info),
                           containerID: Self.containerID(info))
        }
    }

    // MARK: - Load / unload

    func loadResource(resource: FSResource,
                      options: FSTaskOptions) async throws -> FSVolume {
        guard let device = resource as? FSBlockDeviceResource else {
            throw Ext4Error.notSupported
        }
        lastSeenResource = device

        //
        // Mount mode.
        //
        // FSKit gives the module no way to receive user mount options: the
        // header for mount(options:) states "there are no defined options
        // currently", and taskOptions arrives empty for -o rw, -o ro and -r
        // alike. An opt-in flag is therefore not expressible, so the volume
        // mounts read-write whenever that is safe and read-only when it is not
        // -- the same contract every other filesystem offers.
        //
        // "Safe" is decided by the probe, not by optimism. A volume is refused
        // write access when the media is read-only, when it uses features we
        // do not implement, or when its checksum seed no longer matches its
        // UUID. A dirty journal is replayed before the volume is written.
        //
        let mediaWritable = device.isWritable
        let readOnly = !mediaWritable

        guard let bridge = BlockDeviceBridge(resource: device, forceReadOnly: readOnly),
              let dev = bridge.device else {
            throw Ext4Error.ioError
        }

        var info = ext4b_probe_info()
        try Ext4Error.check(ext4b_probe(dev, &info), "probe")

        // A volume the probe only rates usable-but-limited must never be
        // written, whatever the media allows.
        let effectiveReadOnly = readOnly || info.verdict == EXT4B_PROBE_READ_ONLY

        guard info.verdict == EXT4B_PROBE_USABLE || info.verdict == EXT4B_PROBE_READ_ONLY else {
            bridge.close()
            Ext4Log.error("refusing to mount: \(Self.reason(info))")
            throw Ext4Error.notSupported
        }

        try executor.runSync {
            // ext4b_mount replays the journal and attaches it for read-write
            // mounts; it fails rather than proceeding if either step fails.
            try Ext4Error.check(ext4b_mount(dev, effectiveReadOnly), "mount")
        }

        let volume = Ext4Volume(bridge: bridge,
                                executor: executor,
                                probe: info,
                                readOnly: effectiveReadOnly,
                                identity: IdentityMapper())
        volume.fileSystem = self
        self.bridge = bridge
        self.volume = volume

        // FSKit tracks a container state machine and rejects the load with
        // EAGAIN ("unexpected container state") if the resource is still
        // NotReady when loadResource returns. Ready means "loaded, volume
        // available"; activate() moves it on to Active.
        containerStatus = FSContainerStatus.ready

        Ext4Log.info("mounted ext\(info.generation) volume \(effectiveReadOnly ? "read-only" : "read-write"), "
                     + "\(info.block_count) blocks of \(info.block_size)B")
        return volume
    }

    /// Cleanly close the volume: stop the journal (which clears the
    /// needs-recovery flag and writes the final superblock), unmount, flush.
    ///
    /// This has to be driven from the volume's `unmount`/`deactivate`, not from
    /// `unloadResource`: FSKit does not call `unloadResource` on umount(8) at
    /// all, so doing it there left every volume with an unreplayed journal and
    /// stale free counts, needing recovery on the next mount.
    ///
    /// Idempotent -- whichever callback arrives first does the work.
    ///
    /// Async on purpose. A synchronous version deadlocks: the callers are async
    /// and resume on the executor's own queue after awaiting it, so a
    /// `queue.sync` from there blocks the queue against itself.
    func closeVolume() async {
        guard let bridge, let dev = bridge.device else { return }
        // Carried across the concurrency boundary as an integer: OpaquePointer
        // is not Sendable, and the executor guarantees serial access anyway.
        let handle = UInt(bitPattern: dev)
        try? await executor.run {
            _ = ext4b_unmount(OpaquePointer(bitPattern: handle))
        }
        bridge.close()
        self.bridge = nil
        self.volume = nil
        Ext4Log.info("volume closed")
    }

    func unloadResource(resource: FSResource, options: FSTaskOptions) async throws {
        await closeVolume()
        containerStatus = FSContainerStatus.notReady(status: Ext4Error.posix(ENODEV) as NSError)
        Ext4Log.info("unloaded resource")
    }

    // MARK: - Helpers

    private static func name(_ info: ext4b_probe_info) -> String {
        var label = info.label
        let text = withUnsafeBytes(of: &label) { raw -> String in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "ext\(info.generation) Volume" : trimmed
    }

    private static func containerID(_ info: ext4b_probe_info) -> FSContainerIdentifier {
        var raw = info.uuid
        let uuid = withUnsafeBytes(of: &raw) { buf in
            UUID(uuid: (buf[0], buf[1], buf[2],  buf[3],  buf[4],  buf[5],  buf[6],  buf[7],
                        buf[8], buf[9], buf[10], buf[11], buf[12], buf[13], buf[14], buf[15]))
        }
        return FSContainerIdentifier(uuid: uuid)
    }

    static func reason(_ info: ext4b_probe_info) -> String {
        var text = info.unsupported
        return withUnsafeBytes(of: &text) { raw -> String in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
    }
}
