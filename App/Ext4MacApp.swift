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

        // Writing to media that can be unplugged *without a barrier*.
        // The normal path needs no toggle: the mount asks the privileged
        // helper for a real barrier and grants read-write when one is
        // confirmed. See RemovableWritePolicy.
        case "removable-writes":
            exit(removableWrites(arguments.first))

        // The privileged helper that issues the write barrier the sandbox
        // will not let the extension issue itself.
        case "barrier":
            exit(Ext4Barrier.command(arguments.first))

        case "help", "-h", "--help":
            usage(0)
        default:
            FileHandle.standardError.write("Ext4Mac: unknown command '\(command)'\n".data(using: .utf8)!)
            usage(1)
        }
    }

    /// Report or change whether removable media may be written.
    static func removableWrites(_ argument: String?) -> Int32 {
        let directory = RemovableWritePolicy.directoryFromOutside()
        switch argument {
        case nil, "status":
            let on = RemovableWritePolicy.isEnabled(in: directory)
            print("unbarriered writes to removable media: \(on ? "FORCED" : "off (automatic)")")
            if !on {
                print("")
                print("Automatic mode: a removable volume mounts read-write when the")
                print("barrier daemon confirms a working write barrier on it, and")
                print("read-only -- with the reason in the log -- when it cannot.")
                print("Install the daemon with: make sign && sudo make install-barrier")
                print("")
                print("    Ext4Mac removable-writes on     force writes with no barrier")
            } else {
                print("")
                print("Writes are forced even with no barrier. A volume pulled while")
                print("mounted can come back corrupt -- measured, not theoretical.")
                print("")
                print("    Ext4Mac removable-writes off    return to automatic")
            }
            return 0
        case "on", "off":
            let enable = argument == "on"
            do {
                try RemovableWritePolicy.set(enable, in: directory)
            } catch {
                FileHandle.standardError.write("Ext4Mac: \(error)\n".data(using: .utf8)!)
                return 1
            }
            print(enable ? "unbarriered writes FORCED: removable media mounts read-write with no barrier"
                         : "automatic: removable media mounts read-write when the barrier works")
            print("takes effect on the next mount")
            return 0
        default:
            FileHandle.standardError.write("Ext4Mac: expected on, off or status\n".data(using: .utf8)!)
            return 1
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
        Ext4Mac removable-writes [on|off]
                                    allow writing to media you can unplug
        Ext4Mac barrier [on|off]    install the helper that gives the journal
                                    a real write barrier

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
