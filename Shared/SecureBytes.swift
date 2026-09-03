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

    /// How many bytes were actually allocated -- the buffer rounded up to a
    /// page, because that is the unit mlock and munlock work in.
    private let allocatedBytes: Int

    /// Which allocator this came from, and therefore which one frees it.
    /// posix_memalign memory is freed with free(); Swift's allocate() is not.
    /// Not inferred from the sizes: a request that happens to be exactly one
    /// page makes the two indistinguishable, and getting that wrong is a
    /// mismatched free on the buffer holding somebody's passphrase.
    private let ownsRawAllocation: Bool

    /// Whether the kernel agreed not to page this out.
    ///
    /// A passphrase sits here for as long as it takes to derive a key from it,
    /// which with argon2id is a second or two of deliberately heavy memory
    /// traffic -- exactly the conditions under which something gets evicted.
    /// Anonymous memory that gets evicted goes to a swap file on a disk, and
    /// wiping the buffer afterwards does nothing for the copy the kernel made.
    ///
    /// Best-effort, and false is not an error: RLIMIT_MEMLOCK is small and a
    /// sandboxed extension cannot raise it. Refusing to unlock somebody's
    /// volume because the kernel would not lock a page is worse for them than
    /// the risk this removes. The flag exists so a test can assert it where it
    /// can be had, and `Ext4Mac selftest` does.
    let isLocked: Bool

    /// Whether this build asks at all. False only under the test-only
    /// LUKS_NO_MLOCK define; `Ext4Mac selftest` asserts this rather than
    /// `isLocked`, because a refusal is the host's RLIMIT_MEMLOCK and not a
    /// regression, and the design decision on record is availability over
    /// hygiene.
    static var lockAttempted: Bool {
#if LUKS_NO_MLOCK
        return false
#else
        return true
#endif
    }

    var count: Int { buffer.count }
    var isEmpty: Bool { buffer.count == 0 }

    init(count: Int) {
        let wanted = max(count, 0)
        let page = Int(sysconf(Int32(_SC_PAGESIZE)))
        let pageSize = page > 0 ? page : 4096
        // At least one page even for an empty buffer: posix_memalign with a
        // size of zero may return NULL, and a NULL base with a count of zero
        // then has to be special-cased in three places instead of here.
        let rounded = max(((wanted + pageSize - 1) / pageSize) * pageSize, pageSize)

        var raw: UnsafeMutableRawPointer?
        let rc = posix_memalign(&raw, pageSize, rounded)
        guard rc == 0, let base = raw?.assumingMemoryBound(to: UInt8.self) else {
            // Out of memory. Fall back to an ordinary allocation rather than
            // trapping: this is on the path that unlocks somebody's disk.
            buffer = .allocate(capacity: wanted)
            buffer.initialize(repeating: 0)
            allocatedBytes = wanted
            ownsRawAllocation = false
            isLocked = false
            return
        }
        base.initialize(repeating: 0, count: rounded)
        allocatedBytes = rounded
        ownsRawAllocation = true
#if LUKS_NO_MLOCK
        isLocked = false
#else
        isLocked = mlock(base, rounded) == 0
#endif
        buffer = UnsafeMutableBufferPointer(start: base, count: wanted)
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
        // loop over a soon-to-be-freed buffer can be. The whole allocation,
        // not just the requested count: the rest of the page is ours and was
        // zeroed at the start, and wiping what we asked for while leaving the
        // page around is the sort of half-measure this class exists to avoid.
        guard let base = buffer.baseAddress else { return }
        memset_s(base, allocatedBytes, 0, allocatedBytes)
        if isLocked { munlock(base, allocatedBytes) }
        if ownsRawAllocation {
            free(UnsafeMutableRawPointer(base))
        } else {
            buffer.deallocate()
        }
    }
}
