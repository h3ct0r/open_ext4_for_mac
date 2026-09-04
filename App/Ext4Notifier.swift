//
//  Ext4Notifier.swift — the part that notices the extension had something to say
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  The extension writes a VolumeEvent when it refuses, degrades, locks or
//  fails a volume (Shared/VolumeEvent.swift). It cannot show anybody: it has
//  no window and FSKit's own vocabulary reaches the user as "The disk you
//  inserted was not readable by this computer." This watches the directory
//  those files land in and turns a new one into a notification -- the one
//  place a sentence like "this volume is encrypted and locked, not broken"
//  can appear at the moment the disk is plugged in.
//
//  No IPC, on purpose. A directory watch on the file the extension already
//  writes is the same channel LUKSKeyStore proved, and it keeps working when
//  the agent was not running at the time: the file is still there, and
//  `Ext4Mac status` and `Ext4Mac last-error` read it.
//

import AppKit
import UserNotifications

@MainActor
final class Ext4Notifier {

    private let directory: URL
    private var watched: URL?
    private var fd: Int32 = -1
    private var source: DispatchSourceFileSystemObject?
    /// The newest event already shown, so a re-arm or a DiskArbitration
    /// callback does not show the same one twice.
    private var shownUpTo: Double
    /// Called after a new event is noticed, so the menu can be rebuilt.
    var onChange: (() -> Void)?

    init(directory: URL) {
        self.directory = directory
        // Whatever is already there was there before this agent started:
        // history, not news. Only what arrives from now on is announced.
        self.shownUpTo = VolumeEventStore.all(in: directory).first?.time ?? 0
    }

    func start() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                appLog.error("notifications: \(error.localizedDescription, privacy: .public)")
            } else if !granted {
                appLog.info("notifications not granted; events are still in `Ext4Mac status`")
            }
        }
        watch()
    }

    /// The directory may not exist yet -- an extension that has never had to
    /// refuse anything never creates it -- so watch the nearest existing
    /// ancestor and move down when it appears. A rename inside a directory
    /// fires `.write` on the directory, which is what an atomic event write is.
    private func watch() {
        source?.cancel(); source = nil
        if fd >= 0 { close(fd); fd = -1 }

        var target = directory
        while !FileManager.default.fileExists(atPath: target.path) {
            let parent = target.deletingLastPathComponent()
            guard parent.path != target.path else { return }
            target = parent
        }
        fd = open(target.path, O_EVTONLY)
        guard fd >= 0 else {
            appLog.error("cannot watch \(target.path, privacy: .public): \(String(cString: strerror(errno)), privacy: .public)")
            return
        }
        watched = target
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                                                          eventMask: [.write, .rename, .delete],
                                                          queue: .main)
        s.setEventHandler { [weak self] in
            guard let self else { return }
            if self.watched != self.directory,
               FileManager.default.fileExists(atPath: self.directory.path) {
                self.watch()
            }
            self.check()
        }
        s.resume()
        source = s
    }

    /// Look for anything newer than what has been shown. Also called from
    /// the DiskArbitration callbacks: a disk appearing is exactly when an
    /// event is about to be written, and a watch can be re-arming.
    func check() {
        let fresh = VolumeEventStore.all(in: directory)
            .filter { $0.time > shownUpTo }
            .sorted { $0.time < $1.time }
        guard !fresh.isEmpty else { return }
        for event in fresh { notify(event) }
        shownUpTo = fresh.last!.time
        onChange?()
    }

    private func notify(_ e: VolumeEvent) {
        let content = UNMutableNotificationContent()
        content.title = Ext4Notifier.title(for: e)
        var body = e.reason
        if let advice = Ext4Events.advice(for: e.kind) {
            body += "\n" + advice.replacingOccurrences(of: "\n  ", with: " ")
        }
        content.body = body
        // One notification per volume: a stick refused at every probe
        // replaces its own notice rather than stacking ten of them.
        let request = UNNotificationRequest(identifier: "volume-\(e.key)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                appLog.error("notification for \(e.device, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        appLog.info("event on \(e.device, privacy: .public): \(e.kind.rawValue, privacy: .public) — \(e.reason, privacy: .public)")
    }

    static func title(for e: VolumeEvent) -> String {
        let name = e.label ?? e.device
        switch e.kind {
        case .locked:           return "\(name) is locked"
        case .keyRejected:      return "\(name): the stored key was rejected"
        case .refused:          return "\(name) was not mounted"
        case .degradedReadOnly: return "\(name) mounted read-only"
        case .replayRefused:    return "\(name): journal not replayed"
        case .mountFailed:      return "\(name) could not be mounted"
        case .unmountFailed:    return "\(name): unmount did not finish cleanly"
        case .unformatted:      return "\(name) has no filesystem"
        }
    }
}
