//
//  Ext4SampleVolume.swift — mounting the volume that ships inside the app
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  The last thing a first run should do is claim to work. This mounts the
//  sample ext4 volume from Contents/Resources through the same path a
//  plugged-in disk takes -- attach the device, let DiskArbitration probe it,
//  let FSKit hand it to our extension -- so that what the user sees in the
//  Finder is the real driver on a real volume, not a picture of one.
//
//  Two rules it does not bend.
//
//  The image is attached READ-WRITE. A read-only resource makes the extension
//  record degradedReadOnly and raise a notification, which is a bug report
//  arriving in the middle of a demonstration.
//
//  Nothing is left attached. The detach is retried, because the extension does
//  not always release the device the instant the unmount returns -- the same
//  race scripts/check_extension.sh has retried since a PROBE device was found
//  still attached days later. If it still will not go, the backing file is
//  KEPT and the command to run is printed: a leak that announces itself can be
//  cleaned up, a silent one accumulates.
//

import Foundation
import AppKit
import os

enum Ext4SampleVolume {
    private static let log = Logger(subsystem: "dev.h3ct0r.ext4", category: "sample")

    /// An attached sample, and everything needed to take it away again.
    struct Handle {
        let device: String        // /dev/diskN
        let mountPoint: URL
        let workDirectory: URL
    }

    enum Failure: Error {
        case notApproved
        case imageMissing
        case copyFailed(String)
        case attachFailed(String)
        case notMounted(String)
        case cancelled
    }

    /// Where it is in the run, for a progress line that says something true.
    enum Phase: String {
        case copying = "Copying the sample volume…"
        case attaching = "Attaching the image…"
        case waiting = "Waiting for macOS to mount it…"
        case mounted = "Mounted"
    }

    // Every device this process has attached and not yet detached. Read at
    // quit, so a closed window or a crash-free exit never leaves one behind.
    private static let lock = NSLock()
    private static var live: [Handle] = []

    static var attachedDevices: [String] {
        lock.lock(); defer { lock.unlock() }
        return live.map(\.device)
    }

    // MARK: - mounting

