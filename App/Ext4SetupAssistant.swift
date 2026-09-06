//
//  Ext4SetupAssistant.swift — the first run, in one window
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  What this replaces: three NSAlerts that fired before the menu-bar icon even
//  existed, gave the same sentence to "registered but not approved" and "not
//  registered at all", gave up after two minutes in silence, and never showed
//  a person what a working install looks like.
//
//  What it does instead: one window that says what is still missing and does
//  each thing from a button; watches for the approval switch with a visible
//  countdown; mounts a real ext4 volume that ships inside the app so the user
//  sees the driver working in the Finder before risking a disk of their own;
//  and then points at the menu-bar icon, which is the whole interface.
//
//  It asks nothing that is already true, and it opens itself only when the
//  extension is not usable and this build has not been dismissed once
//  (Ext4Setup.launchDecision). Everything in it is reachable again from the
//  menu, so nothing here has to be a nag.
//

import SwiftUI
import AppKit

// MARK: - the steps

enum SetupStep: Int, CaseIterable, Identifiable {
    case welcome, approve, loginItem, notifications, diskUtility, tryIt, tour, done
    var id: Int { rawValue }

    /// The check this step is about, when it is about one.
    var check: SetupCheckID? {
        switch self {
        case .welcome: return .install
        case .approve: return .approve
        case .loginItem: return .loginItem
        case .notifications: return .notifications
        case .diskUtility: return .diskUtility
        case .tryIt: return .sample
        case .tour, .done: return nil
        }
    }

    var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .approve: return "Approve the extension"
        case .loginItem: return "Keep it working after a restart"
        case .notifications: return "Let Ext4Mac tell you things"
        case .diskUtility: return "Disk Utility (optional)"
        case .tryIt: return "Try it on a real volume"
        case .tour: return "Where Ext4Mac lives"
        case .done: return "Ready"
        }
    }

    /// Steps a person may pass over. The approval cannot be skipped because
    /// nothing works without it, and skipping it would leave the wizard
    /// claiming an install that mounts nothing.
    var isSkippable: Bool {
        switch self {
        case .loginItem, .notifications, .diskUtility, .tryIt: return true
        default: return false
        }
    }
}

// MARK: - the model

@MainActor
final class SetupAssistantModel: ObservableObject {
    @Published var step: SetupStep = .welcome
    @Published var checks: [SetupCheck] = []
    @Published var env = SetupEnvironment()
    @Published var busy: String? = nil
    @Published var message: String? = nil
    @Published var failure: String? = nil
    /// Seconds spent watching for the approval switch, so the wait is visible
    /// rather than silent -- the single worst part of the old flow.
    @Published var watching: Int? = nil
    @Published var sample: Ext4SampleVolume.Handle? = nil

    private var skipped: Set<SetupCheckID> = []
    private var watchTask: Task<Void, Never>? = nil

    /// Set by the menu-bar agent, which owns the status item the tour points
    /// at. Nil when the wizard is running without an agent (it cannot be,
    /// today, but the window must not depend on that).
    var runTour: ((@escaping () -> Void) -> Void)? = nil

    init() {
        skipped = Ext4Setup.skippedSteps()
    }

    func state(of id: SetupCheckID) -> SetupCheckState {
        checks.first { $0.id == id }?.state ?? .missing
    }

    func detail(of id: SetupCheckID) -> String {
        checks.first { $0.id == id }?.detail ?? ""
    }

    var isReady: Bool { state(of: .approve) == .ok }

    func refresh() async {
        env = await Ext4Setup.probe(interactive: true)
        checks = SetupChecklist.evaluate(env, skipped: skipped)
    }

    // MARK: navigation

    func advance() {
        failure = nil; message = nil
        let all = SetupStep.allCases
        guard let i = all.firstIndex(of: step), i + 1 < all.count else { return }
        step = all[i + 1]
        if step == .done { markComplete() }
    }

    func back() {
        failure = nil; message = nil
        let all = SetupStep.allCases
        guard let i = all.firstIndex(of: step), i > 0 else { return }
        step = all[i - 1]
    }

