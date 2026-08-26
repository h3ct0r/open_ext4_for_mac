//
//  Ext4LUKSKeys.swift
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Security
import Ext4Core

/// Where the master key for an encrypted volume comes from.
///
/// The extension cannot ask for a passphrase. It draws no UI, FSKit has no
/// callback that delivers one, and the sandbox refuses to open a path the user
/// names on the mount command line -- all three measured, see `docs/STATUS.md`.
/// So the key has to be waiting somewhere before the mount begins.
///
/// Two sources, tried in order:
///
///  1. **The keychain**, holding a master key the container app derived. This
///     is the one that scales: the app can prompt, and it can afford the
///     gigabyte LUKS2 asks for, which an app extension may not. The passphrase
///     never enters this process.
///
///  2. **A file in this extension's own container**, holding either a master
///     key or a passphrase. It needs no entitlement and no running app, which
///     makes it the only source an automated test can use and the only one
///     that works on an unattended machine -- but the bytes sit on disk in the
///     clear, and a passphrase there means the derivation happens in this
///     process. A key derived that way is cached in the keychain so it happens
///     only once.
///
/// Both are keyed by the container's LUKS UUID, so a key can only ever open
/// the volume it was stored for.
enum Ext4LUKSKeys {

    /// The outcome of looking for a key, which the caller has to tell apart:
    /// "nobody has unlocked this yet" and "what was offered does not open it"
    /// are different errors to the person at the keyboard.
    enum Lookup {
        case found([UInt8])
        case unavailable
        case rejected
    }

    /// Find the master key for a container, by whatever means are available.
    ///
    /// `unlock` turns a passphrase into a master key; it is passed in rather
    /// than reached directly so this stays independent of the device.
    ///
    /// The caller owns the returned bytes and must zero them.
    static func masterKey(for info: luks_info,
                          unlock: ([UInt8]) -> [UInt8]?) -> Lookup {
        guard let uuid = uuidString(info) else {
            Ext4Log.error("LUKS container has no readable UUID")
            return .unavailable
        }

        if let key = keychainKey(uuid: uuid) {
            Ext4Log.info("master key for \(uuid) came from the keychain")
            return .found(key)
        }

        guard let directory = LUKSKeyStore.directoryFromInsideTheSandbox(),
              let material = LUKSKeyStore.material(uuid: uuid, in: directory) else {
            Ext4Log.info("no key available for LUKS container \(uuid)")
            return .unavailable
        }

        switch material {
        case .masterKey(let key):
            Ext4Log.info("master key for \(uuid) came from the extension's container")
            return .found(key)

        case .passphrase(var passphrase):
            defer { passphrase.resetBytes(in: 0..<passphrase.count) }
            guard let key = unlock(passphrase) else { return .rejected }
            Ext4Log.info("master key for \(uuid) derived from a passphrase")
            // Cache it, so the *next* load does not pay for the derivation
            // again. FSKit loads a resource twice per mount, in two separate
            // extension processes, so an in-memory cache would not help --
            // argon2id at cryptsetup's defaults costs about five seconds and
            // a gigabyte each time.
            cache(masterKey: key, uuid: uuid, in: directory)
            return .found(key)
        }
    }

    /// Remember a derived key for next time.
    ///
    /// Deliberately in the container and not the keychain, even though this
    /// process is entitled to write there. **The extension never creates
    /// keychain items; it only reads them.** Ownership has to sit in one
    /// place, and it belongs with the app -- which is what the user reaches
    /// for when they want a volume to stop being unlocked. A key cached
    /// somewhere the app cannot delete is a key nothing can forget.
    ///
    /// Best effort: failing to cache is not a reason to fail a mount that has
    /// already succeeded.
    private static func cache(masterKey: [UInt8], uuid: String, in directory: URL) {
        do {
            try LUKSKeyStore.write(masterKey: masterKey, uuid: uuid, in: directory)
        } catch {
            Ext4Log.info("could not cache the master key: \(error)")
        }
    }

    // MARK: - Sources

    /// A master key the container app stored for this volume.
    ///
    /// See `LUKSKeychain` for why the query looks the way it does.
    private static func keychainKey(uuid: String) -> [UInt8]? {
        do {
            return try LUKSKeychain.masterKey(uuid: uuid)
        } catch LUKSKeychain.Failure.notFound {
            return nil
        } catch {
            // The failure, never anything derived from a stored item.
            Ext4Log.info("keychain lookup failed: \(error)")
            return nil
        }
    }

    // MARK: - Helpers

    private static func uuidString(_ info: luks_info) -> String? {
        var raw = info.uuid
        let text = withUnsafeBytes(of: &raw) { buf -> String in
            String(cString: buf.bindMemory(to: CChar.self).baseAddress!)
        }.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
