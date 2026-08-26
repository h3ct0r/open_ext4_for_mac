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

    /// The error FSKit is told about while a volume is locked.
    ///
    /// `ENEEDAUTH` is the code FSKit's own documentation gives for this
    /// situation -- "the container needs authentication" -- paired with
    /// `FSContainerStateBlocked`. Nothing in the system acts on either; see
    /// `Ext4FileSystem.blockedVolume`.
    static func needsAuthError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(ENEEDAUTH), userInfo: [
            NSLocalizedDescriptionKey: "This volume is encrypted and needs a passphrase.",
        ])
    }
}

/// A volume that exists only so the container can report itself as blocked.
///
/// FSKit's state machine requires `loadResource` to hand back a volume even
/// when the container ends up blocked rather than ready -- the container state
/// is a property, not a return value. Nothing should ever be asked of this
/// object: a blocked container has no active volume, so there is no VFS layer
/// on the other side to call into it.
final class Ext4LockedVolume: FSVolume {

    /// The owning filesystem, so the device can be closed when FSKit gives up
    /// on the volume. Weak: the filesystem owns the volume.
    weak var fileSystem: Ext4FileSystem?

    init(info: luks_info) {
        let identifier: FSVolume.Identifier
        if let container = Ext4LUKS.containerID(info) {
            identifier = container.volumeIdentifier
        } else {
            identifier = FSVolume.Identifier(uuid: UUID())
        }
        super.init(volumeID: identifier,
                   volumeName: FSFileName(string: Ext4LUKS.name(info)))
    }
}

/// Every filesystem operation on a locked volume, refused with `EAUTH`.
///
/// FSKit requires this conformance whether or not the volume can do anything:
/// after `loadResource` returns, it proceeds to activate the volume regardless
/// of the container status, and a volume that does not answer
/// `activateWithOptions:` takes the whole extension down with an unrecognised
/// selector. Refusing cleanly is the difference between "this volume needs a
/// passphrase" and a crash report.
extension Ext4LockedVolume: FSVolume.PathConfOperations {

    var maximumLinkCount: Int { 65000 }
    var maximumNameLength: Int { 255 }
    var restrictsOwnershipChanges: Bool { true }
    var truncatesLongNames: Bool { false }
    var maximumXattrSize: Int { 4096 }
    var maximumFileSize: UInt64 { 0 }
}

extension Ext4LockedVolume: FSVolume.Operations {

    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        FSVolume.SupportedCapabilities()
    }

    var volumeStatistics: FSStatFSResult {
        FSStatFSResult(fileSystemTypeName: "ext4")
    }

    private var locked: Error { Ext4Error.posix(EAUTH) }

    func activate(options: FSTaskOptions) async throws -> FSItem {
        // Release the device before failing. FSKit does not call
        // `deactivate` or `unloadResource` after `activate` throws, so
        // anything still held here stays held: the next probe of the same
        // device then fails with "Resource busy", and the volume cannot be
        // retried without detaching the media. Measured, not assumed.
        await fileSystem?.closeVolume()

        Ext4Log.volume.info("refusing to activate a locked volume: no passphrase")
        throw locked
    }

    func deactivate(options: FSDeactivateOptions = []) async throws {
        await fileSystem?.closeVolume()
    }

    func mount(options: FSTaskOptions) async throws { throw locked }
    func unmount() async { }
    func synchronize(flags: FSSyncFlags) async throws { }

    func attributes(_ desired: FSItem.GetAttributesRequest,
                    of item: FSItem) async throws -> FSItem.Attributes { throw locked }

    func setAttributes(_ request: FSItem.SetAttributesRequest,
                       on item: FSItem) async throws -> FSItem.Attributes { throw locked }

    func lookupItem(named name: FSFileName,
                    inDirectory directory: FSItem) async throws -> (FSItem, FSFileName) { throw locked }

    func enumerateDirectory(_ directory: FSItem,
                            startingAt cookie: FSDirectoryCookie,
                            verifier: FSDirectoryVerifier,
                            attributes: FSItem.GetAttributesRequest?,
                            packer: FSDirectoryEntryPacker) async throws -> FSDirectoryVerifier { throw locked }

    func reclaimItem(_ item: FSItem) async throws { }

    func readSymbolicLink(_ item: FSItem) async throws -> FSFileName { throw locked }

    func createItem(named name: FSFileName,
                    type: FSItem.ItemType,
                    inDirectory directory: FSItem,
                    attributes: FSItem.SetAttributesRequest) async throws -> (FSItem, FSFileName) { throw locked }

    func createSymbolicLink(named name: FSFileName,
                            inDirectory directory: FSItem,
                            attributes: FSItem.SetAttributesRequest,
                            linkContents contents: FSFileName) async throws -> (FSItem, FSFileName) { throw locked }

    func createLink(to item: FSItem,
                    named name: FSFileName,
                    inDirectory directory: FSItem) async throws -> FSFileName { throw locked }

    func removeItem(_ item: FSItem,
                    named name: FSFileName,
                    fromDirectory directory: FSItem) async throws { throw locked }

    func renameItem(_ item: FSItem,
                    inDirectory sourceDirectory: FSItem,
                    named sourceName: FSFileName,
                    to destinationName: FSFileName,
                    inDirectory destinationDirectory: FSItem,
                    overItem: FSItem?) async throws -> FSFileName { throw locked }
}
