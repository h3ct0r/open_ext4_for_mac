//
//  Ext4Executor.swift
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Serialises every call into the ext4 core.
///
/// lwext4 keeps global mount-point state and its block cache has no internal
/// locking, so concurrent entry is undefined behaviour. FSKit, by contrast,
/// issues volume operations concurrently. This type is the boundary between
/// the two: a single serial queue that all core access funnels through.
///
/// This is a correctness requirement, not a performance tuning knob. Bulk file
/// data does not flow through here — that goes via kernel-offloaded I/O, where
/// the kernel moves bytes directly using extent maps we hand it.
final class Ext4Executor: @unchecked Sendable {

    private let queue = DispatchQueue(label: "dev.h3ct0r.ext4.core",
                                      qos: .userInitiated)

    /// Run a core operation, suspending the calling task rather than blocking it.
    func run<T>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try body() })
            }
        }
    }

    /// Run a core operation synchronously. Used on paths that are already
    /// serialised, such as mount and unmount.
    func runSync<T>(_ body: () throws -> T) rethrows -> T {
        try queue.sync(execute: body)
    }
}
