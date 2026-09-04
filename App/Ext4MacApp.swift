//
//  Ext4MacApp.swift — container app for the ext4 FSKit extension
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  macOS discovers FSKit modules through an installed application bundle, so
//  the extension has to ship inside one. This app deliberately does very
//  little: it reports whether the extension is registered and enabled, and
//  points the user at the System Settings pane where they turn it on.
//

import Foundation
import ServiceManagement
import FSKit

@main
struct Ext4MacApp {
    static func main() {
        var arguments = Array(CommandLine.arguments.dropFirst())

        // With no arguments this is either someone typing `Ext4Mac`, who wants
        // to know whether the extension is working, or Finder opening the app,
        // which means they want the agent. The parent process tells them
        // apart: LaunchServices hands an app to launchd, so a Finder launch is
        // reparented to pid 1, while anything started from a shell or a script
        // keeps that shell as its parent.
        //
        // Deliberately not `isatty`, which was tried and is wrong: it makes
        // any script that captures the output get the agent instead, and the
        // agent never returns. scripts/check_extension.sh hung on exactly that.
        let launchedByLaunchServices = getppid() == 1
        let command = arguments.isEmpty
            ? (launchedByLaunchServices ? "menu" : "status")
            : arguments.removeFirst()

        switch command {
        case "status":
            statusSynchronously()

        // Watch for encrypted volumes and ask when one turns up. Never
        // returns; this is the app's main run loop.
        case "menu", "watch":
            Ext4MenuBar.run()

        // Encrypted volumes. The passphrase is handled here and nowhere else:
        // the extension is sandboxed, cannot prompt, and would pay for the key
        // derivation once per resource load.
        case "unlock":
            guard let device = arguments.first else { usage(1) }
            exit(Ext4Unlock.unlock(devicePath: device))
        case "forget":
            guard let which = arguments.first else { usage(1) }
            if which == "--all" {
                exit(Ext4Unlock.forgetAll(confirmed: arguments.contains("--yes")))
            }
            exit(Ext4Unlock.forget(which))
        case "list":
            exit(Ext4Unlock.list())

        // What the extension had to say about a volume. It cannot say it
        // itself: no window, no notification, and one FSKit sentence for every
        // way a mount can fail.
        case "last-error":
            exit(Ext4Events.lastError(arguments))
        case "events":
            exit(Ext4Events.events(arguments))
        case "mount":
            guard let device = arguments.first else { usage(1) }
            exit(Ext4Mount.command(device))

        // Whether the app starts at login, which is what keeps the FILE SYSTEM
        // EXTENSION registered.
        //
        // An ExtensionKit extension is registered by its containing app
        // running -- not by installing it, and not by pluginkit, which
        // reports success and registers it somewhere FSKit never looks. So a
        // reboot leaves the module absent from System Settings entirely (not
        // switched off: absent) until something launches the app. Making the
        // app a login item is the only fix that survives a restart, and it
        // was reachable solely from the menu bar, which is no use to a script
        // or to anyone whose extension has just vanished.
        case "login-item":
            let action = arguments.first ?? "status"
            switch action {
            case "on":
                do {
                    try SMAppService.mainApp.register()
                    print("Ext4Mac will start at login; the extension stays registered across reboots")
                } catch {
                    FileHandle.standardError.write(
                        "Ext4Mac: could not enable: \(error.localizedDescription)\n".data(using: .utf8)!)
                    exit(1)
                }
            case "off":
                do {
                    try SMAppService.mainApp.unregister()
                    print("Ext4Mac will no longer start at login")
                    print("note: after a reboot the extension will be missing until the app runs")
                } catch {
                    FileHandle.standardError.write(
                        "Ext4Mac: could not disable: \(error.localizedDescription)\n".data(using: .utf8)!)
                    exit(1)
                }
            case "status":
                let on = SMAppService.mainApp.status == .enabled
                print(on ? "enabled — starts at login" : "disabled — the extension will be missing after a reboot")
                exit(on ? 0 : 1)
            default:
                usage(1)
            }
            exit(0)

        // Checks this build can make about itself, with no disk, no volume
        // and nothing installed. Today that is one thing, and it is one thing
        // worth being able to ask: is key material actually locked into
        // memory on this machine, or did the kernel decline and nobody
        // noticed? mlock is best-effort by design, so "it is supposed to be"
        // and "it is" are different statements.
        //
        // Documented rather than hidden. A diagnostic somebody has to be told
        // about is a diagnostic nobody runs.
        case "selftest":
            exit(selftest())

        case "version", "--version", "-v":
            // Which source the installed bundles were built from. The point is
            // to answer "is the thing on disk today's code?" without inference:
            // a stale extension has cost three debugging sessions, once via a
            // log line that read exactly like the new build and was not.
            let appID = Bundle.main.object(forInfoDictionaryKey: "Ext4BuildID")
                        as? String ?? "unknown"
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                          as? String ?? "0.0.0"
            let buildNo = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")
                          as? String ?? "0"
            // Three numbers, three questions. The version is what a release is
            // called; the build number is how many commits it is on; the build
            // id is which commit, and whether the tree was dirty. 0.0.0 means
            // the bundle was copied out of the source tree and never built.
            print("version:   \(version) (build \(buildNo))")
            print("app:       \(appID)")
            print("bundle:    \(Bundle.main.bundleURL.path)")

            // ExtensionKit puts the appex under Contents/Extensions, not
            // Contents/PlugIns, so builtInPlugInsURL does not find it.
            let extDir = Bundle.main.bundleURL
                .appendingPathComponent("Contents/Extensions")
            let appexes = (try? FileManager.default.contentsOfDirectory(
                                at: extDir, includingPropertiesForKeys: nil)) ?? []
            if appexes.isEmpty {
                print("extension: none found in \(extDir.path)")
            }
            for appex in appexes where appex.pathExtension == "appex" {
                let id = Bundle(url: appex)?
                            .object(forInfoDictionaryKey: "Ext4BuildID")
                         as? String ?? "unknown"
                print("extension: \(id)  (\(appex.lastPathComponent))")
            }
            print("")
            print("A running extension keeps serving a mounted volume from the")
            print("binary it started with, so installing a new bundle does not")
            print("replace it until the volume is ejected and re-attached.")
            exit(0)

        case "help", "-h", "--help":
            usage(0)
        default:
            FileHandle.standardError.write("Ext4Mac: unknown command '\(command)'\n".data(using: .utf8)!)
            usage(1)
        }
    }

