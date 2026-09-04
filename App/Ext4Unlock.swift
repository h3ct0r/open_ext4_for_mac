//
//  Ext4Unlock.swift — unlocking an encrypted volume from the container app
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  The expensive, interactive half of LUKS belongs here rather than in the
//  extension. This process can ask for a passphrase; a sandboxed FSKit module
//  cannot. It can also afford the gigabyte argon2id wants, and it pays for it
//  once -- FSKit loads a resource twice per mount, in two separate extension
//  processes, so deriving there costs the derivation twice over.
//
//  What crosses over is only the master key, in the keychain. The passphrase
//  never leaves this process.
//

import Foundation
import Ext4Core

/// A block device or image file, read through a plain file descriptor.
///
/// The C core asks for byte ranges through a function pointer and does not
/// care what is underneath, which is what lets the same LUKS code serve the
/// extension, the test tool, and this.
final class RawDevice {
    private let fd: Int32

    /// Every read is widened to this before it reaches the descriptor.
    ///
    /// A block device will not serve an unaligned read, and a LUKS header is
    /// full of them -- the very first thing read is a 6-byte magic. Widening
    /// here rather than teaching the header parser about alignment keeps the
    /// same parser serving files, block devices and FSKit resources alike.
    private static let alignment = 4096

    init?(path: String) {
        // Read-only. Unlocking only ever reads the header, and nothing in this
        // process should be able to write to a volume.
        let descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else { return nil }
        fd = descriptor
    }

    deinit { close(fd) }

    var context: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    fileprivate func read(into buffer: UnsafeMutableRawPointer,
                          offset: UInt64, count: Int) -> Int32 {
        let unit = UInt64(Self.alignment)
        let start = (offset / unit) * unit
        let shift = Int(offset - start)
        let span = ((shift + count + Self.alignment - 1) / Self.alignment) * Self.alignment

        var scratch = [UInt8](repeating: 0, count: span)
        let got: Int = scratch.withUnsafeMutableBytes { raw -> Int in
            var done = 0
            while done < span {
                let n = pread(fd, raw.baseAddress! + done, span - done, off_t(start) + off_t(done))
                if n <= 0 { break }   // a short read at the end of the medium
                done += n
            }
            return done
        }
        guard got >= shift + count else { return EIO }

        scratch.withUnsafeBytes { raw in
            buffer.copyMemory(from: raw.baseAddress! + shift, byteCount: count)
        }
        return 0
    }
}

let rawDeviceRead: @convention(c) (UnsafeMutableRawPointer?,
                                   UnsafeMutableRawPointer?,
                                   UInt64, Int) -> Int32 = { ctx, buf, offset, count in
    guard let ctx, let buf else { return EIO }
    return Unmanaged<RawDevice>.fromOpaque(ctx)
        .takeUnretainedValue()
        .read(into: buf, offset: offset, count: count)
}

/// A failure with something to show the person who asked.
///
/// `Result<_, String>` will not do: Swift wants a real Error, and a bare
/// string is exactly what these failures are -- a line from `luks_strstatus`
/// or from `strerror`, already written for a human.
struct UnlockFailure: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

enum Ext4Unlock {

    /// What a container says about itself before anyone types anything.
    struct Container {
        let uuid: String
        let version: Int
        let cipher: String
        let sectorSize: Int
    }

    /// Where a key ended up. Worth reporting: one of these is encrypted at
    /// rest and the other is a file the user could read.
    enum Stored {
        case keychain
        case containerFile(URL)
    }

    // MARK: - Where the header comes from

