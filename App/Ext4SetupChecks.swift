//
//  Ext4SetupChecks.swift — what stands between a fresh install and a mount
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  The first run of Ext4Mac is a checklist. Is the app in /Applications, is
//  the extension registered, has a person approved it, does the app start at
//  login, may it post a notification, is Disk Utility integration in place,
//  is there a sample volume to prove all of it with, and is another ext
//  driver installed that might claim the disk first.
//
//  All of that is decided here, with no window and no AppKit, from a value
//  struct of facts. The wizard fills the struct from the machine; the test
//  suite fills it from the command line (`--given registered=1 enabled=0`),
//  which is the only way to see every state the wizard can show without
//  breaking this Mac to produce them.
//
//  The distinction the old NSAlert flow could not make is the reason this
//  exists: "registered, not approved" and "not registered" look identical to
//  a user (no volume mounts) and need opposite next steps -- flip a switch,
//  versus launch the app so the switch appears at all.
//

import Foundation

// MARK: - the facts

/// What macOS lets us know about notification permission. `unknown` is real:
/// asking from a command line, with no application object running, is not
/// something UserNotifications supports, and inventing an answer there would
/// be worse than admitting it.
enum SetupNotifyState: String {
    case authorized, provisional, denied, notDetermined, unknown
}

/// Everything the checklist reads, and nothing else. No probing lives in the
/// checks themselves, so a check is a pure function of this struct.
struct SetupEnvironment {
    var bundlePath: String = ""
    var registered: Bool = false
    var enabled: Bool = false
    var loginItem: Bool = false
    var notifications: SetupNotifyState = .unknown
    var diskUtility: Bool = false
    /// The name of another ext driver found on this Mac, if any.
    var otherDriver: String? = nil
    var sample: Bool = false
}

// MARK: - the checks

enum SetupCheckID: String, CaseIterable {
    case install, approve, loginItem, notifications, diskUtility, sample, otherDriver
}

/// `warn` is not a failure: it is something worth saying that must not stop
/// a person from finishing the wizard. `skipped` is a decision they made.
enum SetupCheckState: String {
    case ok, missing, skipped, warn
}

struct SetupCheck {
    let id: SetupCheckID
    let state: SetupCheckState
    let detail: String
    /// What the wizard offers to do about it, when there is something to do.
    let action: String?

    init(_ id: SetupCheckID, _ state: SetupCheckState, _ detail: String, action: String? = nil) {
        self.id = id; self.state = state; self.detail = detail; self.action = action
    }
}

