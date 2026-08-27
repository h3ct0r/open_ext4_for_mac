//
//  BarrierClient.swift
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import XPC

/// Asks the privileged helper to put a write barrier on the medium.
///
/// The barrier itself is one ioctl, `DKIOCSYNCHRONIZECACHE`, and this process
/// is not allowed to issue it. The App Sandbox denies it by name — the kernel
/// logs `deny(1) file-ioctl ... ioctl-command:(_IO "d" 22)` — and no
/// entitlement lifts that: a file-path exception grants read and write, not
/// ioctl, and the IOKit user-client exception that Apple's own `msdos` module
/// carries changes nothing here. So the call is made somewhere the sandbox
/// does not reach, and this is the near end of that arrangement.
///
/// The connection is kept for the life of the mount. Establishing one costs an
/// XPC handshake and a code-signature check on the far side, and this sits on
/// the path of every journal commit; the helper keeps its descriptor open for
/// the same reason.
final class BarrierClient {

    private let connection: xpc_connection_t
    private let bsdName: String

    /// True once a barrier has actually completed. Until then the helper might
    /// be unregistered, unapproved, or simply not there, and none of those are
    /// distinguishable from the outside without asking.
    private(set) var isWorking = false

    init?(bsdName: String) {
        self.bsdName = bsdName

        // Non-optional: this succeeds whether or not anything is listening.
        // Whether the helper is actually there is answered by the first
        // request, not by this call.
        let connection = xpc_connection_create_mach_service(
            "dev.h3ct0r.ext4mac.barrier", nil, 0)
        self.connection = connection

        // The helper never initiates anything, so the only events arriving
        // here are errors — an unregistered service, or the daemon going away.
        xpc_connection_set_event_handler(connection) { event in
            guard xpc_get_type(event) == XPC_TYPE_ERROR else { return }
            let text = xpc_dictionary_get_string(event, XPC_ERROR_KEY_DESCRIPTION)
                .map { String(cString: $0) } ?? "unknown"
            Ext4Log.io.error("barrier helper connection: \(text, privacy: .public)")
        }
        xpc_connection_resume(connection)
    }

    deinit {
        release()
        xpc_connection_cancel(connection)
    }

    /// Put a barrier on the medium. Returns 0, or an errno.
    ///
    /// Synchronous on purpose. A barrier that returned before the medium had
    /// committed would be a barrier in name only, and the caller is the
    /// journal, which is asking precisely because it needs to know.
    func barrier() -> Int32 {
        let status = send(release: false)
        if status == 0 { isWorking = true }
        return status
    }

    /// Tell the helper to let go of the device, so a stick that is unplugged
    /// does not leave a descriptor open as root until the daemon exits.
    func release() {
        _ = send(release: true)
    }

    private func send(release: Bool) -> Int32 {
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(message, "device", bsdName)
        xpc_dictionary_set_bool(message, "release", release)

        let reply = xpc_connection_send_message_with_reply_sync(connection, message)

        if xpc_get_type(reply) == XPC_TYPE_ERROR {
            let text = xpc_dictionary_get_string(reply, XPC_ERROR_KEY_DESCRIPTION)
                .map { String(cString: $0) } ?? "unknown"
            Ext4Log.io.error("barrier request failed: \(text, privacy: .public)")
            return EIO
        }

        return Int32(xpc_dictionary_get_int64(reply, "status"))
    }
}
