//
//  Ext4Extension.swift
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FSKit

/// The app-extension entry point. FSKit instantiates this in a sandboxed
/// process when the kernel needs an ext volume mounted.
@main
struct Ext4Extension: UnaryFileSystemExtension {

    /// One filesystem instance for the lifetime of the process.
    ///
    /// This must NOT be a computed property that returns a fresh object.
    /// FSKit reads `fileSystem` more than once, and the delegate carries the
    /// mounted state: the block device bridge, the open volume, the live item
    /// table. Handing back a new instance each time means `loadResource` lands
    /// on a different object than `probeResource` did, and the volume the
    /// kernel is given is not the one holding the mount.
    private static let shared = Ext4FileSystem()

    var fileSystem: Ext4FileSystem { Self.shared }
}