    func skip() {
        if let id = step.check {
            skipped.insert(id)
            var stored = Set(UserDefaults.standard.stringArray(forKey: Ext4Setup.Prefs.skippedSteps) ?? [])
            stored.insert(id.rawValue)
            UserDefaults.standard.set(Array(stored), forKey: Ext4Setup.Prefs.skippedSteps)
            // The login item's skip predates this window and is read by other
            // code; keep writing the key it already uses.
            if id == .loginItem {
                UserDefaults.standard.set(true, forKey: Ext4Setup.Prefs.declinedLoginItem)
            }
        }
        Task { await refresh() }
        advance()
    }

    private func markComplete() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                      as? String ?? "0.0.0"
        UserDefaults.standard.set(version, forKey: Ext4Setup.Prefs.completedVersion)
    }

    /// What to do when the window's close button is clicked.
    ///
    /// The last step is exempt: it already lists everything still outstanding
    /// and says where to come back to, so asking again on the way out of a
    /// screen the person has just read would be the wizard arguing with them.
    func closeDecision() -> SetupCloseDecision {
        if step == .done { return .close }
        return SetupChecklist.closeDecision(checks, sampleMounted: sample != nil)
    }

    /// Closing while the extension is still unapproved is an answer too: this
    /// build stops opening the window by itself, and the menu keeps the way
    /// back. Without this the wizard would greet every launch of a machine
    /// whose owner has decided to approve it later.
    func windowClosed() {
        watchTask?.cancel(); watchTask = nil
        if !isReady {
            let buildID = Bundle.main.object(forInfoDictionaryKey: "Ext4BuildID") as? String ?? "unknown"
            UserDefaults.standard.set(buildID, forKey: Ext4Setup.Prefs.dismissedForBuild)
        }
        Task { await Ext4SampleVolume.detachAll() }
    }

    // MARK: the actions behind the buttons

    func openSettings() {
        if !Ext4Setup.openSettingsPane() {
            failure = "System Settings would not open. Look for General → Login Items & Extensions → File System Extensions."
        }
        watchForApproval()
    }

    /// Watch the switch and say so while watching. Yields every two seconds
    /// for two minutes, then stops and leaves a Re-check button -- the old
    /// version stopped in silence, which reads exactly like a broken app.
    func watchForApproval() {
        watchTask?.cancel()
        watching = 0
        watchTask = Task { [weak self] in
            guard let self else { return }
            for await enabled in Ext4Setup.approvalStream() {
                if Task.isCancelled { break }
                self.watching = (self.watching ?? 0) + 2
                if enabled {
                    await self.refresh()
                    self.watching = nil
                    self.message = "ext4 is ready. Plug in an ext2, ext3 or ext4 drive and it will mount like any other disk."
                    return
                }
            }
            if !Task.isCancelled, self.watching != nil {
                self.watching = nil
                self.failure = """
                    Still not approved. The switch is in System Settings → General → \
                    Login Items & Extensions → File System Extensions, under “open_ext4 (ext2/3/4)”.
                    """
            }
        }
    }

    func recheck() async {
        busy = "Checking…"
        await refresh()
        busy = nil
        if step == .approve && isReady {
            message = "ext4 is ready. Plug in an ext2, ext3 or ext4 drive and it will mount like any other disk."
        }
    }

    func enableLoginItem() async {
        do {
            try Ext4Setup.setLoginItem(true)
            UserDefaults.standard.set(false, forKey: Ext4Setup.Prefs.declinedLoginItem)
            await refresh()
            if state(of: .loginItem) != .ok {
                failure = "macOS has the request but wants it confirmed in System Settings → General → Login Items."
            }
        } catch {
            failure = "Could not set the login item: \(error.localizedDescription)"
        }
    }

    func askForNotifications() async {
        busy = "Waiting for your answer…"
        _ = await Ext4Notifier.requestAuthorization()
        await refresh()
        busy = nil
        if state(of: .notifications) == .missing {
            failure = """
                Notifications are off for Ext4Mac. Turn them on in System Settings → \
                Notifications → Ext4Mac; without them, a locked encrypted volume is \
                reported only by `Ext4Mac status`.
                """
        }
    }

    func openNotificationSettings() {
        if let pane = Ext4Setup.notificationSettingsPane { NSWorkspace.shared.open(pane) }
    }

    func installDiskUtility() async {
        busy = "Waiting for the administrator prompt…"
        // osascript blocks until the person answers the prompt, so it must not
        // run on the main actor: the window would stop drawing behind it.
        let outcome = await Task.detached { Ext4DiskUtilityInstall.install() }.value
        busy = nil
        switch outcome {
        case .installed:
            await refresh()
            message = Ext4DiskUtilityInstall.diskUtilityListsExt()
                ? "ext2, ext3 and ext4 are in Disk Utility's Erase menu."
                : "Installed. Disk Utility lists it after its next launch."
        case .cancelled:
            message = nil          // a decision, not a failure
        case .failed(let why):
            failure = why
        case .unavailable(let why):
            failure = """
                \(why)

                You can do it from a terminal:

                \(Ext4DiskUtilityInstall.manualCommands())
                """
        }
    }

    func mountSample() async {
        failure = nil; message = nil
        let result = await Ext4SampleVolume.mount(reveal: true) { [weak self] phase in
            Task { @MainActor in self?.busy = phase.rawValue }
        }
        busy = nil
        switch result {
        case .success(let handle):
            sample = handle
            message = "Mounted at \(handle.mountPoint.path). It is in the Finder now — open it, copy something in. Eject it when you are done."
        case .failure(let why):
            failure = Ext4SampleVolume.advice(for: why)
        }
    }

    func ejectSample() async {
        guard let handle = sample else { return }
        busy = "Ejecting…"
        let stuck = await Ext4SampleVolume.detach(handle)
        busy = nil
        sample = nil
        if let stuck {
            failure = stuck
        } else {
            message = "Ejected. That is the habit worth keeping: eject before unplugging."
        }
    }

    func startTour() {
        guard let runTour else {
            failure = "Look for the drive icon in the menu bar at the top of the screen; it may be hidden behind the notch."
            return
        }
        busy = nil
        runTour { [weak self] in self?.advance() }
    }
}

