//
//  LUKSVolumeName.swift
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// The name a locked container is presented under.
///
/// The extension's probe returns it, and the container app recognises volumes
/// by it — DiskArbitration hands out the name the probe produced, so the app
/// can tell an encrypted volume from anything else without opening the device.
/// One definition, so the two cannot drift apart.
public enum LUKSVolumeName {

    public static func forVersion(_ version: Int) -> String {
        "LUKS\(version) Encrypted Volume"
    }

    /// Whether a volume name came from us.
    public static func matches(_ name: String?) -> Bool {
        guard let name else { return false }
        return name.hasPrefix("LUKS") && name.hasSuffix(" Encrypted Volume")
    }
}