    /// Returns 0 if everything this build can check about itself holds.
    static func selftest() -> Int32 {
        var failed = 0
        var passedCount = 0
        func check(_ what: String, _ passed: Bool, _ detail: String = "") {
            if passed {
                passedCount += 1
                print("  ok    \(what)")
            } else {
                failed += 1
                print("  FAIL  \(what)")
                if !detail.isEmpty { print("        \(detail)") }
            }
        }

        print("Ext4Mac selftest")
        print("")

        // A passphrase lives in one of these for as long as argon2id takes to
        // derive from it -- a second or two of deliberately heavy memory
        // traffic, which is exactly when something gets evicted to swap. A
        // swap file is on a disk and survives the machine being switched off,
        // and the wipe in deinit does nothing whatsoever for a copy the kernel
        // made while we were not looking.
        let secret = SecureBytes(utf8: "correct horse battery staple")
        // Asks, not granted. A build that never calls mlock is the regression
        // (red under -DLUKS_NO_MLOCK); a kernel that refuses is this machine's
        // RLIMIT_MEMLOCK, and the decision on record is that the volume opens
        // anyway -- so that is reported, not failed. The first version of this
        // cell went red under `ulimit -l 0` with the code entirely correct.
        check("key material asks to be locked into memory, not swappable",
              SecureBytes.lockAttempted,
              "this build never calls mlock (LUKS_NO_MLOCK)")
        if SecureBytes.lockAttempted && !secret.isLocked {
            print("        (asked, and this host refused: RLIMIT_MEMLOCK)")
        }
        check("and it holds what was put in it", secret.count == 28,
              "count is \(secret.count)")

        // Forgetting a key has to be checkable, because the verb that does it
        // used to report success without looking. A round trip on a UUID no
        // volume will ever have: store, see it, forget it, see it gone, and
        // then forget it again and get a different answer -- because "there
        // was nothing here" and "there was something and it is gone" are
        // different facts and only one of them is what the user asked for.
        //
        // Cleans up after itself even when it fails. This runs against the
        // real keychain; leaving a key behind is exactly the thing being
        // fixed.
        let probeUUID = "ffffffff-ffff-ffff-ffff-ffffffffffff"
        defer { _ = try? LUKSKeychain.remove(uuid: probeUUID) }
        do {
            let key = [UInt8](repeating: 0xA5, count: 64)
            try LUKSKeychain.store(masterKey: key, uuid: probeUUID, label: "Ext4Mac selftest")
            check("a key can be stored and read back", LUKSKeychain.hasKey(uuid: probeUUID))

            let first = try LUKSKeychain.remove(uuid: probeUUID)
            check("forgetting one that is there reports it deleted",
                  first == .deleted, "reported \(first.rawValue)")
            check("and it really is gone", !LUKSKeychain.hasKey(uuid: probeUUID))

            let second = try LUKSKeychain.remove(uuid: probeUUID)
            check("forgetting one that is not there does not claim to have deleted it",
                  second == .notVisible, "reported \(second.rawValue)")
        } catch {
            // An unsigned build has its own view of the keychain and may not
            // be allowed to write to it at all. That is a fact about this
            // binary, not a failure of the code under test, and saying so is
            // more useful than a red cell nobody can act on.
            print("  ----  the keychain round trip did not run: \(error.localizedDescription)")
            print("        (an unsigned build may not be permitted to store items)")
        }

        // The same last line every suite in this project prints, so the CI
        // summary counts these assertions instead of showing a dash.
        // `forget --all` deletes every key this build can see, in two places
        // that fail independently. The first time it ran it took nine key
        // files out of the extension's container while every keychain item
        // stayed put, and then printed "forgot 0 of 9" -- it had deleted
        // before it reported, and reported only the half that failed. The gate
        // is the fix, and a gate that has never been shown to hold is not one.
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ext4mac-selftest-\(getpid())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            for uuid in ["aaaa-1", "bbbb-2"] {
                try Data([0xDE, 0xAD]).write(to: tmp.appendingPathComponent("\(uuid).key"))
            }
            let listed = Ext4Unlock.forgetAll(confirmed: false, in: tmp, includeKeychain: false)
            let survivors = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []
            check("forget --all without --yes deletes nothing",
                  listed == 2 && survivors.count == 2,
                  "rc \(listed), \(survivors.count) file(s) left")

            let done = Ext4Unlock.forgetAll(confirmed: true, in: tmp, includeKeychain: false)
            let after = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []
            check("and with --yes the key files are gone",
                  done == 0 && after.isEmpty,
                  "rc \(done), \(after.count) file(s) left")
        } catch {
            check("the forget --all gate could be exercised", false,
                  error.localizedDescription)
        }

