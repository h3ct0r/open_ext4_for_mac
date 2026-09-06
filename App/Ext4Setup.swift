//
//  Ext4Setup.swift — first-run checks for a distributed build
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Two switches stand between a fresh install and a working ext4 volume, and
//  they fail in different ways.
//
//  The File System Extension has to be approved in System Settings. macOS
//  reserves that for a person at the keyboard: no entitlement grants it, and
//  an app that could flip it would be a hole in the sandbox. What an app can
//  do is notice, explain, and open the exact pane -- which is worth doing,
//  because the failure is silent. Nothing says "approve me"; volumes simply
//  do not mount.
//
//  The login item can be set programmatically, and matters more than it
//  looks. An ExtensionKit extension is registered by its containing app
//  RUNNING, so a reboot leaves the module absent from System Settings
//  entirely -- not switched off, absent -- until something launches the app
//  again. Observed twice in one day on the development machine, both times
//  read as a broken install. Starting at login is what makes the approval
//  stick.
//
//  So this runs once at launch, asks for nothing that is already true, and
//  says plainly which of the two is missing.
//

import Foundation
import AppKit
import UserNotifications
import FSKit
import ServiceManagement
import os

enum Ext4Setup {
    private static let log = Logger(subsystem: "dev.h3ct0r.ext4", category: "setup")
    private static let modulePrefix = "dev.h3ct0r.ext4mac"
    private static let declinedLoginItemKey = "Ext4SetupDeclinedLoginItem"

    /// The pane that holds File System Extensions, by its own identifier
    /// rather than a guessed URL: com.apple.LoginItems-Settings.extension is
    /// what ships in /System/Library/ExtensionKit/Extensions.
    private static let settingsPane =
        URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")

    /// Is our module registered with FSKit, and has the user approved it?
    static func extensionState() async -> (registered: Bool, enabled: Bool) {
        do {
            let installed = try await FSClient.shared.installedExtensions
            let ours = installed.filter { $0.bundleIdentifier.hasPrefix(modulePrefix) }
            return (!ours.isEmpty, ours.contains { $0.isEnabled })
        } catch {
            log.error("could not ask FSKit: \(error.localizedDescription, privacy: .public)")
            return (false, false)
        }
    }

    /// Called once at launch. Silent when both switches are already set.
    static func runAtLaunch() {
        Task { @MainActor in
            let (registered, enabled) = await extensionState()

            // Registration is this app's own doing: it happened by launching.
            // Keeping it across reboots is what the login item buys, so offer
            // it in the same breath as the approval rather than as a second
            // interruption later.
            let loginItemOn = SMAppService.mainApp.status == .enabled

            if enabled && loginItemOn {
                log.info("extension enabled and set to start at login; nothing to ask")
                return
            }
            if enabled && !loginItemOn {
                // Asked once. A person who declines has decided, and a
                // question re-asked at every launch stops being a question
                // and becomes a nag -- the surest way to have it dismissed
                // without reading. The menu keeps the toggle for later.
                if !UserDefaults.standard.bool(forKey: declinedLoginItemKey) {
                    offerLoginItem()
                }
                return
            }
            offerApproval(registered: registered, loginItemOn: loginItemOn)
        }
    }

    @MainActor
    private static func offerApproval(registered: Bool, loginItemOn: Bool) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "One step left before ext4 volumes will mount"
        alert.informativeText = """
            macOS needs you to approve the file system extension by hand — no \
            app can do it for you, which is why nothing has prompted until now.

            In the pane that opens, turn on “open_ext4 (ext2/3/4)” under \
            File System Extensions.
            """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")

        if !loginItemOn {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Also start Ext4Mac at login (recommended)"
            alert.suppressionButton?.state = .on
        }

        let choice = alert.runModal()
        let wantsLoginItem = alert.suppressionButton?.state == .on

        if !loginItemOn && wantsLoginItem { enableLoginItem() }