enum SetupChecklist {
    static func evaluate(_ env: SetupEnvironment,
                         skipped: Set<SetupCheckID> = []) -> [SetupCheck] {
        var out: [SetupCheck] = []
        func add(_ id: SetupCheckID, _ state: SetupCheckState,
                 _ detail: String, action: String? = nil) {
            // A skip only applies to something that would otherwise be
            // missing. Skipping a step that is already done would report a
            // working install as unfinished.
            if state == .missing && skipped.contains(id) {
                out.append(SetupCheck(id, .skipped, detail + " (skipped)"))
            } else {
                out.append(SetupCheck(id, state, detail, action: action))
            }
        }

        // Where the app runs from. macOS registers an extension from the
        // bundle it launched, so a copy left in Downloads registers a module
        // that vanishes the moment the disk image is ejected or the file is
        // moved.
        if env.bundlePath == "/Applications/\(SetupPaths.appName)" {
            add(.install, .ok, "Ext4Mac is in /Applications")
        } else {
            add(.install, .missing,
                "Ext4Mac is running from \(env.bundlePath.isEmpty ? "an unknown place" : env.bundlePath) — move it to /Applications and open it again",
                action: "Reveal in Finder")
        }

        // The one switch no app may flip for itself, and the two ways it can
        // be unset.
        switch (env.registered, env.enabled) {
        case (_, true):
            add(.approve, .ok, "the file system extension is approved and enabled")
        case (true, false):
            add(.approve, .missing,
                "registered, not approved — turn on “open_ext4 (ext2/3/4)” under File System Extensions",
                action: "Open System Settings")
        case (false, false):
            add(.approve, .missing,
                "not registered — the extension is absent from System Settings, not switched off; open Ext4Mac from /Applications so macOS registers it",
                action: "Open System Settings")
        }

        // Registration lasts only as long as something has launched the app,
        // so after a reboot the module is absent until it runs again.
        add(.loginItem,
            env.loginItem ? .ok : .missing,
            env.loginItem
                ? "Ext4Mac starts at login, so the extension stays registered across reboots"
                : "not set to start at login — after a restart the extension will be missing until Ext4Mac runs",
            action: "Start at Login")

        switch env.notifications {
        case .authorized, .provisional:
            add(.notifications, .ok, "Ext4Mac may tell you when a volume needs attention")
        case .denied:
            add(.notifications, .missing,
                "notifications are denied — a locked encrypted volume would be reported only by `Ext4Mac status`",
                action: "Open Notification Settings")
        case .notDetermined:
            add(.notifications, .missing,
                "not asked yet — without notifications, a locked encrypted volume is reported only by `Ext4Mac status`",
                action: "Allow Notifications")
        case .unknown:
            add(.notifications, .warn,
                "not readable from a command line; the Setup Assistant asks for it")
        }

        add(.diskUtility,
            env.diskUtility ? .ok : .missing,
            env.diskUtility
                ? "ext2, ext3 and ext4 are in Disk Utility's Erase menu"
                : "optional — add ext2/3/4 to Disk Utility's Erase menu and to `diskutil listFilesystems`",
            action: "Add to Disk Utility…")

        add(.sample,
            env.sample ? .ok : .missing,
            env.sample
                ? "a sample ext4 volume is in the app bundle, ready to mount"
                : "the sample volume is missing from this build, so the wizard cannot demonstrate a mount")

        // Not a failure in either direction. Both drivers were installed
        // together on 2026-09-05 and ours won the probe; saying so beats a
        // silent race nobody knows about.
        if let other = env.otherDriver {
            add(.otherDriver, .warn,
                "\(other) is also installed and may claim an ext volume before Ext4Mac does")
        } else {
            add(.otherDriver, .ok, "no other ext file system driver is installed")
        }
        return out
    }

    /// 0 when nothing is missing, 1 when something is. `warn` and `skipped`
    /// do not fail: they are things said, and things decided.
    static func exitCode(_ checks: [SetupCheck]) -> Int32 {
        checks.contains { $0.state == .missing } ? 1 : 0
    }

    /// One line per check, state first, so a reader (or a test cell) can look
    /// for "ok install" without knowing how the detail is worded.
    static func text(_ checks: [SetupCheck]) -> String {
        checks.map { check in
            let state = check.state.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)
            let id = check.id.rawValue.padding(toLength: 14, withPad: " ", startingAt: 0)
            return "\(state)\(id)\(check.detail)"
        }.joined(separator: "\n")
    }

    static func json(_ checks: [SetupCheck]) -> String {
        let rows: [[String: String]] = checks.map {
            var row = ["id": $0.id.rawValue, "state": $0.state.rawValue, "detail": $0.detail]
            if let action = $0.action { row["action"] = action }
            return row
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rows,
                                                     options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "[]" }
        return s
    }
}

// MARK: - facts from the command line

enum SetupPaths {
    static let appName = "Ext4Mac.app"
    static let diskUtilityBundle = "/Library/Filesystems/ext4.fs"
    /// Other ext drivers, by the bundle each one installs. Paragon's is the
    /// one seen in the wild; the rest are here so the message names them
    /// rather than saying "something".
    static let otherDrivers: [(path: String, name: String)] = [
        ("/Library/Filesystems/ufsd_ExtFS.fs", "Paragon ExtFS"),
        ("/Library/Filesystems/extfs.fs", "Paragon extFS"),
        ("/Library/Filesystems/fuse-ext2.fs", "fuse-ext2"),
        ("/Library/Filesystems/macfuse.fs", "macFUSE (with an ext plugin)"),
    ]
}