// MARK: - the window

@MainActor
final class SetupAssistantWindowController: NSObject, NSWindowDelegate {
    static let shared = SetupAssistantWindowController()

    private var window: NSWindow?
    private(set) var model: SetupAssistantModel?

    /// Brings the existing window forward rather than opening a second one:
    /// the menu item and the launch decision can both ask for it.
    func show(runTour: ((@escaping () -> Void) -> Void)? = nil) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let model = SetupAssistantModel()
        model.runTour = runTour
        self.model = model

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Ext4Mac Setup"
        window.contentViewController = NSHostingController(rootView: SetupAssistantView(model: model))
        window.delegate = self
        window.center()
        window.isReleasedWhenClosed = false
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task { await model.refresh() }
    }

    var isOpen: Bool { window?.isVisible ?? false }

    /// Ask before closing an unfinished setup. The window stays closable --
    /// trapping someone in a wizard is worse than letting them leave -- but
    /// leaving it half done means an app that mounts nothing, or a sample
    /// volume that vanishes from under the Finder, and neither should happen
    /// without a word.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let model else { return true }
        guard case .confirm(let missing, let sampleMounted) = model.closeDecision() else {
            return true
        }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = missing.contains(SetupCheckID.approve.rawValue)
            ? "Ext4Mac will not mount anything yet"
            : "Finish setting up Ext4Mac?"

        var lines: [String] = []
        for id in missing {
            if let detail = model.checks.first(where: { $0.id.rawValue == id })?.detail {
                lines.append("• " + detail)
            }
        }
        if sampleMounted {
            lines.append("• The sample volume is still mounted and will be ejected.")
        }
        alert.informativeText = """
            Still to do:

            \(lines.joined(separator: "\n"))

            You can come back at any time from the menu-bar icon → Setup Assistant…
            """
        alert.addButton(withTitle: "Keep Setting Up")
        alert.addButton(withTitle: "Close Anyway")
        // The safe answer is the default one: a return key pressed out of
        // habit should not be what loses an unapproved install.
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() != .alertFirstButtonReturn
    }

    func windowWillClose(_ notification: Notification) {
        model?.windowClosed()
        window = nil
        model = nil
    }
}

