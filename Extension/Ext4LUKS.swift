//
//  Ext4LUKS.swift
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FSKit
import Ext4Core

/// Recognising an encrypted volume, and saying so to macOS.
///
/// A LUKS container is not an ext4 volume and never probes as one -- its first
/// bytes are a header, and everything after that is ciphertext. The filesystem
/// probe therefore has nothing to recognise, which is why a locked volume is
/// looked for separately and *before* giving up.
///
/// Claiming the volume is the whole point. FSKit only routes a device to a
/// module that said it recognised it, so a module that declines a LUKS
/// container never gets a second chance to ask for a passphrase.
enum Ext4LUKS {

    /// A short description for the volume in Finder, before the key is known.
    ///
    /// The ext4 label lives inside the ciphertext, so there is nothing better
    /// to offer until the volume is unlocked.
    static func name(_ info: luks_info) -> String {
        "LUKS\(info.version) Encrypted Volume"
    }

    /// The container's identity, taken from the LUKS UUID.
    ///
    /// Stable across unlocking: the same volume must not change identity when
    /// it stops being locked, or macOS treats it as a different one.
    static func containerID(_ info: luks_info) -> FSContainerIdentifier? {
        var raw = info.uuid
        let text = withUnsafeBytes(of: &raw) { buf -> String in
            String(cString: buf.bindMemory(to: CChar.self).baseAddress!)
        }
        guard let uuid = UUID(uuidString: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return FSContainerIdentifier(uuid: uuid)
    }

    /// Why a recognised container cannot be opened, in the header's own terms.
    static func reason(_ info: luks_info) -> String {
        var text = info.unsupported
        return withUnsafeBytes(of: &text) { buf -> String in
            String(cString: buf.bindMemory(to: CChar.self).baseAddress!)
        }
    }
}
