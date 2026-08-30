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