// MARK: - the view

struct SetupAssistantView: View {
    @ObservedObject var model: SetupAssistantModel

    var body: some View {
        HStack(spacing: 0) {
            checklist
                .frame(width: 232)
                .background(Color(nsColor: .underPageBackgroundColor))
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(model.step.title).font(.title2).bold()
                        stepBody
                        if let busy = model.busy {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(busy).foregroundStyle(.secondary)
                            }
                        }
                        if let message = model.message {
                            banner(message, colour: .green, symbol: "checkmark.circle.fill")
                        }
                        if let failure = model.failure {
                            banner(failure, colour: .orange, symbol: "exclamationmark.triangle.fill")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
                }
                Divider()
                footer.padding(16)
            }
        }
        .frame(minWidth: 700, minHeight: 460)
        .task { await model.refresh() }
    }

    // The same list the `setup --check` verb prints, with dots.
    private var checklist: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Setup").font(.headline).padding(.bottom, 2)
            ForEach(SetupStep.allCases.filter { $0.check != nil }) { step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    dot(for: model.state(of: step.check!))
                    Text(step.title)
                        .font(.callout)
                        .fontWeight(step == model.step ? .semibold : .regular)
                        .foregroundStyle(step == model.step ? .primary : .secondary)
                }
            }
            Spacer()
            if model.state(of: .otherDriver) == .warn {
                Label(model.detail(of: .otherDriver), systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private func dot(for state: SetupCheckState) -> some View {
        let colour: Color
        switch state {
        case .ok: colour = .green
        case .missing: colour = Color(nsColor: .tertiaryLabelColor)
        case .skipped: colour = Color(nsColor: .quaternaryLabelColor)
        case .warn: colour = .orange
        }
        return Circle().fill(colour).frame(width: 9, height: 9)
    }

    private func banner(_ text: String, colour: Color, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(colour)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(colour.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: each step

    @ViewBuilder
    private var stepBody: some View {
        switch model.step {
        case .welcome:
            Text("""
                Ext4Mac lets macOS read and write ext2, ext3 and ext4 disks — the file \
                systems Linux uses — through Apple's own file system extension mechanism. \
                Plugged-in drives appear in the Finder like any other disk.

                This takes about a minute. Nothing here changes your disks.
                """)
            if model.state(of: .install) != .ok {
                banner(model.detail(of: .install), colour: .orange, symbol: "exclamationmark.triangle.fill")
                Button("Reveal Ext4Mac in the Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                }
            }

        case .approve:
            if model.isReady {
                Text("The extension is approved. macOS will hand every ext2, ext3 and ext4 volume to Ext4Mac.")
            } else {
                Text(model.detail(of: .approve))
                Text("""
                    macOS reserves this switch for a person at the keyboard — no app can \
                    turn it on, which is why nothing has asked until now. In the pane that \
                    opens, find **File System Extensions** and turn on **open_ext4 (ext2/3/4)**.
                    """)
                HStack {
                    Button("Open System Settings") { model.openSettings() }
                        .buttonStyle(.borderedProminent)
                    if model.env.registered == false {
                        Button("Quit and Reopen from Applications") {
                            let path = "/Applications/Ext4Mac.app"
                            if FileManager.default.fileExists(atPath: path) {
                                NSWorkspace.shared.open(URL(fileURLWithPath: path))
                            }
                            NSApp.terminate(nil)
                        }
                    }
                }
                if let watching = model.watching {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Watching for the switch… (\(watching) s)").foregroundStyle(.secondary)
                    }
                }
            }

        case .loginItem:
            Text("""
                macOS registers a file system extension while its app is running. After a \
                restart the module is absent from System Settings — not switched off, \
                absent — until Ext4Mac runs again. Starting at login is what makes the \
                approval stick.
                """)
            if model.state(of: .loginItem) == .ok {
                Text("Ext4Mac starts at login.").foregroundStyle(.secondary)
            } else {
                Button("Start at Login") { Task { await model.enableLoginItem() } }
                    .buttonStyle(.borderedProminent)
            }

        case .notifications:
            Text("""
                When a volume cannot be mounted, Ext4Mac writes down why and says so. \
                Without notifications, a locked encrypted volume is reported only by \
                `Ext4Mac status` in a terminal.
                """)
            if model.state(of: .notifications) == .ok {
                Text("Notifications are allowed.").foregroundStyle(.secondary)
            } else {
                HStack {
                    Button("Allow Notifications") { Task { await model.askForNotifications() } }
                        .buttonStyle(.borderedProminent)
                    Button("Open Notification Settings") { model.openNotificationSettings() }
                }
            }

        case .diskUtility:
            Text("""
                Adds ext2, ext3 and ext4 to Disk Utility's Erase menu and to \
                `diskutil listFilesystems`. The formatting is still done by the \
                extension; this only makes it selectable.

                Worth knowing: erasing a physical disk as ext4 from Disk Utility needs \
                an administrator — macOS refuses it for anyone else with error −69832 — \
                and Disk Utility labels the result “EXT2”. You can remove this at any \
                time from this window.
                """)
            if model.state(of: .diskUtility) == .ok {
                Text("Installed in /Library/Filesystems/ext4.fs.").foregroundStyle(.secondary)
            } else {
                Button("Add to Disk Utility…") { Task { await model.installDiskUtility() } }
                    .buttonStyle(.borderedProminent)
            }

        case .tryIt:
            Text("""
                Ext4Mac carries a small ext4 volume of its own. Mounting it uses exactly \
                the path a plugged-in disk takes, so if it appears in the Finder, the \
                install works.
                """)
            if !model.isReady {
                banner("Approve the extension first — nothing can mount an ext4 volume until then.",
                       colour: .orange, symbol: "exclamationmark.triangle.fill")
                Button("Back to the approval step") { model.step = .approve }
            } else if model.sample != nil {
                Button("Eject the sample volume") { Task { await model.ejectSample() } }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Mount the sample volume") { Task { await model.mountSample() } }
                    .buttonStyle(.borderedProminent)
            }

        case .tour:
            Text("""
                Ext4Mac has no window of its own. It lives in the menu bar, at the top of \
                the screen: attached encrypted volumes, what the extension last refused \
                and why, and the way back to this window.
                """)
            Button("Show me") { model.startTour() }
                .buttonStyle(.borderedProminent)

        case .done:
            if model.isReady {
                Text("""
                    Ext4Mac is ready. Plug in an ext2, ext3 or ext4 drive and it will mount \
                    like any other disk.

                    One habit worth keeping: eject before unplugging. macOS gives a file \
                    system extension no way to flush a drive's own cache, so a disk pulled \
                    mid-write is the one thing that can still cost data.
                    """)
            } else {
                Text("Ext4Mac will not mount anything until the extension is approved.")
            }
            let unfinished = model.checks.filter { $0.state == .missing || $0.state == .skipped }
            if !unfinished.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Left for later").font(.headline)
                    ForEach(unfinished, id: \.id.rawValue) { check in
                        Text("• " + check.detail).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("You can come back from the menu-bar icon → Setup Assistant…")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if model.step != .welcome {
                Button("Back") { model.back() }
            }
            Button("Re-check") { Task { await model.recheck() } }
            Spacer()
            if model.step.isSkippable {
                Button("Skip") { model.skip() }
            }
            if model.step == .done {
                Button("Finish") { NSApp.keyWindow?.performClose(nil) }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Continue") { model.advance() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