extension SetupEnvironment {
    /// A parse error names the key, because the point of `--given` is to be
    /// exact and a typo that silently reads the machine instead would make a
    /// test cell pass for the wrong reason.
    struct GivenError: Error { let message: String }

    /// `--given bundle=/Applications/Ext4Mac.app registered=1 enabled=0 …`
    /// Later assignments win, so a base set can be overridden one key at a
    /// time.
    static func parse(given: [String], base: SetupEnvironment = SetupEnvironment()) throws -> SetupEnvironment {
        var env = base
        for pair in given {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else {
                throw GivenError(message: "--given wants key=value, not '\(pair)'")
            }
            let (key, value) = (parts[0], parts[1])
            func flag() throws -> Bool {
                switch value.lowercased() {
                case "1", "true", "yes", "on": return true
                case "0", "false", "no", "off": return false
                default: throw GivenError(message: "\(key)=\(value) is not a yes/no value")
                }
            }
            switch key {
            case "bundle":     env.bundlePath = value
            case "registered": env.registered = try flag()
            case "enabled":    env.enabled = try flag()
            case "login":      env.loginItem = try flag()
            case "diskutil":   env.diskUtility = try flag()
            case "sample":     env.sample = try flag()
            case "other":
                env.otherDriver = try flag() ? SetupPaths.otherDrivers[0].name : nil
            case "notify":
                guard let state = SetupNotifyState(rawValue: value) else {
                    throw GivenError(message: "notify=\(value) is not one of "
                        + "authorized, provisional, denied, notDetermined, unknown")
                }
                env.notifications = state
            default:
                throw GivenError(message: "unknown --given key '\(key)'")
            }
        }
        return env
    }

    /// The parts that need no FSKit call, no AppKit and no run loop.
    static func fromDisk() -> SetupEnvironment {
        var env = SetupEnvironment()
        env.bundlePath = Bundle.main.bundleURL.path
        env.diskUtility = FileManager.default.fileExists(
            atPath: SetupPaths.diskUtilityBundle + "/Contents/Info.plist")
        env.otherDriver = SetupPaths.otherDrivers.first {
            FileManager.default.fileExists(atPath: $0.path)
        }?.name
        env.sample = FileManager.default.fileExists(atPath: SetupSample.imagePath ?? "")
        return env
    }
}

/// Where the bundled demonstration volume lives. One place, because the
/// wizard, the selftest and the build all have to agree on it.
enum SetupSample {
    static let resourceName = "Ext4Mac-Sample"
    static let resourceExtension = "img"
    static let volumeLabel = "Ext4Mac Sample"

    static var imagePath: String? {
        Bundle.main.url(forResource: resourceName, withExtension: resourceExtension)?.path
    }
}

// MARK: - closing before it is finished

/// What should happen when someone closes the Setup Assistant window.
///
/// The window is closable at any point, deliberately -- a wizard that traps a
/// person is worse than one they abandon. But closing it while the extension
/// is still unapproved silently leaves an app that mounts nothing, and closing
/// it while the sample volume is mounted takes the volume away underneath the
/// Finder. Both are worth one question.
enum SetupCloseDecision: Equatable {
    case close
    case confirm(missing: [String], sampleMounted: Bool)
}

extension SetupChecklist {
    /// Confirm only when something is actually unfinished. A step the person
    /// chose to skip is finished as far as they are concerned, and a warning
    /// is something said, not something owed -- neither earns a dialog.
    static func closeDecision(_ checks: [SetupCheck],
                              sampleMounted: Bool = false) -> SetupCloseDecision {
        let missing = checks.filter { $0.state == .missing }
        if missing.isEmpty && !sampleMounted { return .close }
        return .confirm(missing: missing.map(\.id.rawValue), sampleMounted: sampleMounted)
    }
}