        guard choice == .alertFirstButtonReturn, let pane = settingsPane else { return }
        NSWorkspace.shared.open(pane)
        waitForApproval()
    }

    @MainActor
    private static func offerLoginItem() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Keep ext4 working after a restart?"
        alert.informativeText = """
            The extension is registered only while Ext4Mac has run. After a \
            reboot it disappears from System Settings until the app is opened \
            again — starting Ext4Mac at login keeps it available.

            Without the agent running, a locked encrypted volume is reported \
            only by `Ext4Mac status`, not as a notification.
            """
        alert.addButton(withTitle: "Start at Login")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn {
            enableLoginItem()
        } else {
            UserDefaults.standard.set(true, forKey: declinedLoginItemKey)
        }
    }

    private static func enableLoginItem() {
        do {
            try SMAppService.mainApp.register()
            log.info("registered as a login item")
        } catch {
            log.error("could not register a login item: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Watch for the approval and confirm it, so the user is not left
    /// wondering whether the switch they just flipped was the right one.
    /// Gives up quietly: an unanswered question is not an error.
    @MainActor
    private static func waitForApproval() {
        Task { @MainActor in
            for _ in 0..<60 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if await extensionState().enabled {
                    let done = NSAlert()
                    done.alertStyle = .informational
                    done.messageText = "ext4 is ready"
                    done.informativeText =
                        "Plug in an ext2, ext3 or ext4 drive and it will mount like any other disk."
                    done.addButton(withTitle: "OK")
                    done.runModal()
                    return
                }
            }
            log.info("approval not granted within the watch window")
        }
    }
}

// MARK: - the facts, from this machine
//
// One owner for probing and persistence. These were copied into three places
// (the menu bar's toggle, the `login-item` verb, the alert flow above), and
// three copies of a rule is three chances to disagree about it.

extension Ext4Setup {
    /// UserDefaults keys, named once. `Ext4SetupDeclinedLoginItem` predates
    /// the wizard and keeps its meaning: the user was asked and said no.
    enum Prefs {
        static let completedVersion = "Ext4SetupCompletedVersion"
        static let skippedSteps = "Ext4SetupSkippedSteps"
        static let declinedLoginItem = "Ext4SetupDeclinedLoginItem"
        static let dismissedForBuild = "Ext4SetupDismissedForBuild"
    }

    static func loginItemEnabled() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setLoginItem(_ on: Bool) throws {
        if on {
            try SMAppService.mainApp.register()
            log.info("registered as a login item")
        } else {
            try SMAppService.mainApp.unregister()
            log.info("unregistered as a login item")
        }
    }

    /// Opens the pane that holds File System Extensions. Returns false if the
    /// URL scheme is refused, so a caller can say so instead of appearing to
    /// have done something.
    @discardableResult
    static func openSettingsPane() -> Bool {
        guard let pane = settingsPane else { return false }
        return NSWorkspace.shared.open(pane)
    }

    static let notificationSettingsPane =
        URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")

    /// Notification permission, when there is an application object to ask on
    /// behalf of. `UNUserNotificationCenter` belongs to a running app; from a
    /// command line there is no supported way to read it, and `unknown` is
    /// the honest answer rather than a guessed one.
    @MainActor
    static func notificationStatus() async -> SetupNotifyState {
        guard NSApp != nil, Bundle.main.bundleIdentifier != nil else { return .unknown }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized: return .authorized
        case .provisional: return .provisional
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .unknown
        }
    }

    /// Everything the checklist needs, from this Mac.
    ///
    /// `interactive` is asked for, not inferred: notification permission can
    /// only be read on the main actor, and the command line reaches this by
    /// blocking the main thread on a semaphore -- so a probe that decided for
    /// itself whether to ask deadlocked `Ext4Mac setup --check` outright.
    /// The wizard, which has a run loop, passes true.
    static func probe(interactive: Bool = false) async -> SetupEnvironment {
        var env = SetupEnvironment.fromDisk()
        let state = await extensionState()
        env.registered = state.registered
        env.enabled = state.enabled
        env.loginItem = loginItemEnabled()
        env.notifications = interactive ? await notificationStatus() : .unknown
        return env
    }

    static func skippedSteps() -> Set<SetupCheckID> {
        var ids = Set((UserDefaults.standard.stringArray(forKey: Prefs.skippedSteps) ?? [])
                        .compactMap(SetupCheckID.init(rawValue:)))
        if UserDefaults.standard.bool(forKey: Prefs.declinedLoginItem) { ids.insert(.loginItem) }
        return ids
    }

    /// Watch for the approval switch. A stream rather than a wait, so the
    /// wizard can show a countdown and the person can see that something is
    /// still looking -- the old version gave up after two minutes in silence.
    /// Yields false on every poll that is still unapproved, true once, then
    /// finishes.
    static func approvalStream(every seconds: UInt64 = 2,
                               maxTries: Int = 60) -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let task = Task {
                for _ in 0..<maxTries {
                    try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                    if Task.isCancelled { break }
                    let enabled = await extensionState().enabled
                    continuation.yield(enabled)
                    if enabled { break }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Why the Setup Assistant would open at launch, if it should at all.
    enum LaunchDecision {
        case quiet
        case open(reason: String)
    }

    /// Opening a window at every launch is a nag; never opening it leaves a
    /// broken install with no way back. The rule: open when the extension is
    /// not usable and this build has not already been dismissed once.
    static func launchDecision() async -> LaunchDecision {
        let defaults = UserDefaults.standard
        let buildID = Bundle.main.object(forInfoDictionaryKey: "Ext4BuildID") as? String ?? "unknown"
        if await extensionState().enabled {
            // A working install that never saw a wizard has nothing to be
            // walked through. Record it so a later upgrade is not treated as
            // a first run.
            if defaults.string(forKey: Prefs.completedVersion) == nil {
                let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                              as? String ?? "0.0.0"
                defaults.set(version, forKey: Prefs.completedVersion)
            }
            return .quiet
        }
        if defaults.string(forKey: Prefs.dismissedForBuild) == buildID { return .quiet }
        return .open(reason: "the file system extension is not approved yet")
    }
}
