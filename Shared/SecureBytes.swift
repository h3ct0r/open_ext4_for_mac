//
//  SecureBytes.swift
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// A heap buffer of sensitive bytes that is wiped when the last reference to it
/// goes away.
///
/// The reason this is a class and not `[UInt8]`: an array is a value type with
/// copy-on-write, and `zero(&array)` after `let alias = array` wipes a *new*
/// buffer while the original -- still held by `alias` -- is freed intact. Every
/// "zero the passphrase" that followed an assignment had that hole; the
/// plaintext outlived the wipe. A reference type has one buffer, shared by
/// reference, zeroed exactly once in `deinit`. There is nothing to alias.
final class SecureBytes: @unchecked Sendable {
    // @unchecked: the buffer is written only in init and zeroed only in deinit;
    // between those it is read-only, so handing the object to a detached Task
    // (which is the whole point -- key derivation runs off the main thread) is
    // safe despite the raw pointer.
    private let buffer: UnsafeMutableBufferPointer<UInt8>

    var count: Int { buffer.count }
    var isEmpty: Bool { buffer.count == 0 }

    init(count: Int) {
        buffer = .allocate(capacity: max(count, 0))
        buffer.initialize(repeating: 0)
    }

    /// Copy the UTF-8 of a string in. Note the caller's `String` still holds the
    /// plaintext in storage Swift will not let us wipe -- that is the platform
    /// floor (NSSecureTextField and readLine both hand back a String). This at
    /// least keeps every copy we control wipeable.
    convenience init(utf8 string: String) {
        let bytes = Array(string.utf8)
        self.init(count: bytes.count)
        for (i, b) in bytes.enumerated() { buffer[i] = b }
    }

    convenience init(_ bytes: [UInt8]) {
        self.init(count: bytes.count)
        for (i, b) in bytes.enumerated() { buffer[i] = b }
    }

    /// Read-only access to the bytes, for the duration of the closure.
    func withUnsafeBytes<R>(_ body: (UnsafeBufferPointer<UInt8>) throws -> R) rethrows -> R {
        try body(UnsafeBufferPointer(buffer))
    }

    deinit {
        // volatile-ish: memset_s does not get optimised away the way a plain
        // loop over a soon-to-be-freed buffer can be.
        if let base = buffer.baseAddress, buffer.count > 0 {
            memset_s(base, buffer.count, 0, buffer.count)
        }
        buffer.deallocate()
    }
}
