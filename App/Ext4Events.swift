//
//  Ext4Events.swift
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Reading what the extension had to say.
//
//  The extension cannot talk to anybody: no window, no notification, and a
//  failure vocabulary that reaches the user as one sentence -- "The disk you
//  inserted was not readable by this computer." -- whether the volume uses a
//  feature we have not implemented, carries a journal we would not replay, or
//  is a LUKS container nobody has unlocked yet. The third of those is not even
//  a problem; it is a volume waiting for a passphrase, and it looks identical
//  to a broken disk.
//
//  So the extension writes an event, and this reads it back.
//

import Foundation

enum Ext4Events {

    /// `Ext4Mac last-error <uuid|disk> [events-directory]`
    ///
    /// The optional directory is how this is tested without an installed
    /// extension, and it is also the honest way to look at events somebody
    /// copied out of a machine that is not this one. Visible in the usage
    /// text, because a hidden way in is a thing to be discovered rather than
    /// used.
    static func lastError(_ arguments: [String]) -> Int32 {
        guard let key = arguments.first else { return usage() }
        guard let dir = directory(arguments.dropFirst().first) else {
            FileHandle.standardError.write(
                "Ext4Mac: no events directory\n".data(using: .utf8)!)
            return 1
        }
        // A UUID, a BSD name, or /dev/diskN -- people paste all three.
        let cleaned = key.hasPrefix("/dev/") ? String(key.dropFirst(5)) : key
        guard let event = VolumeEventStore.latest(forKey: cleaned, in: dir) else {
            print("no event recorded for \(key)")
            return 1
        }
        print(describe(event))
        return 0
    }

    /// `Ext4Mac events [count] [events-directory]` -- the recent history,
    /// oldest first, which is the order somebody reading a trail wants.
    static func events(_ arguments: [String]) -> Int32 {
        var rest = arguments
        var count = VolumeEventStore.recentCount
        if let first = rest.first, let n = Int(first) {
            // Collection.suffix traps on a negative length. A diagnostic verb
            // somebody runs because something already went wrong must not
            // add a crash to it.
            guard n >= 0 else {
                print("usage: Ext4Mac events [count] [events-directory]")
                return 2
            }
            count = n; rest.removeFirst()
        }
        guard let dir = directory(rest.first) else {
            FileHandle.standardError.write(
                "Ext4Mac: no events directory\n".data(using: .utf8)!)
            return 1
        }
        let recent = VolumeEventStore.recent(count, in: dir)
        if recent.isEmpty {
            print("no events recorded")
            return 1
        }
        for event in recent {
            print(oneLine(event))
        }
        return 0
    }

    static func directory(_ explicit: String?) -> URL? {
        if let explicit, !explicit.isEmpty {
            return URL(fileURLWithPath: explicit, isDirectory: true)
        }
        return VolumeEventStore.directory(insideSandbox: false)
    }

    /// One line, for a list. The shape a person scans.
    static func oneLine(_ e: VolumeEvent) -> String {
        let when = DateFormatter.eventStamp.string(from: Date(timeIntervalSince1970: e.time))
        return "\(when)  \(e.device)  \(e.kind.rawValue)  \(e.reason)"
    }

    /// The whole thing, for one volume. Every field that has a value, because
    /// this is what somebody pastes into a bug report.
    static func describe(_ e: VolumeEvent) -> String {
        var out: [String] = []
        out.append("device:   \(e.device)")
        if let uuid = e.uuid   { out.append("uuid:     \(uuid)") }
        if let label = e.label { out.append("label:    \(label)") }
        out.append("time:     \(DateFormatter.eventStamp.string(from: Date(timeIntervalSince1970: e.time)))")
        out.append("kind:     \(e.kind.rawValue)")
        if let verdict = e.verdict { out.append("verdict:  \(verdict)") }
        out.append("reason:   \(e.reason)")
        for (i, line) in e.bridge.enumerated() {
            out.append(i == 0 ? "core:     \(line)" : "          \(line)")
        }
        out.append("build:    \(e.build)")
        if let advice = advice(for: e.kind) {
            out.append("")
            out.append(advice)
        }
        return out.joined(separator: "\n")
    }

    /// What to do about it. The reason this whole channel exists is that "not
    /// readable by this computer" is the same sentence for situations with
    /// completely different next steps.
    static func advice(for kind: VolumeEvent.Kind) -> String? {
        switch kind {
        case .locked:
            return "This volume is encrypted and locked, not broken.\n"
                 + "  Ext4Mac unlock /dev/<disk>"
        case .keyRejected:
            return "The passphrase or key did not open the container. Another one might."
        case .refused:
            return "This driver will not touch this volume. Run e2fsck on a Linux machine\n"
                 + "and look at what it says before writing anything to it."
        case .replayRefused, .degradedReadOnly:
            return "Mounted read-only, so what you see may predate the last crash.\n"
                 + "Replaying the journal needs a read-write mount, or e2fsck on Linux."
        case .unformatted:
            return "Nothing recognisable here. If this disk is meant to be blank, format it;\n"
                 + "if it is not, stop and image it before doing anything else."
        case .mountFailed, .unmountFailed:
            return nil
        }
    }

    static func usage() -> Int32 {
        print("usage: Ext4Mac last-error <uuid|disk> [events-directory]")
        return 2
    }
}

extension DateFormatter {
    /// Local time, seconds resolution. The event stores an epoch value on
    /// purpose -- the extension has no business deciding how a person's
    /// machine formats a date -- and this is where that decision gets made.
    static let eventStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
}
