//
//  Ext4MenuBar.swift — the part that notices a disk was plugged in
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  An encrypted volume cannot prompt for its own passphrase: the extension is
//  sandboxed, draws no UI, and is handed the device only after macOS has
//  already decided to mount it. So something outside has to be watching, and
//  this is it -- a menu-bar agent that sees the volume appear, asks, derives
//  the master key, and then lets the mount proceed.
//
//  The app bundle is already LSUIElement, because it exists to host the FSKit
//  extension rather than to be looked at. Adding a status item costs nothing
//  and changes no manifest, which matters here: Info.plist edits are what have
//  deregistered this module before.
//

import AppKit
import DiskArbitration
import os
import ServiceManagement

/// The agent runs with no window and no terminal, so this is the only way to
/// find out what it did. Follow along with:
///
///     log stream --predicate 'subsystem == "dev.h3ct0r.ext4"'
///
/// Never logs key material, a passphrase, or anything derived from one.
let appLog = Logger(subsystem: "dev.h3ct0r.ext4", category: "app")

/// A LUKS container macOS currently knows about.
private struct EncryptedVolume {
    let bsdName: String          // "disk6"
    let displayName: String      // "LUKS2 Encrypted Volume"
    var uuid: String?            // nil when the header could not be read
    var isMounted: Bool
}