        print("")
        print("passed: \(passedCount)   failed: \(failed)")
        return failed == 0 ? 0 : 1
    }

    static func usage(_ code: Int32) -> Never {
        let text = """
        open_ext4_for_mac — ext2/ext3/ext4 for macOS via FSKit

        Ext4Mac                     is the extension installed and enabled?
        Ext4Mac unlock /dev/diskN   unlock an encrypted (LUKS) volume
        Ext4Mac forget <uuid|disk>  forget a volume's key again
        Ext4Mac forget --all        list every key this build can see;
                                    add --yes to actually forget them
        Ext4Mac version             which build the installed bundles are
        Ext4Mac list                which volumes are unlocked
        Ext4Mac last-error <uuid|disk>
                                    why the extension refused or degraded a
                                    volume, and what to do about it
        Ext4Mac events [n]          the last n volume events (default 10)
        Ext4Mac selftest            what this build can check about itself
        Ext4Mac mount /dev/diskN    mount a volume whose key is stored
        Ext4Mac menu                watch for encrypted volumes and ask
        Ext4Mac login-item [on|off] start at login, so the extension stays
                                    registered across reboots (default: status)

        Or mount anything ext4 with:
          mount -F -t ext4 <disk> <mountpoint>
        """
        print(text)
        exit(code)
    }

    /// `FSClient` is async and this entry point is not, because AppKit wants
    /// the main thread and its own run loop. One wait, at the only point that
    /// needs it, is simpler than making the whole program async around it.
    static func statusSynchronously() {
        let done = DispatchSemaphore(value: 0)
        Task { await status(); done.signal() }
        done.wait()
    }

    static func status() async {
        print("open_ext4_for_mac — ext2/ext3/ext4 for macOS via FSKit")
        print("")

        do {
            let installed = try await FSClient.shared.installedExtensions
            let ours = installed.filter { $0.bundleIdentifier.hasPrefix("dev.h3ct0r.ext4mac") }

            if ours.isEmpty {
                print("status: extension not registered")
                print("")
                print("Move Ext4Mac.app to /Applications and launch it once so macOS")
                print("registers the extension.")
            } else {
                for module in ours {
                    print("status: \(module.isEnabled ? "enabled" : "registered but DISABLED")")
                    print("  bundle: \(module.bundleIdentifier)")
                    print("  path:   \(module.url.path)")
                }
                if ours.allSatisfy({ !$0.isEnabled }) {
                    print("")
                    print("Enable it in System Settings > General >")
                    print("Login Items & Extensions > File System Extensions.")
                }
            }
        } catch {
            print("could not query installed extensions: \(error.localizedDescription)")
        }

        do {
            let unlocked = try LUKSKeychain.storedUUIDs()
            if !unlocked.isEmpty {
                print("")
                print("unlocked encrypted volumes: \(unlocked.count)")
                for uuid in unlocked { print("  \(uuid)") }
            }
        } catch {
            // Not fatal: the keychain has nothing to do with whether the
            // extension works, and an unentitled build simply has no items.
        }

        // What the extension last had to say about each volume it would not,
        // or could not, mount. Without the menu-bar agent running this is the
        // only place a locked container is reported at all.
        if let dir = VolumeEventStore.directory(insideSandbox: false) {
            let events = VolumeEventStore.all(in: dir)
            if !events.isEmpty {
                print("")
                print("volumes with something to report (newest first):")
                for e in events.prefix(5) { print("  " + Ext4Events.oneLine(e)) }
                if events.count > 5 { print("  … and \(events.count - 5) more") }
                print("  Ext4Mac last-error <disk|uuid> shows the whole record")
            }
        }

        print("")
        print("Mount manually with:")
        print("  mount -F -t ext4 <disk> <mountpoint>")
    }
}
