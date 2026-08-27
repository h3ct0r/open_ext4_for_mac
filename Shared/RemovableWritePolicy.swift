//
//  RemovableWritePolicy.swift
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Whether this driver is allowed to write to media somebody can unplug.
///
/// Off by default, and that default is a consequence of a measured defect
/// rather than caution for its own sake. FSKit exposes no write barrier that
/// works here -- `metadataFlush` is the only one it has, and that whole I/O
/// family fails with `EIO` for reasons not yet understood -- so lwext4 issues
/// journal barriers that nothing carries out.
///
/// On a disk image that costs nothing: writes reach APFS through the page
/// cache in issue order, and killing the driver mid-write recovers cleanly
/// five times out of five. On a USB stick it costs the filesystem. Pulled from
/// under a live mount, one came back with ext4's own recovery reporting
/// `Journal transaction 8 was corrupt, replay was aborted` -- a commit block
/// that outran its own data, after which every later transaction is discarded.
///
/// So removable media mounts read-only unless somebody says otherwise. Reading
/// is unaffected and always has been: nothing is written, so nothing can be
/// reordered.
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
