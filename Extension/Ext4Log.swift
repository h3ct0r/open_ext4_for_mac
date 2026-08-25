//
//  Ext4Log.swift
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import os

/// Unified logging for the extension.
///
/// The extension is sandboxed and has no console, so os_log is the only way to
/// see what it is doing. Follow along with:
///
///     log stream --predicate 'subsystem == "dev.h3ct0r.ext4"' --level debug
///
enum Ext4Log {
    static let subsystem = "dev.h3ct0r.ext4"

    static let core   = Logger(subsystem: subsystem, category: "core")
    static let volume = Logger(subsystem: subsystem, category: "volume")
    static let io     = Logger(subsystem: subsystem, category: "io")

    static func error(_ message: String) { core.error("\(message, privacy: .public)") }
    static func info(_ message: String)  { core.info("\(message, privacy: .public)") }
    static func debug(_ message: String) { core.debug("\(message, privacy: .public)") }
}
