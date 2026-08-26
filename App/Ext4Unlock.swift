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

enum Ext4Unlock {

    // MARK: - Commands

    /// Read a container's header, ask for the passphrase, derive the master
    /// key, and leave it where the extension will find it.
    static func unlock(devicePath: String) -> Int32 {
        guard let device = RawDevice(path: devicePath) else {
            complain("cannot open \(devicePath): \(String(cString: strerror(errno)))")
            if errno == EACCES || errno == EPERM {
                // Removable media attached by this user is normally readable;
                // a fixed disk is root:operator and is not.
                complain("  the device node is not readable by this user")
            }
            return 1
        }

        var info = luks_info()
        let probe = luks_probe(device.context, rawDeviceRead, &info)
        guard probe == LUKS_OK else {
            complain("\(devicePath): \(String(cString: luks_strstatus(probe)))")
            let why = text(info.unsupported)
            if !why.isEmpty { complain("  \(why)") }
            return 1
        }

        let uuid = text(info.uuid)
        print("LUKS\(info.version) container \(uuid)")
        print("  cipher   \(text(info.cipher))-\(text(info.mode))")
        print("  key      \(info.key_bytes * 8) bits, \(info.sector_size)-byte sectors")
        print("")

        guard var passphrase = askPassphrase("Passphrase for \(uuid): ") else {
            complain("no passphrase given")
            return 1
        }
        defer { zero(&passphrase) }

        print("deriving the master key…", terminator: "")
        fflush(stdout)

        var key = [UInt8](repeating: 0, count: Int(LUKS_MAX_MASTER_KEY))
        var length = 0
        let status = passphrase.withUnsafeBufferPointer { pass in
            key.withUnsafeMutableBufferPointer { out in
                luks_unlock(device.context, rawDeviceRead, &info,
                            pass.baseAddress, pass.count,
                            out.baseAddress, &length)
            }
        }
        print("")
        defer { zero(&key) }

        guard status == LUKS_OK, length > 0 else {
            complain("\(String(cString: luks_strstatus(status)))")
            return 1
        }

        var master = Array(key[0..<length])
        defer { zero(&master) }

        // The keychain when we can reach it, the extension's container when we
        // cannot. Claiming the keychain group needs a provisioning profile
        // issued for this app's bundle ID; without one this binary is not
        // signed for it, and the call fails rather than the app being killed.
        do {
            try LUKSKeychain.store(masterKey: master, uuid: uuid,
                                   label: "ext4 volume \(uuid)")
            print("unlocked. The master key is in the keychain.")
        } catch {
            let directory = LUKSKeyStore.directoryFromOutside()
            do {
                try LUKSKeyStore.write(masterKey: master, uuid: uuid, in: directory)
            } catch {
                complain("could not store the key: \(error)")
                return 1
            }
            print("unlocked. The master key is in the extension's container:")
            print("    \(directory.path)/\(uuid).key")
            print("")
            print("That file is readable by you and is not encrypted at rest.")
            print("Put App/Ext4Mac.provisionprofile in place and reinstall to")
            print("use the keychain instead; see docs/SIGNING.md.")
        }

        print("")
        print("The volume will mount until the key is forgotten:")
        print("    Ext4Mac forget \(uuid)")
        return 0
    }

    /// Drop a stored key. Takes a UUID, or a device to read one from.
    static func forget(_ argument: String) -> Int32 {
        let uuid = argument.hasPrefix("/dev/") ? containerUUID(devicePath: argument) : argument
        guard let uuid else { return 1 }
        // Both places, always: which one holds the key depends on how this
        // binary was signed, and forgetting half of it is worse than useless.
        try? LUKSKeychain.remove(uuid: uuid)
        LUKSKeyStore.forget(uuid: uuid, in: LUKSKeyStore.directoryFromOutside())
        print("forgot the key for \(uuid)")
        return 0
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
        guard let device = RawDevice(path: devicePath) else {
            complain("cannot open \(devicePath)")
            return nil
        }
        var info = luks_info()
        guard luks_probe(device.context, rawDeviceRead, &info) == LUKS_OK else {
            complain("\(devicePath) is not a LUKS container we can read")
            return nil
        }
        return text(info.uuid)
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

    private static func zero(_ bytes: inout [UInt8]) {
        bytes.resetBytes(in: 0..<bytes.count)
    }

    private static func complain(_ message: String) {
        FileHandle.standardError.write(("Ext4Mac: " + message + "\n").data(using: .utf8)!)
    }

    /// A fixed-size C char array out of `luks_info`, as a Swift string.
    private static func text<T>(_ field: T) -> String {
        var value = field
        return withUnsafeBytes(of: &value) { raw -> String in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
