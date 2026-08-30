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

        case "help", "-h", "--help":
            usage(0)
        default:
            FileHandle.standardError.write("Ext4Mac: unknown command '\(command)'\n".data(using: .utf8)!)
            usage(1)
        }
    }

    static func usage(_ code: Int32) -> Never {
        let text = """
        open_ext4_for_mac — ext2/ext3/ext4 for macOS via FSKit

        Ext4Mac                     is the extension installed and enabled?
        Ext4Mac unlock /dev/diskN   unlock an encrypted (LUKS) volume
        Ext4Mac forget <uuid|disk>  forget a volume's key again
        Ext4Mac list                which volumes are unlocked
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
