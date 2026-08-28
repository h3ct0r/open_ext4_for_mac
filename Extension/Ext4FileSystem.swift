//
//  Ext4FileSystem.swift
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FSKit
import Ext4Core
import os

/// The extension's entry point into FSKit.
///
/// `FSUnaryFileSystem` means one resource presented as exactly one volume,
/// which is what a disk partition is. FSKit calls `probeResource` to ask
/// whether we recognise some media, then `loadResource` to actually open it.
/// `@objc(Ext4FileSystem)` fixes the name the ObjC runtime knows this class by.
///
/// Without it a Swift class is registered under its mangled name --
/// `_TtC6Ext4FS14Ext4FileSystem` -- so anything looking the class up as
/// "Ext4FileSystem" finds nothing. That matters for `EXExtensionPrincipalClass`,
/// which is how Apple's own FSKit modules are wired (msdos declares
/// `msdosFileSystem` and its `startFormat` is reached; ours is not). Adding
/// that key was tried once and recorded as deregistering the module, which is
/// exactly what an unresolvable principal class looks like from outside.
///
/// The name is free and changes nothing on its own. Whether the key can then
/// be added without FSKit dropping the module is a separate experiment.
@objc(Ext4FileSystem)
final class Ext4FileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations {

    let executor = Ext4Executor()

    /// All the mount state that FSKit reaches from more than one concurrent
    /// callback -- probe, load, unload, the volume's own unmount/deactivate,
    /// and the detached startFormat task all touch it. It was a handful of
    /// bare `var`s with no synchronisation, which raced: two closeVolume
    /// callers (unmount and deactivate both fire on a normal umount) each
    /// passing a guard and then both calling ext4b_unmount on the same handle.
    ///
    /// The rule is simple and enforced by construction: the lock is never held
    /// across an `await`. Anything that must suspend -- unmounting through the
    /// executor -- first *takes ownership* of what it needs out of the struct
    /// under the lock, then awaits on the local copy. A second caller that
    /// takes next finds nil and does nothing.
    private struct MountState {
        var bridge: BlockDeviceBridge?
        var volume: Ext4Volume?
        /// The last resource FSKit presented, whether to probe or to load. The
        /// maintenance operations get a task but no resource, so this is how
        /// startFormat/startCheck know what to operate on.
        var lastSeen: FSBlockDeviceResource?
        /// Every distinct device this process has been asked to probe. If it is
        /// more than one, `lastSeen` is not a safe guess for a format target.
        var probedBSDNames: Set<String> = []
    }
    private let state = OSAllocatedUnfairLock(uncheckedState: MountState())

    /// The live volume, when there is one. Read by the maintenance operations:
    /// FSKit loads a resource before asking for a check on it, so "is this
    /// already mounted" is a question the check has to be able to ask.
    var volume: Ext4Volume? { state.withLock { $0.volume } }

    /// The device startFormat/startCheck should operate on. They are handed no
    /// resource, so it has to come from what this process has already seen --
    /// but "last seen" is a trap: any probe of any device overwrites it, so a
    /// format could land on whichever disk fskitd probed last. Resolution
    /// order: (1) the live mount's own resource, the only certain answer;
    /// (2) the last-probed resource, but ONLY if this process has seen exactly
    /// one device; (3) otherwise refuse rather than guess.
    func maintenanceTarget() throws -> FSBlockDeviceResource {
        try state.withLock {
            if let bridge = $0.bridge {
                return bridge.resource
            }
            guard let last = $0.lastSeen else {
                Ext4Log.error("maintenance requested but no resource has been presented")
                throw Ext4Error.posix(ENODEV)
            }
            if $0.probedBSDNames.count > 1 {
                Ext4Log.error("ambiguous maintenance target: \(($0.probedBSDNames).count) "
                              + "devices probed by this process; refusing to guess")
                throw Ext4Error.posix(ENODEV)
            }
            return last
        }
    }

    // MARK: - Probe

