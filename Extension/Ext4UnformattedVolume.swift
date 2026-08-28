//
//  Ext4UnformattedVolume.swift
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FSKit
import Ext4Core

/// The volume `loadResource` answers with when the media holds no filesystem
/// this module can read.
///
/// It exists because of how formatting works. `newfs_fskit` asks fskitd to
/// format a resource, and fskitd *loads* the resource first -- unconditionally,
/// before it will create the maintenance task -- so a `loadResource` that
/// refuses unrecognised media refuses formatting too. That was the entire
/// mystery of "startFormat is never called": the error `newfs_fskit` printed
/// was this module's own ENOTSUP, relayed back through fskitd from a load that
/// never needed to succeed as a *mount* -- only as a load. (The msdos module
/// demonstrates the contract: its load of a blank device succeeds and the
/// format proceeds; nothing about it requires an ObjC principal class.)
///
/// So unrecognised media loads successfully as this: a volume-shaped object
/// with no filesystem behind it. It can be the target of `startFormat` and
/// `startCheck`, which take their device from `lastSeenResource` and never
/// touch the volume. It cannot do anything else: activation -- the step every
/// actual use of a volume goes through first -- fails with ENOTSUP exactly
/// where the load itself used to, and the remaining operations answer the
/// same way for a caller that never activated.
///
/// Auto-mount is unaffected: DiskArbitration routes media here only after
/// `probeResource` recognises it, and the probe still refuses everything this
/// shell stands in for.
final class Ext4UnformattedVolume: FSVolume {

    init(bsdName: String) {
        // The identifier is random on purpose: media without a filesystem has
        // no identity, and this object's lifetime is one load. What must NOT
        // happen is two loads inventing the same identity for different media.
        super.init(volumeID: FSVolume.Identifier(uuid: UUID()),
                   volumeName: FSFileName(string: bsdName))
    }

    private var refusal: Error { Ext4Error.notSupported }
}

extension Ext4UnformattedVolume: FSVolume.PathConfOperations {
    var maximumLinkCount: Int { 1 }
    var maximumNameLength: Int { 255 }
    var restrictsOwnershipChanges: Bool { true }
    var truncatesLongNames: Bool { false }
}

extension Ext4UnformattedVolume: FSVolume.Operations {

    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        FSVolume.SupportedCapabilities()
    }

    var volumeStatistics: FSStatFSResult {
        FSStatFSResult(fileSystemTypeName: "ext4")
    }

    func activate(options: FSTaskOptions) async throws -> FSItem {
        Ext4Log.error("refusing to activate: no recognisable filesystem on this media")
        throw refusal
    }

    // Teardown must never add its own failure to whatever brought it here.
    func deactivate(options: FSDeactivateOptions = []) async throws {}
    func mount(options: FSTaskOptions) async throws { throw refusal }
    func unmount() async {}
    func synchronize(flags: FSSyncFlags) async throws {}
    func reclaimItem(_ item: FSItem) async throws {}

    func attributes(_ desired: FSItem.GetAttributesRequest,
                    of item: FSItem) async throws -> FSItem.Attributes {
        throw refusal
    }

    func setAttributes(_ request: FSItem.SetAttributesRequest,
                       on item: FSItem) async throws -> FSItem.Attributes {
        throw refusal
    }

    func lookupItem(named name: FSFileName,
                    inDirectory directory: FSItem) async throws -> (FSItem, FSFileName) {
        throw refusal
    }

    func enumerateDirectory(_ directory: FSItem,
                            startingAt cookie: FSDirectoryCookie,
                            verifier: FSDirectoryVerifier,
                            attributes: FSItem.GetAttributesRequest?,
                            packer: FSDirectoryEntryPacker) async throws -> FSDirectoryVerifier {
        throw refusal
    }

    func readSymbolicLink(_ item: FSItem) async throws -> FSFileName {
        throw refusal
    }

    func createItem(named name: FSFileName,
                    type: FSItem.ItemType,
                    inDirectory directory: FSItem,
                    attributes: FSItem.SetAttributesRequest) async throws -> (FSItem, FSFileName) {
        throw refusal
    }

    func createSymbolicLink(named name: FSFileName,
                            inDirectory directory: FSItem,
                            attributes: FSItem.SetAttributesRequest,
                            linkContents contents: FSFileName) async throws -> (FSItem, FSFileName) {
        throw refusal
    }

    func createLink(to item: FSItem,
                    named name: FSFileName,
                    inDirectory directory: FSItem) async throws -> FSFileName {
        throw refusal
    }

    func removeItem(_ item: FSItem,
                    named name: FSFileName,
                    fromDirectory directory: FSItem) async throws {
        throw refusal
    }

    func renameItem(_ item: FSItem,
                    inDirectory sourceDirectory: FSItem,
                    named sourceName: FSFileName,
                    to destinationName: FSFileName,
                    inDirectory destinationDirectory: FSItem,
                    overItem: FSItem?) async throws -> FSFileName {
        throw refusal
    }
}
