//
//  LUKSKeyStore.swift
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  The fallback channel, for when the keychain is not available: a small
//  directory inside the FSKit extension's own sandbox container.
//
//  The extension can always read it, with no entitlement at all, which makes
//  it the only channel an automated test can use and the only one that works
//  on an unattended machine. The container app can always write it, because it
//  is not sandboxed. It is strictly worse than the keychain -- the bytes sit on
//  disk in the clear -- so it is the second choice, not the first.
//

import Foundation

/// Key material left for the extension in its own container.
///
///     …/Library/Application Support/luks/<LUKS-UUID>.key    raw master key
///     …/Library/Application Support/luks/<LUKS-UUID>.pass   a passphrase
///
/// Keyed by UUID, so a key can only ever open the volume it was left for.
///
/// A master key is preferable to a passphrase even though both are plaintext
/// on disk: it opens exactly one volume, whereas a passphrase is the sort of
/// thing people reuse. It also means the derivation happens once, in whichever
/// process could afford it, rather than on every mount.
public enum LUKSKeyStore {

    public static let extensionBundleID = "dev.h3ct0r.ext4mac.Ext4FS"

    public enum Material {
        case masterKey([UInt8])
        case passphrase([UInt8])
    }

    /// The directory as the *extension* sees it: inside its sandbox,
    /// `.applicationSupportDirectory` already is the container.
    public static func directoryFromInsideTheSandbox() -> URL? {
        guard let support = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                         in: .userDomainMask,
                                                         appropriateFor: nil,
                                                         create: false) else { return nil }
        return support.appendingPathComponent("luks", isDirectory: true)
    }

    /// The same directory as anything *outside* the sandbox sees it.
    public static func directoryFromOutside() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(extensionBundleID)/Data")
            .appendingPathComponent("Library/Application Support/luks", isDirectory: true)
    }

    /// Whatever has been left for this volume, master key preferred.
    ///
    /// Read with no trimming of any kind. `cryptsetup --key-file` does not
    /// strip a trailing newline either, so a passphrase that ends in one is a
    /// different passphrase -- quietly removing it would open some containers
    /// and not others.
    public static func material(uuid: String, in directory: URL) -> Material? {
        let key = directory.appendingPathComponent("\(uuid).key")
        if let data = try? Data(contentsOf: key), !data.isEmpty,
           data.count <= LUKSKeychain.maxKeyLength {
            return .masterKey([UInt8](data))
        }
        let pass = directory.appendingPathComponent("\(uuid).pass")
        if let data = try? Data(contentsOf: pass), !data.isEmpty {
            return .passphrase([UInt8](data))
        }
        return nil
    }

    /// Leave a master key for the extension, readable only by this user.
    ///
    /// The permissions are set as the file is created rather than afterwards,
    /// so there is no instant at which it is world-readable.
    public static func write(masterKey: [UInt8], uuid: String, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("\(uuid).key")
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(at: url, contents: Data(masterKey)) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// Remove anything left for a volume. Nothing there is not an error.
    public static func forget(uuid: String, in directory: URL) {
        for suffix in ["key", "pass"] {
            try? FileManager.default.removeItem(
                at: directory.appendingPathComponent("\(uuid).\(suffix)"))
        }
    }
}

private extension FileManager {
    /// `createFile` with the mode applied at creation time.
    func createFile(at url: URL, contents: Data) -> Bool {
        createFile(atPath: url.path, contents: contents,
                   attributes: [.posixPermissions: 0o600])
    }
}
