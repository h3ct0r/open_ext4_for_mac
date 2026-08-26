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
    static func main() async {
        var arguments = Array(CommandLine.arguments.dropFirst())
        let command = arguments.isEmpty ? "status" : arguments.removeFirst()

        switch command {
        case "status":
            await status()

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

        Mount with:
          mount -F -t ext4 <disk> <mountpoint>
        """
        print(text)
        exit(code)
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
