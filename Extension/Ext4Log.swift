//
//  Ext4Log.swift
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import os
import Ext4Core

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

    /// The last few error-level lines from the C core, kept so they can be
    /// put in front of the person holding the stick rather than only in an
    /// os_log stream nobody was watching. One process serves one resource,
    /// so one ring is per-mount; `forgetCoreLines` at the start of each
    /// probe and load keeps a refusal from carrying the previous one's lines.
    static let coreLineCapacity = 8
    private static let coreLines = OSAllocatedUnfairLock(initialState: [String]())

    static func rememberCoreLine(_ line: String) {
        coreLines.withLock {
            $0.append(line)
            if $0.count > coreLineCapacity { $0.removeFirst($0.count - coreLineCapacity) }
        }
    }
    static func recentCoreLines() -> [String] { coreLines.withLock { $0 } }
    static func forgetCoreLines() { coreLines.withLock { $0.removeAll() } }

    /// Route the C core's diagnostics into os_log. The bridge calls
    /// `ext4b_set_logger` nowhere on its own, so until this runs every
    /// `bridge_log` -- "journal recovery failed; refusing read-write mount",
    /// "could not start journal", the orphan-cleanup failures -- is written to
    /// a logger that was never installed and vanishes. Idempotent, install
    /// once at startup. Levels: the core uses >= 3 for errors, less for info.
    static let installBridgeLogger: Void = {
        ext4b_set_logger({ _, level, msg in
            guard let msg else { return }
            let text = String(cString: msg)
            if level >= 3 {
                Ext4Log.core.error("core: \(text, privacy: .public)")
                Ext4Log.rememberCoreLine(text)
            } else {
                Ext4Log.core.info("core: \(text, privacy: .public)")
            }
        }, nil)
    }()
}