    func probeResource(resource: FSResource) async throws -> FSProbeResult {
        guard let device = resource as? FSBlockDeviceResource else {
            return .notRecognized
        }
        state.withLock {
            $0.lastSeen = device
            $0.probedBSDNames.insert(device.bsdName)
        }

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
            // Nothing here looks like ext4 -- which is exactly what an
            // encrypted volume looks like, because the superblock is behind
            // the cipher. Check for a LUKS header before giving up.
            return Self.probeLUKS(bridge)

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

    /// Second look at media the filesystem probe did not recognise.
    ///
    /// Claiming a locked container is what makes unlocking possible at all:
    /// FSKit routes a device only to a module that recognised it, so declining
    /// here would mean never being asked about the volume again.
    private static func probeLUKS(_ bridge: BlockDeviceBridge) -> FSProbeResult {
        guard let (status, info) = bridge.probeLUKS() else {
            return .notRecognized
        }
        guard status == LUKS_OK else {
            // A container whose cipher or KDF we do not implement. Declining
            // it is honest: claiming it would put a volume in front of the
            // user that can never be opened.
            Ext4Log.info("declining LUKS volume: \(Ext4LUKS.reason(info))")
            return .notRecognized
        }
        guard let container = Ext4LUKS.containerID(info) else {
            Ext4Log.info("declining LUKS volume: unreadable UUID")
            return .notRecognized
        }

        // With a key stored we can see the filesystem inside, and its own
        // label is a far better name than "LUKS2 Encrypted Volume" -- that is
        // what Finder puts under the icon and what /Volumes is named after.
        //
        // The identity stays the *container's* UUID either way. A volume that
        // changed identity the moment it stopped being locked would look to
        // macOS like a different volume from the one it had just seen.
        // openEncryptedIfNeeded distinguishes ENEEDAUTH (no key stored -- the
        // volume is simply locked) from EAUTH (a key IS stored but no longer
        // opens the container -- the passphrase changed, or the stored key is
        // stale). Both still present the locked container so the user can act,
        // but the second is worth a distinct log line: silently collapsing it
        // to "locked" hides why a supposedly-remembered volume keeps asking.
        var unlocked = false
        do {
            unlocked = try Ext4LUKSKeys.openEncryptedIfNeeded(bridge)
        } catch let e as NSError where e.domain == NSPOSIXErrorDomain && e.code == Int(EAUTH) {
            Ext4Log.info("LUKS\(info.version) container: stored key no longer opens it "
                         + "(EAUTH); presenting as locked")
        } catch {
            // ENEEDAUTH and anything else: locked, present it for unlocking.
        }
        if unlocked, let decrypted = bridge.device {
            var inner = ext4b_probe_info()
            if ext4b_probe(decrypted, &inner) == 0 {
                switch inner.verdict {
                case EXT4B_PROBE_USABLE:
                    return .usable(name: name(inner, or: info), containerID: container)
                case EXT4B_PROBE_READ_ONLY:
                    Ext4Log.info("encrypted volume usable read-only: \(reason(inner))")
                    return .usableButLimited(name: name(inner, or: info), containerID: container)
                default:
                    Ext4Log.info("declining volume inside LUKS: \(reason(inner))")
                    return .notRecognized
                }
            }
        }

        Ext4Log.info("LUKS\(info.version) container, \(info.sector_size)B sectors, locked")
        return .usable(name: Ext4LUKS.name(info), containerID: container)
    }

    /// The filesystem's own label, falling back to the container's name when
    /// the volume inside has none.
    private static func name(_ inner: ext4b_probe_info, or container: luks_info) -> String {
        var label = inner.label
        let text = withUnsafeBytes(of: &label) { raw -> String in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? Ext4LUKS.name(container) : text
    }

    // MARK: - Load / unload

    func loadResource(resource: FSResource,
                      options: FSTaskOptions) async throws -> FSVolume {
        guard let device = resource as? FSBlockDeviceResource else {
            throw Ext4Error.notSupported
        }

        // One volume per extension process. FSKit runs one instance per
        // resource (this is a unary file system), so a second live bridge here
        // means either a reload of the same device or a genuine second device
        // -- the latter is a contract violation we refuse loudly rather than
        // silently leaking the first bridge and its still-open volume.
        let existing = state.withLock { $0.bridge != nil ? $0.lastSeen?.bsdName : nil }
        if let existing {
            if existing == device.bsdName {
                Ext4Log.info("reloading \(device.bsdName); closing the previous mount first")
                await closeVolume()
            } else {
                Ext4Log.error("refusing to load \(device.bsdName): this extension "
                              + "process already has \(existing) mounted "
                              + "(one volume per process)")
                throw Ext4Error.posix(EBUSY)
            }
        }

        state.withLock {
            $0.lastSeen = device
            $0.probedBSDNames.insert(device.bsdName)
        }

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
        //
        // Removable media is writable exactly when ordering is real.
        //
        // The old policy -- read-only unless a marker said otherwise -- dated
        // from when no write barrier existed here at all, and a stick pulled
        // from under a live mount came back corrupt five times out of five.
        // The barrier exists now (the privileged helper), and with it the
        // same abuse was measured clean: five kill-recovery rounds and a
        // physical mid-write pull, every one recovered by journal replay.
        //
        // So ask the helper for an actual barrier on this actual device,
        // before deciding. It works: mount read-write, the proven-safe
        // configuration. It does not -- helper missing, unapproved, or denied
        // by TCC: mount read-only and say why, because unordered writes to a
        // physical stick are still the measured corruption they always were
        // (the reorder suite's negative controls keep proving it).
        //
        // The marker file remains as a manual override: writes without a
        // barrier, for someone who accepts the risk knowingly.
        //
        // Reading is untouched either way. A disk image is exempt from all of
        // this -- its writes reach APFS in issue order, which is why the media
        // class matters rather than the removable flag alone. And a device we
        // cannot read from the IORegistry is treated as detachable, not as
        // fixed: fail closed, so a lookup failure cannot open the door to an
        // unbarriered write.
        //
        let mediaClass = MediaTraits.classify(bsdName: device.bsdName)
        var inhibitedForRemovableMedia = false
        if mediaClass.requiresBarrier {
            let markerPresent = RemovableWritePolicy.directoryFromInsideTheSandbox()
                .map { RemovableWritePolicy.isEnabled(in: $0) } ?? false
            var barrierConfirmed = false
            if !markerPresent {
                let probe = BarrierClient(bsdName: device.bsdName)
                barrierConfirmed = (probe?.barrier() ?? EIO) == 0
                probe?.release()
            }
            inhibitedForRemovableMedia = RemovableWritePolicy.inhibitsWrites(
                requiresBarrier: true,
                markerPresent: markerPresent,
                barrierConfirmed: barrierConfirmed)

            let how = markerPresent ? "writes forced by the marker file, barrier or not"
                    : barrierConfirmed ? "write barrier confirmed, mounting read-write"
                    : "no write barrier, mounting read-only"
            Ext4Log.info("\(device.bsdName) needs a barrier (\(mediaClass)); \(how)")
        }

        let mediaWritable = device.isWritable && !inhibitedForRemovableMedia
        let readOnly = !mediaWritable

        guard let bridge = BlockDeviceBridge(resource: device, forceReadOnly: readOnly),
              var dev = bridge.device else {
            throw Ext4Error.ioError
        }

        // An encrypted container is recognised here rather than by the
        // filesystem probe, which would only see ciphertext.
        if try Ext4LUKSKeys.openEncryptedIfNeeded(bridge) {
            guard let decrypted = bridge.device else { throw Ext4Error.ioError }
            dev = decrypted
        }

        var info = ext4b_probe_info()
        try Ext4Error.check(ext4b_probe(dev, &info), "probe")

        // A volume the probe only rates usable-but-limited must never be
        // written, whatever the media allows.
        let effectiveReadOnly = readOnly || info.verdict == EXT4B_PROBE_READ_ONLY

        guard info.verdict == EXT4B_PROBE_USABLE || info.verdict == EXT4B_PROBE_READ_ONLY else {
            // Not a refusal -- a load is not a mount. fskitd loads a resource
            // before it will format or check it, so media with no filesystem
            // on it (the thing newfs exists to fix) must load successfully.
            // The shell volume this returns can be formatted and checked but
            // fails activation, which is where an actual mount of
            // unrecognised media now gets the ENOTSUP the load used to give.
            bridge.close()
            Ext4Log.info("no mountable filesystem (\(Self.reason(info))); "
                         + "loaded for maintenance only")
            containerStatus = FSContainerStatus.ready
            return Ext4UnformattedVolume(bsdName: device.bsdName)
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
        state.withLock {
            $0.bridge = bridge
            $0.volume = volume
        }

        // FSKit tracks a container state machine and rejects the load with
        // EAGAIN ("unexpected container state") if the resource is still
        // NotReady when loadResource returns. Ready means "loaded, volume
        // available"; activate() moves it on to Active.
        containerStatus = FSContainerStatus.ready

        Ext4Log.info("mounted ext\(info.generation) volume \(effectiveReadOnly ? "read-only" : "read-write")"
                     + "\(bridge.isEncrypted ? " (encrypted)" : ""), "
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
        // Take ownership under the lock: whichever caller wins nils the state
        // out in the same critical section, so the loser -- the second of
        // unmount and deactivate, which both fire on a normal umount -- takes
        // (nil, nil) and returns. The unmount and close then happen on a
        // bridge nobody else can still reach, so there is no double free and
        // no double ext4b_unmount. The lock is released before the await.
        let taken: BlockDeviceBridge? = state.withLock {
            let b = $0.bridge
            $0.bridge = nil
            $0.volume = nil
            return b
        }
        guard let bridge = taken, let dev = bridge.device else { return }
        // Carried across the concurrency boundary as an integer: OpaquePointer
        // is not Sendable, and the executor guarantees serial access anyway.
        let handle = UInt(bitPattern: dev)
        try? await executor.run {
            _ = ext4b_unmount(OpaquePointer(bitPattern: handle))
        }
        bridge.close()
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
