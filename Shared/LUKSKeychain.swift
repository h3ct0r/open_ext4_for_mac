//
//  LUKSKeychain.swift
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Compiled into both the container app and the FSKit extension. It is the
//  only thing they share, and the only channel between them: an app extension
//  has no IPC back to its host, so the app leaves the master key for a volume
//  where the extension will look for it.
//

import Foundation
import Security

/// Master keys for encrypted volumes, in the keychain both binaries can reach.
///
/// One item per container, keyed by its LUKS UUID, so a key can only ever open
/// the volume it was stored for.
///
/// Two details are load-bearing:
///
///  * **`kSecUseDataProtectionKeychain`.** macOS has two keychains, and access
///    groups only exist in the newer one. Without this flag the query goes to
///    the old file-based keychain, where the group is ignored and the app and
///    the extension cannot see each other's items at all.
///
///  * **No access group is named.** The first entry of the
///    `keychain-access-groups` entitlement is the default for items a binary
///    creates, and every entitled group is searched on lookup. Leaving it out
///    keeps the entitlement as the single place the group is written down, and
///    means neither binary has a team identifier compiled into it.
public enum LUKSKeychain {

    public static let service = "dev.h3ct0r.ext4mac.luks"

    /// Longest master key LUKS defines: AES-256-XTS, two 32-byte halves.
    public static let maxKeyLength = 64

    public enum Failure: Error, CustomStringConvertible {
        case notFound
        case malformed
        case keychain(OSStatus)

        public var description: String {
            switch self {
            case .notFound:          return "no stored key for this volume"
            case .malformed:         return "the stored item is not a usable master key"
            case .keychain(let s):
                let text = SecCopyErrorMessageString(s, nil) as String? ?? "OSStatus \(s)"
                return "keychain: \(text) (\(s))"
            }
        }
    }

    private static func base(uuid: String) -> [String: Any] {
        [
            kSecClass as String:                     kSecClassGenericPassword,
            kSecAttrService as String:               service,
            kSecAttrAccount as String:               uuid,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    /// Whether a key is stored for this container, without fetching it. Asks
    /// for attributes only (kSecReturnAttributes), so the master key never
    /// leaves the keychain into a heap array just to answer a yes/no -- which
    /// is what a plain masterKey() call did on every menu rebuild.
    public static func hasKey(uuid: String) -> Bool {
        var query = base(uuid: uuid)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
    }

    /// The master key stored for a container, if there is one.
    ///
    /// The caller owns the bytes and should zero them when done.
    public static func masterKey(uuid: String) throws -> [UInt8] {
        var query = base(uuid: uuid)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:      break
        case errSecItemNotFound: throw Failure.notFound
        default:                 throw Failure.keychain(status)
        }
        guard let data = item as? Data, !data.isEmpty, data.count <= maxKeyLength else {
            throw Failure.malformed
        }
        return [UInt8](data)
    }

    /// Store, or replace, the master key for a container.
    ///
    /// `ThisDeviceOnly` so the key is never carried to another machine by a
    /// keychain sync, and `WhenUnlocked` so it is unreadable while the Mac is
    /// locked -- an encrypted volume that stays readable across a locked
    /// screen would give away most of what the encryption was for.
    public static func store(masterKey: [UInt8], uuid: String, label: String) throws {
        guard !masterKey.isEmpty, masterKey.count <= maxKeyLength else {
            throw Failure.malformed
        }
        try? remove(uuid: uuid)

        var item = base(uuid: uuid)
        item[kSecValueData as String] = Data(masterKey)
        item[kSecAttrLabel as String] = label
        item[kSecAttrDescription as String] = "LUKS master key"
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        item[kSecAttrSynchronizable as String] = false

        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.keychain(status) }
    }

    /// Forget the key for a container. Not finding one is not an error.
    public static func remove(uuid: String) throws {
        let status = SecItemDelete(base(uuid: uuid) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Failure.keychain(status)
        }
    }

    /// The UUIDs we hold keys for. Never returns key material.
    public static func storedUUIDs() throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String:                     kSecClassGenericPassword,
            kSecAttrService as String:               service,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnAttributes as String:          true,
            kSecMatchLimit as String:                kSecMatchLimitAll,
        ]
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw Failure.keychain(status) }
        let rows = items as? [[String: Any]] ?? []
        return rows.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }
}
