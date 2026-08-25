//
//  main.swift
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FSKit

/// The app-extension entry point. FSKit instantiates this in a sandboxed
/// process when the kernel needs an ext volume mounted.
@main
struct Ext4Extension: UnaryFileSystemExtension {
    var fileSystem: Ext4FileSystem { Ext4FileSystem() }
}
