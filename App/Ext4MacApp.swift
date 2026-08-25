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

        print("")
        print("Mount manually with:")
        print("  mount -F -t ext4 <disk> <mountpoint>")
    }
}
