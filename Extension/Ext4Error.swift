//
//  Ext4Error.swift
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FSKit
import Ext4Core

/// Translates the core's errno-style returns into the NSError values FSKit
/// expects. FSKit propagates these to the kernel, so using the right POSIX
/// code matters: callers of open(2)/read(2) see exactly this errno.
enum Ext4Error {

    /// Throws if `code` is a non-zero errno.
    static func check(_ code: Int32,
                      _ context: @autoclosure () -> String = "") throws {
        guard code != 0 else { return }
        let message = context()
        if !message.isEmpty {
            Ext4Log.error("\(message): \(String(cString: ext4b_strerror(code)))")
        }
        throw fs_errorForPOSIXError(code)
    }

    static func posix(_ code: Int32) -> Error {
        fs_errorForPOSIXError(code)
    }

    static var notSupported: Error { posix(ENOTSUP) }
    static var readOnly: Error { posix(EROFS) }
    static var noEntry: Error { posix(ENOENT) }
    static var notDirectory: Error { posix(ENOTDIR) }
    static var invalid: Error { posix(EINVAL) }
    static var ioError: Error { posix(EIO) }
}
