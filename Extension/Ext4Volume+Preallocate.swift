//
//  Ext4Volume+Preallocate.swift
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FSKit
import os
import Ext4Core

/// `fcntl(F_PREALLOCATE)`, answered the way ext4 answers it: UNWRITTEN
/// extents. Allocated and counted, excluded from reads (they see zeros), and
/// converted to ordinary written extents by the first write into them. The
/// file's size does not move -- only its allocation does.
extension Ext4Volume: FSVolume.PreallocateOperations {

    func preallocateSpace(for item: FSItem,
                          at offset: off_t,
                          length: size_t,
                          flags: FSVolume.PreallocateFlags) async throws -> Int {
        guard let ext4Item = item as? Ext4Item else { throw Ext4Error.invalid }
        try requireWritable()
        guard length > 0 else { return 0 }

        // How macOS asks for space decides the layout, and until this meter
        // existed nobody knew how it asks.
        //
        // The interesting number is calls-per-file. One call per file means
        // the copier knows the size up front and the allocation is one run;
        // many calls per file means it is asking incrementally, and with
        // several files in flight every increment lands in a different place.
        // Measured offline, both shapes on the same eight 32 MiB files: two
        // extents each when preallocated whole, thirty-four when preallocated
        // a megabyte at a time round-robin. That is the difference between a
        // corpus at 2% non-contiguous and one at 89%, and the log had no way
        // to say which was happening on real media.
        Self.preallocRequests.record(inode: ext4Item.inode, length)
        if let line = Self.preallocRequests.due() {
            Ext4Log.io.info("\(line, privacy: .public)")
        }

        // The SDK is explicit: FromEOF "is currently set for all
        // preallocateSpace calls", and with it the offset is to be ignored --
        // the space goes at the file's physical end. Physical, not logical:
        // repeated calls must not re-cover the same already-preallocated
        // range, and allocated-past-EOF is exactly what alloc_size tracks.
        let allocated = try await executor.run { [self] in
            var a = ext4b_attrs()
            try Ext4Error.check(ext4b_getattr(try device, ext4Item.inode, &a),
                                "getattr(\(ext4Item.inode))")
            let start = max(a.size, a.alloc_size)
            var got: UInt64 = 0
            try Ext4Error.check(
                ext4b_preallocate(try device, ext4Item.inode,
                                  start, UInt64(length), &got),
                "preallocate(\(ext4Item.inode) +\(length))")
            return Int(got)
        }

        // Without the persist flag the space is on loan: FSKit deactivates
        // the item when its last user goes, and the trim there returns it.
        notePreallocation(ext4Item.inode, persistent: flags.contains(.persist))

        // alloc_size changed; the cached attributes are stale.
        ext4Item.invalidate()
        return allocated
    }
}


/// Shape of the preallocation requests arriving from the kernel.
///
/// Reports on a call count rather than a byte total, unlike the write meter:
/// preallocations are few and what matters about them is how many there are
/// per file, not how many megabytes they cover.
private struct PreallocMeter {
    private let lock = OSAllocatedUnfairLock(initialState: State())
    private struct State {
        var calls = 0
        var reported = 0
        var bytes = 0
        var smallest = Int.max
        var largest = 0
        var inodes: Set<UInt32> = []
    }

    func record(inode: UInt32, _ n: Int) {
        lock.withLock { s in
            s.calls += 1
            s.bytes += n
            if n < s.smallest { s.smallest = n }
            if n > s.largest { s.largest = n }
            // Bounded: a copy of a few thousand files is a few thousand
            // integers, and the set is what makes calls-per-file readable.
            if s.inodes.count < 20_000 { s.inodes.insert(inode) }
        }
    }

    func due() -> String? {
        lock.withLock { s -> String? in
            guard s.calls - s.reported >= 64 else { return nil }
            s.reported = s.calls
            let files = max(s.inodes.count, 1)
            return String(format:
                "preallocate: %d calls over %d file(s) (%.1f per file), "
                + "%.0f MB, %d..%d KB",
                s.calls, s.inodes.count, Double(s.calls) / Double(files),
                Double(s.bytes) / 1_048_576.0,
                s.smallest / 1024, s.largest / 1024)
        }
    }
}

extension Ext4Volume {
    fileprivate static let preallocRequests = PreallocMeter()
}