    /// The bytes to read a LUKS header out of.
    ///
    /// Preferably the device itself. But a physical disk's node is
    /// `root:operator` and the person at the keyboard is not in that group, so
    /// on real media this process -- the only one that can ask for a
    /// passphrase -- cannot open it at all. The extension can, and leaves a
    /// copy of the header in its container for exactly this. See
    /// `LUKSKeyStore.write(header:)`.
    static func headerSource(devicePath: String) -> String? {
        if access(devicePath, R_OK) == 0 { return devicePath }

        let directory = LUKSKeyStore.directoryFromOutside()
        let bsd = devicePath.hasPrefix("/dev/") ? String(devicePath.dropFirst(5)) : devicePath

        // Ask DiskArbitration which container this is. That works whenever the
        // volume is one macOS has routed to us.
        if let uuid = Ext4Mount.volumeUUID(bsdName: bsd) {
            let exported = LUKSKeyStore.headerURL(uuid: uuid, in: directory)
            if FileManager.default.isReadableFile(atPath: exported.path) {
                return exported.path
            }
        }

        // It does not always know. A partition typed Linux LUKS is reported as
        // having no filesystem at all and no volume UUID, because the module
        // never claimed it -- FSKit does not offer us that partition type. The
        // header is still sitting there, exported by the probe that ran when
        // the mount was attempted by name, so fall back to it when there is
        // exactly one and therefore no ambiguity about which volume it is.
        let headers = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasSuffix(".header") }
        if headers.count == 1 {
            return directory.appendingPathComponent(headers[0]).path
        }
        return nil
    }

    // MARK: - The two steps, usable from anywhere

    /// Read a container's header. No passphrase, no side effects.
    static func inspect(devicePath: String) -> Result<Container, UnlockFailure> {
        guard let source = headerSource(devicePath: devicePath) else {
            return .failure(UnlockFailure(
                "cannot read \(devicePath), and no header has been left for it.\n"
                + "plug the volume in once so the extension can export one"))
        }
        guard let device = RawDevice(path: source) else {
            var message = "cannot open \(devicePath): \(String(cString: strerror(errno)))"
            if errno == EACCES || errno == EPERM {
                message += "\nthe device node is not readable by this user"
            }
            return .failure(UnlockFailure(message))
        }
        var info = luks_info()
        let probe = luks_probe(device.context, rawDeviceRead, &info)
        guard probe == LUKS_OK else {
            let why = text(info.unsupported)
            return .failure(UnlockFailure(String(cString: luks_strstatus(probe))
                                          + (why.isEmpty ? "" : ": " + why)))
        }
        return .success(Container(uuid: text(info.uuid),
                                  version: Int(info.version),
                                  cipher: "\(text(info.cipher))-\(text(info.mode))",
                                  sectorSize: Int(info.sector_size)))
    }

    /// Turn a passphrase into the master key and leave it where the extension
    /// will look. The passphrase is zeroed here; the key never leaves.
    ///
    /// The keychain when we can reach it, the extension's container when we
    /// cannot -- claiming the keychain group needs a provisioning profile for
    /// this app's bundle ID, and a binary signed without one simply fails the
    /// call rather than being killed for it.
    /// Preferred entry point: the passphrase never leaves a wipe-on-deinit
    /// buffer, so there is no copy-on-write alias to leak it (see SecureBytes).
    static func store(passphrase: SecureBytes, devicePath: String) -> Result<(Container, Stored), UnlockFailure> {
        passphrase.withUnsafeBytes { raw in
            store(passphrase: raw, devicePath: devicePath)
        }
    }

    static func store(passphrase: UnsafeBufferPointer<UInt8>, devicePath: String) -> Result<(Container, Stored), UnlockFailure> {
        storeCore(passphrase: passphrase, devicePath: devicePath)
    }

    static func store(passphrase: [UInt8], devicePath: String) -> Result<(Container, Stored), UnlockFailure> {
        passphrase.withUnsafeBufferPointer { storeCore(passphrase: $0, devicePath: devicePath) }
    }

    private static func storeCore(passphrase: UnsafeBufferPointer<UInt8>, devicePath: String) -> Result<(Container, Stored), UnlockFailure> {
        guard let source = headerSource(devicePath: devicePath),
              let device = RawDevice(path: source) else {
            return .failure(UnlockFailure("cannot read a LUKS header for \(devicePath)"))
        }
        var info = luks_info()
        guard luks_probe(device.context, rawDeviceRead, &info) == LUKS_OK else {
            return .failure(UnlockFailure("\(devicePath) is not a LUKS container we can read"))
        }
        let uuid = text(info.uuid)

        var key = [UInt8](repeating: 0, count: Int(LUKS_MAX_MASTER_KEY))
        var length = 0
        let status = key.withUnsafeMutableBufferPointer { out in
            luks_unlock(device.context, rawDeviceRead, &info,
                        passphrase.baseAddress, passphrase.count,
                        out.baseAddress, &length)
        }
        defer { zero(&key) }
        guard status == LUKS_OK, length > 0 else {
            return .failure(UnlockFailure(String(cString: luks_strstatus(status))))
        }

        var master = Array(key[0..<length])
        defer { zero(&master) }

        let container = Container(uuid: uuid, version: Int(info.version),
                                  cipher: "\(text(info.cipher))-\(text(info.mode))",
                                  sectorSize: Int(info.sector_size))
        // The exported header exists only to get us here.
        try? FileManager.default.removeItem(
            at: LUKSKeyStore.headerURL(uuid: uuid, in: LUKSKeyStore.directoryFromOutside()))

        do {
            try LUKSKeychain.store(masterKey: master, uuid: uuid,
                                   label: "ext4 volume \(uuid)")
            return .success((container, .keychain))
        } catch {
            let directory = LUKSKeyStore.directoryFromOutside()
            do {
                try LUKSKeyStore.write(masterKey: master, uuid: uuid, in: directory)
                return .success((container, .containerFile(directory)))
            } catch {
                return .failure(UnlockFailure("could not store the key: \(error)"))
            }
        }
    }

    /// Whether a key is already waiting for this container.
    static func isUnlocked(uuid: String) -> Bool {
        // Existence only -- do not pull the master key into memory to answer a
        // boolean that runs on every menu rebuild.
        if LUKSKeychain.hasKey(uuid: uuid) { return true }
        return LUKSKeyStore.material(uuid: uuid,
                                     in: LUKSKeyStore.directoryFromOutside()) != nil
    }

    /// What forgetting one container's key actually did, in both places.
    struct ForgetResult {
        var keychain: LUKSKeychain.Removal?
        var keychainError: String?
        var filesRemoved: [String] = []

        /// Did anything actually go away?
        var removedSomething: Bool {
            keychain == .deleted || !filesRemoved.isEmpty
        }
        /// Is anything still there that we tried to remove?
        var stillThere: Bool { keychain == .stillPresent }
    }

    /// Forget a container's key, wherever it is, and report what happened.
    ///
    /// Both places, always: which one holds the key depends on how this binary
    /// was signed, and forgetting half of it is worse than useless.
    ///
    /// No `try?` here any more. It used to swallow every keychain error and
    /// the caller printed "forgot the key for <uuid>" regardless -- so a build
    /// that could not see the item, which is any build signed differently from
    /// the one that stored it, reported success over a key that was still
    /// there. That is the worst possible failure for this particular verb.
    static func forget(uuid: String,
                       in directory: URL = LUKSKeyStore.directoryFromOutside(),
                       includeKeychain: Bool = true) -> ForgetResult {
        var result = ForgetResult()
        if includeKeychain {
            do {
                result.keychain = try LUKSKeychain.remove(uuid: uuid)
            } catch {
                result.keychainError = error.localizedDescription
            }
        }

        for suffix in ["key", "pass", "header"] {
            let url = directory.appendingPathComponent("\(uuid).\(suffix)")
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
                if !FileManager.default.fileExists(atPath: url.path) {
                    result.filesRemoved.append("\(uuid).\(suffix)")
                }
            }
        }
        return result
    }

    // MARK: - Commands

    /// Read a container's header, ask for the passphrase, derive the master
    /// key, and leave it where the extension will find it.
    static func unlock(devicePath: String) -> Int32 {
        let container: Container
        switch inspect(devicePath: devicePath) {
        case .success(let c): container = c
        case .failure(let why):
            for line in why.message.split(separator: "\n") { complain(String(line)) }
            return 1
        }

        print("LUKS\(container.version) container \(container.uuid)")
        print("  cipher   \(container.cipher)")
        print("  sectors  \(container.sectorSize) bytes")
        print("")

        guard var passphrase = askPassphrase("Passphrase for \(container.uuid): ") else {
            complain("no passphrase given")
            return 1
        }
        defer { zero(&passphrase) }

        print("deriving the master key…", terminator: "")
        fflush(stdout)
        let result = store(passphrase: passphrase, devicePath: devicePath)
        print("")

        switch result {
        case .failure(let why):
            complain(why.message)
            return 1

        case .success(let (c, .keychain)):
            print("unlocked. The master key is in the keychain.")
            print("")
            print("The volume will mount until the key is forgotten:")
            print("    Ext4Mac forget \(c.uuid)")
            return 0

        case .success(let (c, .containerFile(directory))):
            print("unlocked. The master key is in the extension's container:")
            print("    \(directory.path)/\(c.uuid).key")
            print("")
            print("That file is readable by you and is not encrypted at rest.")
            print("Put App/Ext4Mac.provisionprofile in place and reinstall to")
            print("use the keychain instead; see docs/SIGNING.md.")
            print("")
            print("The volume will mount until the key is forgotten:")
            print("    Ext4Mac forget \(c.uuid)")
            return 0
        }
    }

    /// Drop a stored key. Takes a UUID, a device to read one from, or --all.
    static func forget(_ argument: String) -> Int32 {
        if argument == "--all" { return forgetAll(confirmed: false) }
        let uuid = argument.hasPrefix("/dev/") ? containerUUID(devicePath: argument) : argument
        guard let uuid else { return 1 }
        return report(uuid: uuid, forget(uuid: uuid))
    }

    /// Say what happened, in the words of what happened.
    private static func report(uuid: String, _ r: ForgetResult) -> Int32 {
        if let error = r.keychainError {
            complain("the keychain refused to forget \(uuid): \(error)")
            return 1
        }
        switch r.keychain {
        case .deleted:
            print("forgot the keychain key for \(uuid)")
        case .stillPresent:
            complain("the keychain key for \(uuid) is STILL THERE after deleting it")
            return 1
        case .notVisible, nil:
            // Deliberately not "forgot": this build can see no such item, and
            // the keychain cannot tell "there was never one" from "there is
            // one and you are not the code that stored it". Saying which of
            // those it is would be inventing the answer.
            if r.filesRemoved.isEmpty {
                print("no key for \(uuid) is visible to this build")
                print("")
                print("If one was stored by the installed app, forget it with that:")
                print("    /Applications/Ext4Mac.app/Contents/MacOS/Ext4Mac forget \(uuid)")
                return 1
            }
        }
        for file in r.filesRemoved { print("removed \(file)") }
        return 0
    }

    /// Forget everything this build can see: every key in the keychain and
    /// every file in the extension's container.
    ///
    /// Exists because they accumulate. A test that unlocks a fixture container
    /// leaves a key behind, and after a few weeks of suites there are dozens
    /// of them -- each one a master key for a volume that no longer exists,
    /// sitting in the login keychain because nothing ever swept up.
    static func forgetAll(confirmed: Bool,
                          in directory: URL = LUKSKeyStore.directoryFromOutside(),
                          includeKeychain: Bool = true) -> Int32 {
        var uuids = Set<String>()
        if includeKeychain {
            do {
                uuids.formUnion(try LUKSKeychain.storedUUIDs())
            } catch {
                complain("could not list keychain items: \(error.localizedDescription)")
                return 1
            }
        }
        for file in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] {
            guard file.hasSuffix(".key") || file.hasSuffix(".pass") || file.hasSuffix(".header")
            else { continue }
            uuids.insert((file as NSString).deletingPathExtension)
        }

        if uuids.isEmpty {
            print("nothing stored; nothing to forget")
            return 0
        }

        // Say what will go, and do nothing until somebody says yes.
        //
        // This verb deletes every key this build can see, and the two halves
        // fail independently: a build that cannot touch the keychain can still
        // delete every file in the container, which is what happened the first
        // time this was run -- nine key files gone while every keychain item
        // stayed, and the summary said "forgot 0 of 9". Deleting first and
        // reporting afterwards is the wrong order for a verb like this.
        //
        // No isatty. A confirmation that depends on where stdout points is a
        // confirmation that behaves differently under a script than under a
        // person, and this is exactly the verb where those must agree.
        if !confirmed {
            print("would forget \(uuids.count) key(s):")
            for uuid in uuids.sorted() { print("  \(uuid)") }
            print("")
            print("This deletes key material. A volume whose key is forgotten needs its")
            print("passphrase again, and there is nothing to undo it with.")
            print("")
            print("    Ext4Mac forget --all --yes")
            return 2
        }

        var failures = 0
        var deleted = 0
        var unseen = 0
        for uuid in uuids.sorted() {
            let r = forget(uuid: uuid, in: directory, includeKeychain: includeKeychain)
            // The two halves fail independently, so report both. "NOT
            // forgotten" over a run that deleted three files is a lie in the
            // safe-sounding direction, which is the worse one.
            let files = r.filesRemoved.isEmpty
                      ? "" : " (removed \(r.filesRemoved.joined(separator: ", ")))"
            if r.keychainError != nil || r.stillThere {
                complain("  \(uuid): keychain NOT forgotten"
                         + (r.keychainError.map { " (\($0))" } ?? "")
                         + files)
                failures += 1
            } else if r.keychain == .deleted {
                print("  \(uuid): forgotten\(files)")
                deleted += 1
            } else if includeKeychain && r.filesRemoved.isEmpty {
                // Nothing removed and no keychain item this build can see.
                // Not "forgotten": the keychain cannot tell "never stored"
                // from "stored by a build this one cannot see".
                print("  \(uuid): no keychain item visible to this build")
                unseen += 1
            } else if includeKeychain {
                // The container files went; the keychain saw nothing. That is
                // exactly what the single-UUID path reports as success with
                // the files listed -- on a build without the provisioning
                // profile, the container IS where the keys live -- so this
                // agrees with it rather than exiting 1 over a job it did.
                print("  \(uuid): forgot the container files\(files); no keychain item visible")
                deleted += 1
            } else if r.removedSomething {
                print("  \(uuid): forgotten\(files)")
                deleted += 1
            } else {
                print("  \(uuid): nothing visible to remove")
            }
        }
        print("")
        print("forgot \(deleted) of \(uuids.count)")
        if unseen > 0 {
            complain("\(unseen) had no keychain item visible to this build; if the"
                     + " installed app stored them, forget them with that:")
            complain("    /Applications/Ext4Mac.app/Contents/MacOS/Ext4Mac forget --all --yes")
        }

        // Ask again rather than trusting the loop: this verb exists because
        // the old one reported success without checking.
        let left = includeKeychain ? ((try? LUKSKeychain.storedUUIDs()) ?? []) : []
        if !left.isEmpty {
            complain("\(left.count) keychain item(s) remain: \(left.joined(separator: ", "))")
            return 1
        }
        return (failures == 0 && unseen == 0) ? 0 : 1
    }

    /// Which volumes we hold keys for. Never prints key material.
    static func list() -> Int32 {
        var rows: [(String, String)] = []
        if let uuids = try? LUKSKeychain.storedUUIDs() {
            rows += uuids.map { ($0, "keychain") }
        }
        let directory = LUKSKeyStore.directoryFromOutside()
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for file in files.sorted() {
            let uuid = (file as NSString).deletingPathExtension
            let kind = file.hasSuffix(".key") ? "container file" : "container passphrase"
            if file.hasSuffix(".key") || file.hasSuffix(".pass") { rows.append((uuid, kind)) }
        }

        if rows.isEmpty {
            print("no unlocked volumes")
        } else {
            print("keys are stored for:")
            for (uuid, where_) in rows { print("  \(uuid)   (\(where_))") }
        }
        return 0
    }

    // MARK: - Helpers

    private static func containerUUID(devicePath: String) -> String? {
        switch inspect(devicePath: devicePath) {
        case .success(let c): return c.uuid
        case .failure(let why): complain(why.message); return nil
        }
    }

    /// Read a line from the terminal with echo off.
    ///
    /// The terminal state is restored even if the read fails, so a mistyped
    /// passphrase cannot leave the shell with echo disabled.
    private static func askPassphrase(_ prompt: String) -> [UInt8]? {
        guard isatty(STDIN_FILENO) == 1 else {
            // Not a terminal: read a line, so this works from a script
            // without a passphrase ever appearing in the process list.
            guard let line = readLine(strippingNewline: true), !line.isEmpty else { return nil }
            return [UInt8](line.utf8)
        }

        var saved = termios()
        guard tcgetattr(STDIN_FILENO, &saved) == 0 else { return nil }
        var quiet = saved
        quiet.c_lflag &= ~UInt(ECHO)
        guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &quiet) == 0 else { return nil }
        defer {
            var restore = saved
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &restore)
            print("")
        }

        FileHandle.standardError.write(prompt.data(using: .utf8)!)
        guard let line = readLine(strippingNewline: true), !line.isEmpty else { return nil }
        return [UInt8](line.utf8)
    }

    static func zero(_ bytes: inout [UInt8]) {
        bytes.resetBytes(in: 0..<bytes.count)
    }

    private static func complain(_ message: String) {
        FileHandle.standardError.write(("Ext4Mac: " + message + "\n").data(using: .utf8)!)
    }

    /// A fixed-size C char array out of `luks_info`, as a Swift string.
    static func text<T>(_ field: T) -> String {
        var value = field
        return withUnsafeBytes(of: &value) { raw -> String in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
