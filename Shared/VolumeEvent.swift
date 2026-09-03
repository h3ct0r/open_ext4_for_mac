//
//  VolumeEvent.swift
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  What the extension has to say about a volume, in a form something outside
//  its sandbox can read.
//
//  The extension has no way to talk to a person. It is not an app, it has no
//  window, and FSKit's failure vocabulary is a handful of errno values that
//  reach the user as "The disk you inserted was not readable by this
//  computer." -- the same sentence for a volume with a feature we do not
//  implement, a volume whose journal we refused to replay, and a LUKS
//  container nobody has unlocked. Three different situations, three different
//  things the person should do, one sentence.
//
//  So the extension writes down what happened, and the container app -- which
//  does have a window, a menu bar and notifications -- reads it. There is no
//  IPC here and there is deliberately not going to be any: a file in the
//  extension's own container, written inside the sandbox and read from
//  outside, is the channel LUKSKeyStore already proved works.
//

import Foundation

/// One thing that happened to one volume, as the extension saw it.
///
/// Written by the extension, read by the app. `Codable` in both directions and
/// versioned by `schema`, because these files outlive the build that wrote
/// them: a volume refused at breakfast is still on disk when a newer app opens
/// it at lunch.
public struct VolumeEvent: Codable, Equatable, Sendable {

    /// What kind of thing happened. The vocabulary is deliberately small: each
    /// case is a different sentence to a person and a different next step, and
    /// a case nobody can act differently on does not deserve to exist.
    public enum Kind: String, Codable, Sendable {
        /// The volume was not something we will touch at all -- an unsupported
        /// feature, a superblock that does not add up. Next step: e2fsck on
        /// Linux, or nothing.
        case refused
        /// Mounted, but read-only when read-write was asked for. Next step:
        /// depends entirely on the reason, which is why there is one.
        case degradedReadOnly
        /// We were willing and it did not work. Next step: look at `reason`.
        case mountFailed
        /// Unmount returned a failure. Next step: do not pull the stick yet.
        case unmountFailed
        /// A journal needed replaying and we would not replay it.
        case replayRefused
        /// A LUKS container with no key available. Next step: unlock it in the
        /// app. This is the one that most looks like a broken disk and is not.
        case locked
        /// A key was offered and the container rejected it. Next step: another
        /// passphrase.
        case keyRejected
        /// Not a filesystem we recognise -- possibly a blank disk. Next step:
        /// format it, if that is what was meant.
        case unformatted
    }

    /// Bumped when a field changes meaning, never when one is added. A reader
    /// that does not know a schema shows the file as unreadable rather than
    /// guessing at it.
    public static let currentSchema = 1

    public var schema: Int
    /// When, in seconds since the epoch. Not a formatted string: formatting is
    /// the reader's business and it has the user's locale, which the extension
    /// does not.
    public var time: Double
    /// The BSD name, e.g. "disk4s1". What DiskArbitration and the person at
    /// the keyboard both call it.
    public var device: String
    /// The filesystem UUID, when there is one to have. A volume refused before
    /// its superblock was readable has none.
    public var uuid: String?
    public var label: String?
    public var kind: Kind
    /// The probe verdict, when a probe got far enough to have one: USABLE,
    /// READ_ONLY, UNSUPPORTED, NOT_EXT4.
    public var verdict: String?
    /// One sentence a person can act on. Not an errno, not a Swift error
    /// description with a module prefix in it.
    public var reason: String
    /// The last few level-3 lines from the C core, in order. This is where
    /// "read-only mount of an unreplayed journal: contents predate the last
    /// crash" ends up -- the line that explains "the files look old", which
    /// until now only existed in an os_log stream nobody was watching.
    public var bridge: [String]
    /// Which build said this. A field report that names a commit is worth
    /// several that do not.
    public var build: String
    public var pid: Int32

    public init(kind: Kind,
                device: String,
                uuid: String? = nil,
                label: String? = nil,
                verdict: String? = nil,
                reason: String,
                bridge: [String] = [],
                build: String,
                time: Double = Date().timeIntervalSince1970,
                pid: Int32 = ProcessInfo.processInfo.processIdentifier) {
        self.schema  = VolumeEvent.currentSchema
        self.time    = time
        self.device  = device
        self.uuid    = uuid
        self.label   = label
        self.kind    = kind
        self.verdict = verdict
        self.reason  = reason
        self.bridge  = bridge
        self.build   = build
        self.pid     = pid
    }

    /// The file name a volume's latest event is kept under.
    ///
    /// The UUID when there is one, because it survives replugging into another
    /// port and getting a different BSD name. The BSD name when there is not,
    /// because a volume we could not read far enough to get a UUID from is
    /// exactly the volume somebody needs to be told about.
    public static func key(uuid: String?, device: String) -> String {
        if let uuid, !uuid.isEmpty { return sanitised(uuid) }
        return sanitised(device)
    }

    public var key: String { VolumeEvent.key(uuid: uuid, device: device) }

    /// A file name, not a path. The inputs come off a disk somebody else
    /// formatted, so a label or UUID containing "/" or ".." is a thing that
    /// can happen and must not become a directory traversal in the app.
    static func sanitised(_ s: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let cleaned = String(s.prefix(128).map { allowed.contains($0) ? $0 : "_" })
        return cleaned.isEmpty ? "unknown" : cleaned
    }
}
