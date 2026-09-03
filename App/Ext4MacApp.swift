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
        check("key material is locked into memory, not swappable",
              secret.isLocked,
              "mlock did not take -- built with LUKS_NO_MLOCK, or "
              + "RLIMIT_MEMLOCK is too small to lock one page")
        check("and it holds what was put in it", secret.count == 28,
              "count is \(secret.count)")

        // The same last line every suite in this project prints, so the CI
        // summary counts these assertions instead of showing a dash.
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

        print("")
        print("Mount manually with:")
        print("  mount -F -t ext4 <disk> <mountpoint>")
    }
}