    static func mount(reveal: Bool = false,
                      progress: @Sendable (Phase) -> Void = { _ in }) async -> Result<Handle, Failure> {
        // Preflight, in the order a person would ask. An unapproved extension
        // is not a mount failure; it is the step before this one.
        guard await Ext4Setup.extensionState().enabled else { return .failure(.notApproved) }
        guard let imagePath = SetupSample.imagePath else { return .failure(.imageMissing) }

        // A fresh copy each time, for two reasons. Writes the user makes
        // during the demonstration must not accumulate inside the signed app
        // bundle -- they cannot: it is read-only and sealed -- and a file
        // DiskArbitration has never seen carries none of its cached verdicts
        // about a device it refused earlier.
        progress(.copying)
        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ext4mac-sample-\(getpid())-\(UUID().uuidString)",
                                    isDirectory: true)
        let copy = work.appendingPathComponent("Ext4Mac-Sample.img")
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: imagePath), to: copy)
        } catch {
            return .failure(.copyFailed(error.localizedDescription))
        }

        progress(.attaching)
        // -nomount, then let DiskArbitration do the mounting on its own, which
        // is the path a real disk takes. CRawDiskImage because the file is a
        // plain filesystem image with no partition map and no UDIF wrapper.
        let attach = Shell.run("/usr/bin/hdiutil",
                               ["attach", "-imagekey", "diskimage-class=CRawDiskImage",
                                "-nomount", copy.path],
                               deadline: 30)
        guard attach.status == 0,
              let device = attach.stdout
                  .split(separator: "\n").first(where: { $0.hasPrefix("/dev/disk") })
                  .map({ $0.split(separator: " ")[0] }).map(String.init) else {
            try? FileManager.default.removeItem(at: work)
            let why = attach.stderr.isEmpty ? attach.stdout : attach.stderr
            return .failure(.attachFailed(why.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        // Registered before anything else can fail. A device recorded and not
        // used is harmless; a device used and not recorded is the leak.
        var handle = Handle(device: device, mountPoint: URL(fileURLWithPath: "/"),
                            workDirectory: work)
        lock.lock(); live.append(handle); lock.unlock()
        log.info("attached \(device, privacy: .public) for the sample volume")

        progress(.waiting)
        // The automount, then a direct ask. DiskArbitration mounts a disk it
        // recognises within a second or two; when it has already decided
        // otherwise, Ext4Mount says why in the words the rest of the app maps
        // to advice.
        var mountPoint = await waitForMount(device: device, seconds: 8)
        if mountPoint == nil {
            let bsd = String(device.dropFirst("/dev/".count))
            switch Ext4Mount.mount(bsdName: bsd, timeout: 30) {
            case .mounted:
                mountPoint = await waitForMount(device: device, seconds: 5)
            case .refused(let why):
                await detach(handle)
                return .failure(.notMounted(why))
            case .noSuchDisk:
                await detach(handle)
                return .failure(.notMounted("the device disappeared before it could be mounted"))
            }
        }
        guard let mountPoint else {
            await detach(handle)
            return .failure(.notMounted("macOS attached the image but never mounted the volume"))
        }

        handle = Handle(device: device, mountPoint: mountPoint, workDirectory: work)
        lock.lock()
        live.removeAll { $0.device == device }
        live.append(handle)
        lock.unlock()
        progress(.mounted)

        if reveal {
            let readme = mountPoint.appendingPathComponent("README.txt")
            await MainActor.run {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [FileManager.default.fileExists(atPath: readme.path) ? readme : mountPoint])
            }
        }
        return .success(handle)
    }

    /// Where `diskutil` says the device is mounted, once it says anything.
    /// Asked of the device rather than looked up by volume name, so a second
    /// disk that happens to be called the same thing cannot be mistaken for
    /// this one.
    private static func waitForMount(device: String, seconds: Int) async -> URL? {
        for _ in 0..<(seconds * 4) {
            if let point = mountPoint(of: device) { return point }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return mountPoint(of: device)
    }

    private static func mountPoint(of device: String) -> URL? {
        let info = Shell.run("/usr/sbin/diskutil", ["info", "-plist", device], deadline: 10)
        guard info.status == 0,
              let data = info.stdout.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(
                    from: data, options: [], format: nil) as? [String: Any],
              let path = plist["MountPoint"] as? String, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    // MARK: - taking it away again

    /// Eject and detach, retrying the detach. Returns nil on success, or the
    /// line to show the user when the device is still there.
    @discardableResult
    static func detach(_ handle: Handle) async -> String? {
        func gone() -> Bool { !FileManager.default.fileExists(atPath: handle.device) }
        func succeed() -> String? {
            lock.lock(); live.removeAll { $0.device == handle.device }; lock.unlock()
            try? FileManager.default.removeItem(at: handle.workDirectory)
            log.info("detached \(handle.device, privacy: .public)")
            return nil
        }

        // Ejecting a disk image detaches it as well: the device node is gone
        // before hdiutil is ever asked. Measured -- the first version reported
        // a leak on a run that had left nothing behind, because it read
        // hdiutil's "no such device" as a failure to detach.
        _ = Shell.run("/usr/sbin/diskutil", ["eject", handle.device], deadline: 20)
        if gone() { return succeed() }
        for attempt in 0..<5 {
            let out = Shell.run("/usr/bin/hdiutil", ["detach", handle.device, "-force"], deadline: 20)
            if out.status == 0 || gone() { return succeed() }
            if attempt < 4 { try? await Task.sleep(nanoseconds: 1_000_000_000) }
        }
        // Deliberately keeps the backing file: an attached device pointing at
        // a file that no longer exists shows up in `diskutil list` forever and
        // can only be cleared by hand.
        log.error("could not detach \(handle.device, privacy: .public)")
        return "\(handle.device) is still attached. Run: hdiutil detach \(handle.device) -force"
    }

    /// Everything this process still has attached. Called when the app quits
    /// and when the wizard's window closes.
    static func detachAll() async {
        lock.lock(); let all = live; lock.unlock()
        for handle in all { _ = await detach(handle) }
    }

    // MARK: - what to tell the user

    static func advice(for failure: Failure) -> String {
        switch failure {
        case .notApproved:
            return "The file system extension is not approved yet, so nothing can mount an ext4 volume. Go back to the approval step."
        case .imageMissing:
            return "This build of Ext4Mac does not carry the sample volume, so there is nothing to mount. Plugging in a real ext4 disk still works."
        case .copyFailed(let why):
            return "The sample volume could not be copied out of the app: \(why)"
        case .attachFailed(let why):
            return "macOS would not attach the sample image: \(why)"
        case .notMounted(let why):
            return """
                The image was attached but the volume did not mount: \(why)

                This is usually DiskArbitration holding an earlier verdict about \
                the device. Unplug and replug any ext drive, or restart the Mac, \
                and try again. `Ext4Mac last-error` says what the extension \
                itself reported.
                """
        case .cancelled:
            return "Stopped before the volume was mounted."
        }
    }
}

/// One place that runs a command and waits with a deadline, because every
/// caller here would otherwise write the same twenty lines and one of them
/// would forget the deadline.
enum Shell {
    struct Output { let status: Int32; let stdout: String; let stderr: String }

    static func run(_ path: String, _ arguments: [String], deadline: TimeInterval) -> Output {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        let out = Pipe(), err = Pipe()
        task.standardOutput = out
        task.standardError = err
        do { try task.run() } catch {
            return Output(status: -1, stdout: "", stderr: error.localizedDescription)
        }
        // Read before waiting: a command that fills the pipe buffer while we
        // wait for it to exit would deadlock against us.
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()

        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { task.waitUntilExit(); done.signal() }
        if done.wait(timeout: .now() + deadline) == .timedOut {
            task.terminate()
            _ = done.wait(timeout: .now() + 5)
            return Output(status: -1,
                          stdout: String(decoding: outData, as: UTF8.self),
                          stderr: "timed out after \(Int(deadline)) s")
        }
        return Output(status: task.terminationStatus,
                      stdout: String(decoding: outData, as: UTF8.self),
                      stderr: String(decoding: errData, as: UTF8.self))
    }
}
