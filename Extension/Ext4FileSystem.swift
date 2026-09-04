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
        Ext4Log.forgetCoreLines()

        let result = examine(device)
        if result.result == .notRecognized {
            // The resource arrives with the device open, and the descriptor
            // lives as long as the object does. Keeping a declined one in
            // `lastSeen` kept the device open for as long as fskitd kept
            // this idle process around -- minutes -- and a disk this driver
            // had refused to touch then failed to eject with "Resource
            // busy", until the next probe of anything replaced it. (Measured
            // with lsof: the descriptor went away with the reference, and
            // `revoke()` on its own freed nothing.) Nothing here needs a
            // declined resource again: a format or check arrives after a
            // load, which presents a resource of its own.
            state.withLock {
                if $0.lastSeen === device { $0.lastSeen = nil }
            }
        }
        return result
    }

    /// The probe proper: what is on this device, and will we touch it.
    private func examine(_ device: FSBlockDeviceResource) -> FSProbeResult {
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
            Self.report(.refused, device: device.bsdName, info: info, reason: Self.reason(info))
            return .notRecognized

        case EXT4B_PROBE_READ_ONLY:
            Ext4Log.info("volume usable read-only: \(Self.reason(info))")
            Self.report(.degradedReadOnly, device: device.bsdName, info: info,
                        reason: Self.reason(info))
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
            report(.refused, device: bridge.resource.bsdName, luks: info,
                   reason: Ext4LUKS.reason(info))
            return .notRecognized
        }
        guard let container = Ext4LUKS.containerID(info) else {
            Ext4Log.info("declining LUKS volume: unreadable UUID")
            report(.refused, device: bridge.resource.bsdName, luks: info,
                   reason: "LUKS\(info.version) container with an unreadable UUID")
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
            report(.keyRejected, device: bridge.resource.bsdName, luks: info,
                   reason: "a stored key no longer opens this container")
        } catch let e as NSError where e.domain == NSPOSIXErrorDomain && e.code == Int(ENEEDAUTH) {
            // Locked: no key anywhere. Not a fault, but it is the volume
            // that most looks like a broken disk from the outside.
            report(.locked, device: bridge.resource.bsdName, luks: info,
                   reason: "no key is stored for this container")
        } catch {
            // Anything else -- the cipher stack would not open, the key
            // store was unreadable -- still presents as locked so the user
            // can act, but it is not silent any more: this catch used to be
            // empty, and an EIO from the key path read as "locked" forever.
            Ext4Log.error("LUKS\(info.version) container could not be opened: \(error)")
            report(.locked, device: bridge.resource.bsdName, luks: info,
                   reason: "the container could not be opened: \(Self.describe(error))")
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
                    report(.refused, device: bridge.resource.bsdName, info: inner,
                           uuid: Ext4LUKSKeys.uuidString(info), reason: reason(inner))
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
                Self.report(.mountFailed, device: device.bsdName,
                            reason: "this extension process already has \(existing) mounted")
                throw Ext4Error.posix(EBUSY)
            }
        }

        state.withLock {
            $0.lastSeen = device
            $0.probedBSDNames.insert(device.bsdName)
        }
        Ext4Log.forgetCoreLines()

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
        // Removable media gets the same contract, and that is a measured
        // decision, twice over. The read-only-unless-barriered policy that
        // used to live here (behind a privileged helper daemon issuing
        // DKIOCSYNCHRONIZE) guarded against a corruption measured on the
        // driver's earliest write path; on the current direct-I/O path the
        // hazard did not survive remeasurement. Five drives -- USB-2 sticks
        // through an NVMe SSD behind a bridge chip -- took twenty mid-write
        // pulls, fenced and under sustained load, and every one recovered by
        // journal replay to a filesystem e2fsck found nothing to fix
        // (Tests/run_pull_tests.sh; results in docs/STATUS.md). The policy
        // also never covered the drives most likely to cache: anything
        // claiming fixed media on an external bus -- large sticks, USB SSDs
        // -- reported non-removable and wrote unbarriered all along.
        //
        // Eject before unplugging remains the advice, for a reason no policy
        // here could reach: a mid-write pull can panic macOS itself (an
        // IOMediaBSDClient busy timeout in the storage stack, observed once
        // during the sweep).
        //
        let mediaWritable = device.isWritable
        let readOnly = !mediaWritable

        guard let bridge = BlockDeviceBridge(resource: device, forceReadOnly: readOnly),
              var dev = bridge.device else {
            Self.report(.mountFailed, device: device.bsdName,
                        reason: "the device could not be opened")
            throw Ext4Error.ioError
        }

        // An encrypted container is recognised here rather than by the
        // filesystem probe, which would only see ciphertext.
        do {
            if try Ext4LUKSKeys.openEncryptedIfNeeded(bridge) {
                guard let decrypted = bridge.device else { throw Ext4Error.ioError }
                dev = decrypted
            }
        } catch {
            let luks = bridge.probeLUKS()?.1
            switch Self.posixCode(error) {
            case ENEEDAUTH:
                Self.report(.locked, device: device.bsdName, luks: luks,
                            reason: "no key is stored for this container")
            case EAUTH:
                Self.report(.keyRejected, device: device.bsdName, luks: luks,
                            reason: "a stored key no longer opens this container")
            default:
                Self.report(.mountFailed, device: device.bsdName, luks: luks,
                            reason: "the encrypted container could not be opened: "
                                    + Self.describe(error))
            }
            throw error
        }

        var info = ext4b_probe_info()
        do {
            try Ext4Error.check(ext4b_probe(dev, &info), "probe")
        } catch {
            Self.report(.mountFailed, device: device.bsdName,
                        reason: "the superblock could not be read: \(Self.describe(error))")
            throw error
        }

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
            if info.verdict == EXT4B_PROBE_UNSUPPORTED {
                Self.report(.refused, device: device.bsdName, info: info,
                            reason: Self.reason(info))
            } else {
                Self.report(.unformatted, device: device.bsdName,
                            reason: "nothing recognisable as ext2, ext3 or ext4 here")
            }
            containerStatus = FSContainerStatus.ready
            return Ext4UnformattedVolume(bsdName: device.bsdName)
        }

        do {
            try executor.runSync {
                // ext4b_mount replays the journal and attaches it for read-write
                // mounts; it fails rather than proceeding if either step fails.
                try Ext4Error.check(ext4b_mount(dev, effectiveReadOnly), "mount")
            }
        } catch {
            // A read-write mount of a dirty volume that would not replay is
            // its own kind: the next step is e2fsck, not a retry.
            let replay = info.needs_recovery && !effectiveReadOnly
            Self.report(replay ? .replayRefused : .mountFailed,
                        device: device.bsdName, info: info,
                        reason: replay ? "the journal could not be replayed: \(Self.describe(error))"
                                       : "the volume could not be mounted: \(Self.describe(error))")
            bridge.close()
            throw error
        }

        let volume = Ext4Volume(bridge: bridge,
                                executor: executor,
                                probe: info,
                                readOnly: effectiveReadOnly,
                                identity: IdentityMapper())
        volume.fileSystem = self
        if effectiveReadOnly {
            // Mounted, but not the way it was asked for. The reason is the
            // whole message: read-only media and a feature we will not write
            // through are different next steps -- and a dirty journal on
            // either means the files predate the last crash, which the
            // core's own line in bridge[] says. Recorded when the volume
            // activates, not here: see `readOnlyReport`.
            let why = mediaWritable ? Self.reason(info) : "the device is read-only"
            volume.readOnlyReport = (info.needs_recovery ? "\(why); its journal was not replayed" : why,
                                     Ext4Log.recentCoreLines())
        }
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
        let taken: (BlockDeviceBridge?, Ext4Volume?) = state.withLock {
            let b = $0.bridge, v = $0.volume
            $0.bridge = nil
            $0.volume = nil
            return (b, v)
        }
        guard let bridge = taken.0, let dev = bridge.device else { return }
        // Carried across the concurrency boundary as an integer: OpaquePointer
        // is not Sendable, and the executor guarantees serial access anyway.
        let handle = UInt(bitPattern: dev)

        // The result is the whole point of ext4b_unmount. It drains the
        // transaction, stops the journal and writes the superblock back, and
        // reports the FIRST failure among them -- its own comment records a
        // stick that failed its final write-back and ejected "clean". Dropping
        // it with `_ =` inside a `try?` discarded that twice over, and the line
        // below still said the volume closed.
        //
        // The teardown still runs to the end either way: a device left
        // half-registered is worse than any single failed step. What changes is
        // that the failure is now said out loud, which is the difference
        // between a user who knows to re-copy and one who does not.
        var unmountRC: Int32 = 0
        do {
            unmountRC = try await executor.run {
                ext4b_unmount(OpaquePointer(bitPattern: handle))
            }
        } catch {
            Ext4Log.error("closing the volume: unmount never ran (\(error))")
            unmountRC = -1
        }
        bridge.close()
        if unmountRC != 0 {
            Ext4Log.error("unmount failed (\(unmountRC)) while closing the "
                          + "volume: something it was asked to write may not "
                          + "have reached the medium")
            Self.report(.unmountFailed, device: bridge.resource.bsdName, info: taken.1?.probe,
                        reason: "the final write-back failed (\(Self.describe(unmountRC))): "
                                + "something the volume was asked to write may not have "
                                + "reached the medium")
        } else {
            Ext4Log.info("volume closed")
        }
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

    // MARK: - Saying what happened

    /// Which build wrote the event. The same stamp `Ext4Mac version` prints,
    /// read once: a field report that names a commit is worth several that
    /// do not.
    static let buildID: String = Bundle.main.object(forInfoDictionaryKey: "Ext4BuildID")
                                 as? String ?? "unknown"

    /// Write a VolumeEvent for the app to find. Never throws and never fails
    /// the caller: every site is already on its way to reporting a failure
    /// to FSKit, and a mount that fails differently because it could not
    /// write a note about failing is worse than one that just fails.
    ///
    /// `info` supplies the UUID, label and verdict when the probe got that
    /// far; `luks` supplies them for an encrypted container, whose identity
    /// is the container's, not the filesystem's; `uuid` overrides both.
    /// `lines` replaces the ring buffer's current contents when the caller
    /// captured the core's lines earlier than now.
    static func report(_ kind: VolumeEvent.Kind,
                       device: String,
                       info: ext4b_probe_info? = nil,
                       luks: luks_info? = nil,
                       uuid: String? = nil,
                       reason: String,
                       lines: [String]? = nil) {
        var id = uuid
        var label: String?
        var verdict: String?
        if let luks {
            id = id ?? Ext4LUKSKeys.uuidString(luks)
            label = Ext4LUKS.name(luks)
        }
        if let info, info.verdict != EXT4B_PROBE_NOT_EXT {
            id = id ?? uuidString(info)
            let text = name(info)
            label = label ?? (text.hasPrefix("ext") && text.hasSuffix(" Volume") ? nil : text)
            verdict = verdictName(info.verdict)
        }
        let event = VolumeEvent(kind: kind, device: device, uuid: id, label: label,
                                verdict: verdict, reason: reason,
                                bridge: lines ?? Ext4Log.recentCoreLines(), build: buildID)
        guard let directory = VolumeEventStore.directoryFromInsideTheSandbox() else {
            Ext4Log.error("no events directory to record \(kind.rawValue) for \(device)")
            return
        }
        if VolumeEventStore.record(event, in: directory) {
            Ext4Log.info("recorded \(kind.rawValue) for \(device): \(reason)")
        } else {
            Ext4Log.error("could not record \(kind.rawValue) for \(device) in \(directory.path)")
        }
    }

    private static func uuidString(_ info: ext4b_probe_info) -> String? {
        var raw = info.uuid
        let bytes = withUnsafeBytes(of: &raw) { Array($0) }
        guard bytes.contains(where: { $0 != 0 }) else { return nil }
        return bytes.enumerated().map { i, b in
            ([4, 6, 8, 10].contains(i) ? "-" : "") + String(format: "%02x", b)
        }.joined()
    }

    private static func verdictName(_ verdict: ext4b_probe_verdict) -> String {
        switch verdict {
        case EXT4B_PROBE_USABLE:      return "USABLE"
        case EXT4B_PROBE_READ_ONLY:   return "READ_ONLY"
        case EXT4B_PROBE_UNSUPPORTED: return "UNSUPPORTED"
        default:                      return "NOT_EXT"
        }
    }

    /// The POSIX code inside an error FSKit made, or -1.
    static func posixCode(_ error: Error) -> Int32 {
        let e = error as NSError
        return e.domain == NSPOSIXErrorDomain ? Int32(e.code) : -1
    }

    /// One sentence about an error, without the module prefix Swift's
    /// description puts on it.
    static func describe(_ error: Error) -> String {
        let code = posixCode(error)
        return code >= 0 ? describe(code) : error.localizedDescription
    }

    static func describe(_ code: Int32) -> String {
        String(cString: strerror(abs(code)))
    }
}
