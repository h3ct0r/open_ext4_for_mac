//
//  VolumeEventStore.swift
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Where VolumeEvents live: a directory in the extension's own container,
//  written from inside the sandbox and read from outside it.
//
//      …/Library/Application Support/events/<uuid-or-bsdname>.json   latest
//      …/Library/Application Support/events/events.log               history
//
//  The same channel as LUKSKeyStore, for the same reason: the extension can
//  always reach its own container with no entitlement, and the container app
//  is not sandboxed and can reach it too. Nothing else is required to work --
//  no XPC, no shared group container, no agreement between two processes about
//  who is running.
//
//  Writes are atomic. The app watches this directory and will read a file the
//  instant it appears, so a half-written one is not a theoretical race: write
//  to a temporary name in the same directory and rename over the target, which
//  on APFS and HFS+ alike is atomic for the reader.
//

import Foundation

public enum VolumeEventStore {

    public static let extensionBundleID = "dev.h3ct0r.ext4mac.Ext4FS"

    /// The history file stops growing here. 256 KiB is a few thousand events,
    /// which is far more than anybody will read and small enough that the app
    /// can parse the whole thing to show the last ten.
    public static let maxLogBytes = 256 * 1024

    /// How many of the most recent history lines a reader asks for by default.
    public static let recentCount = 10

    /// The directory as the *extension* sees it: inside its sandbox,
    /// `.applicationSupportDirectory` already is the container.
    public static func directoryFromInsideTheSandbox() -> URL? {
        guard let support = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                         in: .userDomainMask,
                                                         appropriateFor: nil,
                                                         create: false) else { return nil }
        return support.appendingPathComponent("events", isDirectory: true)
    }

    /// The same directory as anything *outside* the sandbox sees it.
    public static func directoryFromOutside() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(extensionBundleID)/Data")
            .appendingPathComponent("Library/Application Support/events", isDirectory: true)
    }

    /// The directory to use, whichever side of the sandbox this is.
    ///
    /// Inside the extension the first form is right and the second names a
    /// path the sandbox forbids; outside it the first form points at the
    /// *app's* Application Support, which is not where anybody is looking.
    ///
    /// No environment variable here, deliberately. A test drives this store by
    /// passing a directory -- the CLI takes one as an optional argument and
    /// the test binary requires one -- rather than by setting something the
    /// shipping code would then have to read on every launch.
    public static func directory(insideSandbox: Bool) -> URL? {
        insideSandbox ? directoryFromInsideTheSandbox() : directoryFromOutside()
    }

    // ------------------------------------------------------------- writing --

    /// Record an event: replace this volume's latest, and append to the log.
    ///
    /// Never throws to its caller. Every call site is a path that is already
    /// reporting a failure to FSKit, and a filesystem driver that fails to
    /// mount a volume *and then* fails differently because it could not write
    /// a note about it is worse than one that just fails to mount. The return
    /// value says whether it landed, for a test to assert on.
    @discardableResult
    public static func record(_ event: VolumeEvent, in directory: URL) -> Bool {
        guard (try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])) != nil else { return false }
        // createDirectory applies the mode only when it creates the directory.
        // If it is already there -- made by an older build, or by whatever
        // made the parent -- it keeps whatever mode it had, which under the
        // default umask is 0755. These files name a person's disks and say
        // what went wrong with them; that is not world-readable material, and
        // "we asked for 0700" is not the same as "it is 0700".
        try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                               ofItemAtPath: directory.path)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(event) else { return false }

        let latest = directory.appendingPathComponent("\(event.key).json")
        let ok = atomicallyWrite(data, to: latest)
        appendToLog(data, in: directory)
        return ok
    }

    /// Write via a temporary file in the same directory, then rename.
    ///
    /// Same directory on purpose: rename is only atomic within a filesystem,
    /// and the temporary directory is not guaranteed to be on this one.
    static func atomicallyWrite(_ data: Data, to url: URL) -> Bool {
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(getpid()).tmp")
        guard FileManager.default.createFile(atPath: tmp.path, contents: data,
                                            attributes: [.posixPermissions: 0o600])
        else { return false }
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            return true
        } catch {
            // replaceItemAt fails when the target does not exist yet on some
            // volumes; a plain rename is the same guarantee for that case.
            if (try? FileManager.default.moveItem(at: tmp, to: url)) != nil { return true }
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
    }

    /// Append one JSON line to the history, rotating when it gets large.
    ///
    /// One line per event so a reader can take the tail without parsing the
    /// whole file, and so an interrupted write costs one line rather than the
    /// file. Rotation keeps exactly one older generation: this is a breadcrumb
    /// trail, not an audit log, and a stick that has been refused four
    /// thousand times has told us what it has to tell us.
    static func appendToLog(_ data: Data, in directory: URL) {
        let log = directory.appendingPathComponent("events.log")
        if let size = try? FileManager.default.attributesOfItem(atPath: log.path)[.size] as? Int,
           size >= maxLogBytes {
            let old = directory.appendingPathComponent("events.log.1")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: log, to: old)
        }
        var line = data
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: log) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            _ = FileManager.default.createFile(atPath: log.path, contents: line,
                                               attributes: [.posixPermissions: 0o600])
        }
    }

    // ------------------------------------------------------------- reading --

    /// The latest event for one volume, by UUID or BSD name.
    public static func latest(forKey key: String, in directory: URL) -> VolumeEvent? {
        let url = directory.appendingPathComponent("\(VolumeEvent.sanitised(key)).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(VolumeEvent.self, from: data)
    }

    /// Every volume with an event on record, newest first.
    public static func all(in directory: URL) -> [VolumeEvent] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let events = names
            .filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }
            .compactMap { name -> VolumeEvent? in
                guard let data = try? Data(contentsOf: directory.appendingPathComponent(name))
                else { return nil }
                return try? JSONDecoder().decode(VolumeEvent.self, from: data)
            }
        return events.sorted { $0.time > $1.time }
    }

    /// The last `count` entries of the history, oldest first.
    ///
    /// Reads both generations when the current one is short, so a rotation
    /// that just happened does not make the recent history look empty.
    public static func recent(_ count: Int = recentCount, in directory: URL) -> [VolumeEvent] {
        var lines: [String] = []
        for name in ["events.log.1", "events.log"] {
            let url = directory.appendingPathComponent(name)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            lines.append(contentsOf: text.split(separator: "\n").map(String.init))
        }
        let decoder = JSONDecoder()
        return lines.suffix(max(count, 0)).compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(VolumeEvent.self, from: data)
        }
    }

    /// Forget everything recorded for one volume.
    public static func forget(key: String, in directory: URL) {
        try? FileManager.default.removeItem(
            at: directory.appendingPathComponent("\(VolumeEvent.sanitised(key)).json"))
    }
}
