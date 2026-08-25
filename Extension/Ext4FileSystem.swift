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

    private let executor = Ext4Executor()
    private var bridge: BlockDeviceBridge?
    private var volume: Ext4Volume?

    // MARK: - Probe

    func probeResource(resource: FSResource) async throws -> FSProbeResult {
        guard let device = resource as? FSBlockDeviceResource else {
            return .notRecognized
        }

        guard let bridge = BlockDeviceBridge(resource: device, forceReadOnly: true),
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

        //
        // Mount mode. FSUnaryFileSystem defines -f (force) and --rdonly;
        // anything else arrives via -o.
        //
        // Read-only is the default *even when the caller did not ask for it*.
        // The write path passes its image-level suite (every operation checked
        // with e2fsck, cross-checked against debugfs), but it has not yet been
        // through crash-consistency testing, so enabling it silently on
        // somebody's only copy of a disk is not a defensible default. Opt in
        // explicitly with `-o rw`.
        //
        let opts = options.taskOptions
        let requestedReadOnly = opts.contains("--rdonly")
        let requestedWrite = opts.contains { $0 == "rw" || $0.hasSuffix(",rw") || $0.hasPrefix("rw,") }
        let readOnly = requestedReadOnly || !requestedWrite

        if readOnly && !requestedReadOnly {
            Ext4Log.info("mounting read-only; pass -o rw to enable writes "
                         + "(write support has not completed crash-consistency testing)")
        }

        guard let bridge = BlockDeviceBridge(resource: device, forceReadOnly: readOnly),
              let dev = bridge.device else {
            throw Ext4Error.ioError
        }

        var info = ext4b_probe_info()
        try Ext4Error.check(ext4b_probe(dev, &info), "probe")

        guard info.verdict == EXT4B_PROBE_USABLE || info.verdict == EXT4B_PROBE_READ_ONLY else {
            bridge.close()
            Ext4Log.error("refusing to mount: \(Self.reason(info))")
            throw Ext4Error.notSupported
        }

        try executor.runSync {
            // ext4b_mount replays the journal and attaches it for read-write
            // mounts; it fails rather than proceeding if either step fails.
            try Ext4Error.check(ext4b_mount(dev, readOnly), "mount")
        }

        let volume = Ext4Volume(bridge: bridge,
                                executor: executor,
                                probe: info,
                                readOnly: readOnly,
                                identity: IdentityMapper())
        volume.fileSystem = self
        self.bridge = bridge
        self.volume = volume

        // FSKit tracks a container state machine and rejects the load with
        // EAGAIN ("unexpected container state") if the resource is still
        // NotReady when loadResource returns. Ready means "loaded, volume
        // available"; activate() moves it on to Active.
        containerStatus = FSContainerStatus.ready

        Ext4Log.info("mounted ext\(info.generation) volume \(readOnly ? "read-only" : "read-write"), "
                     + "\(info.block_count) blocks of \(info.block_size)B")
        return volume
    }

    func unloadResource(resource: FSResource, options: FSTaskOptions) async throws {
        guard let bridge, let dev = bridge.device else { return }
        executor.runSync {
            _ = ext4b_unmount(dev)
        }
        bridge.close()
        self.bridge = nil
        self.volume = nil
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

    private static func reason(_ info: ext4b_probe_info) -> String {
        var text = info.unsupported
        return withUnsafeBytes(of: &text) { raw -> String in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
    }
}