@MainActor
final class Ext4MenuBar: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var session: DASession!
    /// Keyed by BSD name, which is the one thing DiskArbitration always gives
    /// us and the one thing `mount` takes.
    private var volumes: [String: EncryptedVolume] = [:]
    /// Volumes we have already offered to unlock, so that a disk which
    /// reappears -- or a mount attempt that fails and retries -- does not put
    /// the same panel up again and again.
    private var asked: Set<String> = []
    private var panelIsUp = false
    /// What the extension wrote about volumes it would not, or could not,
    /// mount. Started once the menu exists; its notifications are the only
    /// way "encrypted and locked, not broken" reaches a person in time.
    private var notifier: Ext4Notifier?

    static func run() -> Never {
        let app = NSApplication.shared
        let delegate = Ext4MenuBar()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        exit(0)
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        appLog.info("menu-bar agent started")
        // Both switches a fresh install needs, asked for once and only when
        // they are actually missing.
        Ext4Setup.runAtLaunch()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "externaldrive.badge.person.crop",
                                   accessibilityDescription: "ext4")
            button.image?.isTemplate = true
        }

        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            statusItem.button?.toolTip = "could not talk to DiskArbitration"
            rebuildMenu()
            return
        }
        self.session = session
        DASessionScheduleWithRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        let context = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskAppearedCallback(session, nil, { disk, context in
            guard let context else { return }
            let me = Unmanaged<Ext4MenuBar>.fromOpaque(context).takeUnretainedValue()
            let snapshot = Ext4MenuBar.describe(disk)
            Task { @MainActor in me.diskAppeared(snapshot) }
        }, context)

        DARegisterDiskDisappearedCallback(session, nil, { disk, context in
            guard let context else { return }
            let me = Unmanaged<Ext4MenuBar>.fromOpaque(context).takeUnretainedValue()
            let name = Ext4MenuBar.describe(disk).bsdName
            Task { @MainActor in me.diskDisappeared(name) }
        }, context)

        // A volume already attached before this agent started still counts.
        DARegisterDiskDescriptionChangedCallback(session, nil, nil, { disk, _, context in
            guard let context else { return }
            let me = Unmanaged<Ext4MenuBar>.fromOpaque(context).takeUnretainedValue()
            let snapshot = Ext4MenuBar.describe(disk)
            Task { @MainActor in me.diskChanged(snapshot) }
        }, context)

        if let dir = VolumeEventStore.directory(insideSandbox: false) {
            let n = Ext4Notifier(directory: dir)
            n.onChange = { [weak self] in self?.rebuildMenu() }
            n.start()
            notifier = n
        }
        rebuildMenu()
    }

    // MARK: - DiskArbitration

    /// What we need out of a `DADisk`, read on whatever thread the callback
    /// arrived on and then carried to the main actor as plain values.
    private struct Snapshot: Sendable {
        let bsdName: String
        let volumeName: String?
        let volumeUUID: String?
        let isMounted: Bool
    }

    private nonisolated static func describe(_ disk: DADisk) -> Snapshot {
        let description = DADiskCopyDescription(disk) as? [String: Any] ?? [:]
        let bsd = description[kDADiskDescriptionMediaBSDNameKey as String] as? String ?? ""
        let name = description[kDADiskDescriptionVolumeNameKey as String] as? String
        let path = description[kDADiskDescriptionVolumePathKey as String] as? URL

        // The container identifier our own probe reported, handed back by
        // DiskArbitration. This is how the agent learns which container it is
        // looking at without opening the device -- which on physical media it
        // cannot do at all, the node being root:operator.
        var uuid: String?
        if let raw = description[kDADiskDescriptionVolumeUUIDKey as String] {
            uuid = (CFUUIDCreateString(kCFAllocatorDefault, (raw as! CFUUID)) as String).lowercased()
        }
        return Snapshot(bsdName: bsd, volumeName: name, volumeUUID: uuid, isMounted: path != nil)
    }

    private func diskAppeared(_ snapshot: Snapshot) {
        guard !snapshot.bsdName.isEmpty,
              LUKSVolumeName.matches(snapshot.volumeName) else { return }

        var volume = EncryptedVolume(bsdName: snapshot.bsdName,
                                     displayName: snapshot.volumeName ?? "Encrypted Volume",
                                     uuid: snapshot.volumeUUID,
                                     isMounted: snapshot.isMounted)
        // DiskArbitration's UUID is the one the probe reported, so it is
        // already the right answer. Reading the header is only a fallback for
        // media where it is missing.
        if volume.uuid == nil,
           case .success(let container) = Ext4Unlock.inspect(devicePath: "/dev/\(snapshot.bsdName)") {
            volume.uuid = container.uuid
        }
        volumes[snapshot.bsdName] = volume
        rebuildMenu()
        appLog.info("encrypted volume on \(snapshot.bsdName, privacy: .public): \(volume.uuid ?? "unreadable header", privacy: .public)")

        // Ask, once, if it is locked. This is the whole point of the agent:
        // plugging a disk in should be enough.
        guard let uuid = volume.uuid,
              !volume.isMounted,
              !Ext4Unlock.isUnlocked(uuid: uuid),
              !asked.contains(uuid) else { return }
        asked.insert(uuid)
        appLog.info("asking for the passphrase for \(uuid, privacy: .public)")
        promptToUnlock(volume)
    }

    private func diskChanged(_ snapshot: Snapshot) {
        // A description change is what a probe's verdict looks like from
        // here, and the event it wrote may have landed between two watch
        // events.
        notifier?.check()
        guard var known = volumes[snapshot.bsdName] else {
            diskAppeared(snapshot)
            return
        }
        known.isMounted = snapshot.isMounted
        volumes[snapshot.bsdName] = known
        rebuildMenu()
    }

    private func diskDisappeared(_ bsdName: String) {
        if let gone = volumes.removeValue(forKey: bsdName), let uuid = gone.uuid {
            // Ask again next time this volume turns up: a disk being unplugged
            // and plugged back in is exactly when someone expects to be asked.
            asked.remove(uuid)
        }
        rebuildMenu()
    }

    // MARK: - Unlocking

    private func promptToUnlock(_ volume: EncryptedVolume) {
        guard !panelIsUp else { return }
        panelIsUp = true
        defer { panelIsUp = false }

        let alert = NSAlert()
        alert.messageText = "Unlock \(volume.displayName)?"
        alert.informativeText = volume.uuid.map { "Volume \($0) on /dev/\(volume.bsdName)." }
            ?? "On /dev/\(volume.bsdName)."
        alert.addButton(withTitle: "Unlock")
        alert.addButton(withTitle: "Cancel")

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "Passphrase"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // SecureBytes, not [UInt8]: a value-type array shared into the Task
        // below would leave an un-wiped copy-on-write buffer behind. This one
        // buffer is passed by reference and zeroed once, in its deinit, after
        // the Task is done with it.
        let passphrase = SecureBytes(utf8: field.stringValue)
        field.stringValue = ""
        guard !passphrase.isEmpty else { return }

        // Deriving takes seconds and a gigabyte, so it does not belong on the
        // main thread with the menu frozen behind it.
        let device = "/dev/\(volume.bsdName)"
        let progress = beginProgress("Deriving the key for \(volume.displayName)…")
        Task.detached(priority: .userInitiated) {
            let result = Ext4Unlock.store(passphrase: passphrase, devicePath: device)
            await MainActor.run {
                progress.close()
                switch result {
                case .success(let (_, where_)):
                    appLog.info("unlocked \(volume.bsdName, privacy: .public); mounting")
                    self.warnIfPlaintext(where_)
                    self.mount(bsdName: volume.bsdName)
                case .failure(let why):
                    // The volume may simply have a different passphrase; let
                    // them try again rather than needing a replug.
                    if let uuid = volume.uuid { self.asked.remove(uuid) }
                    appLog.error("unlock failed: \(why.message, privacy: .public)")
                    self.report("Could not unlock \(volume.displayName)", why.message)
                }
                self.rebuildMenu()
            }
        }
    }

    /// Say so, once, when the key could not go somewhere encrypted at rest.
    private func warnIfPlaintext(_ stored: Ext4Unlock.Stored) {
        guard case .containerFile(let directory) = stored else { return }
        report("Unlocked, but the key is not encrypted at rest",
               "This copy of Ext4Mac is not signed for the shared keychain, so "
               + "the master key was written to:\n\n\(directory.path)\n\n"
               + "See docs/SIGNING.md.")
    }

    /// Mount, off the main thread: DiskArbitration answers on a run loop and
    /// the reply can take as long as a journal replay does.
    private func mount(bsdName: String) {
        Task.detached(priority: .userInitiated) {
            let outcome = Ext4Mount.mount(bsdName: bsdName)
            await MainActor.run {
                switch outcome {
                case .mounted:
                    appLog.info("mounted \(bsdName, privacy: .public)")
                case .noSuchDisk:
                    appLog.error("no such disk: \(bsdName, privacy: .public)")
                case .refused(let why):
                    appLog.error("mount refused: \(why, privacy: .public)")
                    self.report("Could not mount the volume", why)
                }
                self.rebuildMenu()
            }
        }
    }

    // MARK: - Menu

    private func rebuildMenu() {
        let menu = NSMenu()

        let extensionReady = FileManager.default.fileExists(
            atPath: "/Applications/Ext4Mac.app/Contents/Extensions/Ext4FS.appex")
        menu.addItem(withTitle: extensionReady ? "ext4 extension installed"
                                               : "ext4 extension NOT installed",
                     action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())

        if volumes.isEmpty {
            let item = menu.addItem(withTitle: "No encrypted volumes attached",
                                    action: nil, keyEquivalent: "")
            item.isEnabled = false
        } else {
            for volume in volumes.values.sorted(by: { $0.bsdName < $1.bsdName }) {
                let unlocked = volume.uuid.map { Ext4Unlock.isUnlocked(uuid: $0) } ?? false
                let state = volume.isMounted ? "mounted" : (unlocked ? "unlocked" : "locked")
                let item = NSMenuItem(title: "\(volume.displayName) — \(state)",
                                      action: nil, keyEquivalent: "")
                item.submenu = submenu(for: volume, unlocked: unlocked)
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        let issues = NSMenuItem(title: "Recent Issues", action: nil, keyEquivalent: "")
        issues.submenu = recentIssuesMenu()
        menu.addItem(issues)

        menu.addItem(.separator())
        let login = NSMenuItem(title: "Open at Login",
                               action: #selector(toggleOpenAtLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        let quit = NSMenuItem(title: "Quit Ext4Mac", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func submenu(for volume: EncryptedVolume, unlocked: Bool) -> NSMenu {
        let menu = NSMenu()
        if let uuid = volume.uuid {
            menu.addItem(withTitle: uuid, action: nil, keyEquivalent: "").isEnabled = false
        }
        menu.addItem(withTitle: "/dev/\(volume.bsdName)", action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())

        if !unlocked {
            let unlock = NSMenuItem(title: "Unlock…", action: #selector(unlockChosen(_:)), keyEquivalent: "")
            unlock.target = self
            unlock.representedObject = volume.bsdName
            menu.addItem(unlock)
        } else {
            if !volume.isMounted {
                let mount = NSMenuItem(title: "Mount", action: #selector(mountChosen(_:)), keyEquivalent: "")
                mount.target = self
                mount.representedObject = volume.bsdName
                menu.addItem(mount)
            }
            let forget = NSMenuItem(title: "Forget Key", action: #selector(forgetChosen(_:)), keyEquivalent: "")
            forget.target = self
            forget.representedObject = volume.bsdName
            menu.addItem(forget)
        }
        return menu
    }

    /// The last ten things the extension had to say, newest first. Read
    /// from the file every time the menu is built: it is a few kilobytes,
    /// and a menu that caches it is a menu that is wrong after a replug.
    private func recentIssuesMenu() -> NSMenu {
        let menu = NSMenu()
        guard let dir = VolumeEventStore.directory(insideSandbox: false) else { return menu }
        let recent = VolumeEventStore.recent(VolumeEventStore.recentCount, in: dir).reversed()
        if recent.isEmpty {
            menu.addItem(withTitle: "No recent issues", action: nil, keyEquivalent: "").isEnabled = false
            return menu
        }
        for event in recent {
            let item = NSMenuItem(title: Ext4Events.oneLine(event), action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.toolTip = Ext4Events.describe(event)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Details: Ext4Mac last-error <disk>", action: nil,
                     keyEquivalent: "").isEnabled = false
        return menu
    }

    @objc private func unlockChosen(_ sender: NSMenuItem) {
        guard let bsd = sender.representedObject as? String,
              let volume = volumes[bsd] else { return }
        promptToUnlock(volume)
    }

    @objc private func mountChosen(_ sender: NSMenuItem) {
        guard let bsd = sender.representedObject as? String else { return }
        mount(bsdName: bsd)
    }

    @objc private func forgetChosen(_ sender: NSMenuItem) {
        guard let bsd = sender.representedObject as? String,
              let uuid = volumes[bsd]?.uuid else { return }
        // The result matters here too, but a menu is not a place to report
        // three outcomes: log the one that should not happen, and leave the
        // detailed answer to `Ext4Mac forget`, which a person can read.
        let result = Ext4Unlock.forget(uuid: uuid)
        if result.stillThere || result.keychainError != nil {
            NSLog("Ext4Mac: the key for %@ was not forgotten", uuid)
        }
        asked.remove(uuid)
        rebuildMenu()
    }

    @objc private func toggleOpenAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            report("Could not change the login item", "\(error.localizedDescription)")
        }
        rebuildMenu()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - Small UI helpers

    private func beginProgress(_ message: String) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 90),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Ext4Mac"
        let label = NSTextField(labelWithString: message)
        label.frame = NSRect(x: 20, y: 46, width: 300, height: 20)
        let spinner = NSProgressIndicator(frame: NSRect(x: 20, y: 18, width: 300, height: 20))
        spinner.style = .bar
        spinner.isIndeterminate = true
        spinner.startAnimation(nil)
        window.contentView?.addSubview(label)
        window.contentView?.addSubview(spinner)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return window
    }

    private func report(_ title: String, _ detail: String) {
        Ext4MenuBar.reportStatic(title, detail)
    }

    fileprivate static func reportStatic(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
