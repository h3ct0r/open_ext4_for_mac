//
//  RemovableWritePolicy.swift
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Whether removable media may be written *without* a write barrier.
///
/// This marker used to be the only way to write a USB stick at all, because
/// no barrier existed and unordered writes were a measured corruption --
/// `Journal transaction 8 was corrupt, replay was aborted`, a commit block
/// that outran its own data. The barrier exists now (the privileged helper),
/// and the mount decides for itself: it asks the helper for a real barrier on
/// the real device, mounts read-write when one is confirmed -- the
/// configuration proven by five kill-recovery rounds and a physical
/// mid-write pull, all clean -- and read-only, with the reason logged, when
/// none is available.
///
/// What remains for this marker is the override: writes with no barrier, for
/// someone who accepts knowingly what the reorder suite's negative controls
/// keep demonstrating. Reading is unaffected in every mode: nothing is
/// written, so nothing can be reordered.
public enum RemovableWritePolicy {

    /// A marker file, in the extension's own container.
    ///
    /// Deliberately not a mount option: those arrive at `activate`, long after
    /// `loadResource` has decided how to open the volume. Deliberately not a
    /// preference domain either -- the sandboxed extension and the app do not
    /// share one without an entitlement, and this must work with neither.
    public static let markerName = "allow-removable-writes"

    /// The extension's own Application Support directory, as it sees it.
    public static func directoryFromInsideTheSandbox() -> URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory,
                                     in: .userDomainMask,
                                     appropriateFor: nil, create: false)
    }

    /// The same directory, as anything outside the sandbox sees it.
    public static func directoryFromOutside() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(LUKSKeyStore.extensionBundleID)/Data")
            .appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    public static func isEnabled(in directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(markerName).path)
    }

    public static func set(_ enabled: Bool, in directory: URL) throws {
        let url = directory.appendingPathComponent(markerName)
        if enabled {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try Data().write(to: url)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
