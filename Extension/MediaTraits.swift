//
//  MediaTraits.swift
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import IOKit
import IOKit.storage

/// What kind of device is underneath a volume.
///
/// `FSBlockDeviceResource` says how big it is and whether it is writable, and
/// nothing about whether somebody can pull it out of the machine. That matters
/// here more than it does for most drivers: without a working write barrier,
/// a volume that is disconnected while mounted can come back inconsistent, and
/// the volumes people disconnect are exactly the removable ones.
///
/// Read out of the IORegistry, walking up from the media object to whatever
/// ancestor actually carries the property -- a partition does not know it is
/// removable, its disk does.
/// What the write policy needs to know about a device, as four disjoint
/// cases -- so the "we could not tell" case is a value with its own handling,
/// not a `nil` that silently falls through to "not removable".
enum MediaClass {
    /// An internal disk. Its writes reach the platter in issue order; no
    /// barrier probe needed.
    case fixed
    /// A disk image. Removable and ejectable like a stick, but its writes
    /// reach APFS through the page cache in issue order -- exempt for the same
    /// reason a fixed disk is.
    case virtualDevice
    /// Something a person can physically pull: a USB stick, an SD card. Has its
    /// own write cache and reorders freely, so it is writable only behind a
    /// confirmed barrier.
    case physicallyDetachable
    /// The IORegistry lookup failed, so we do not know. Treated exactly like
    /// physicallyDetachable -- fail closed: better a needless barrier probe (or
    /// a read-only mount) than an unbarriered write to a stick we misjudged.
    case unknown

    /// Whether a device in this class may only be written behind a barrier.
    var requiresBarrier: Bool {
        switch self {
        case .physicallyDetachable, .unknown: return true
        case .fixed, .virtualDevice:          return false
        }
    }
}

struct MediaTraits {
    let removable: Bool
    let ejectable: Bool
    let interconnect: String

    /// True when this looks like something a person can unplug.
    var isDetachable: Bool { removable || ejectable }

    /// True when pulling it out is a *physical* act.
    ///
    /// A disk image reports removable and ejectable exactly as a USB stick
    /// does -- both are true, and detaching one is a real operation. What
    /// separates them is the interconnect: an image reaches the medium through
    /// the page cache and onto APFS in issue order, which is why killing the
    /// driver over one recovers cleanly every time, while a stick has its own
    /// write cache and reorders freely. The distinction is the whole reason
    /// this type exists.
    var isPhysicallyDetachable: Bool {
        isDetachable && interconnect != "Virtual Interface"
    }

    static func read(bsdName: String) -> MediaTraits? {
        let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName)
        guard let matching else { return nil }

        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        func flag(_ key: String) -> Bool {
            let value = IORegistryEntrySearchCFProperty(
                service, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
            return (value as? Bool) ?? false
        }
        func text(_ key: String) -> String? {
            let value = IORegistryEntrySearchCFProperty(
                service, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
            return value as? String
        }

        return MediaTraits(removable: flag(kIOMediaRemovableKey),
                           ejectable: flag("Ejectable"),
                           interconnect: text("Physical Interconnect") ?? "unknown")
    }

    /// Classify a device for the write policy. Folds the IORegistry-lookup
    /// failure into `.unknown` rather than losing it as a `nil`, which is what
    /// let a device we could not read mount read-write with no barrier check.
    static func classify(bsdName: String) -> MediaClass {
        guard let t = read(bsdName: bsdName) else { return .unknown }
        if !t.isDetachable { return .fixed }
        if t.interconnect == "Virtual Interface" { return .virtualDevice }
        return .physicallyDetachable
    }
}
