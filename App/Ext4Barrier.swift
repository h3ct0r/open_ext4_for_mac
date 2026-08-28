//
//  Ext4Barrier.swift
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Report on the privileged barrier daemon.
///
/// The daemon issues one ioctl — `DKIOCSYNCHRONIZECACHE` — on behalf of the
/// extension, which is not permitted to issue it: the App Sandbox denies that
/// call by name and no entitlement lifts the denial. Without it the journal
/// commits with nothing enforcing order beneath it, which is why a USB stick
/// pulled from under a live mount came back damaged five times out of five
/// while a disk image never did.
///
/// Installing and removing it are `sudo make install-barrier` and
/// `sudo make uninstall-barrier`. This command only reports, because the two
/// operations it would otherwise wrap are a root file copy and a `launchctl
/// bootstrap`, and wrapping those in an app that then has to ask for
/// authorisation is the arrangement that did not work.
///
/// It was written against `SMAppService` first, which is the modern API for
/// exactly this and is the reason for that last sentence. `SMAppService`
/// registers a daemon as *disallowed* and waits for approval in Login Items;
/// here the toggle is inert, `register()` returns a bare `EPERM` as the user
/// and as root alike, and every attempt leaves another stuck
/// "pending authorization" record in the Background Task Management database.
/// A daemon installed into `/Library/LaunchDaemons` by root is dispositioned
/// `enabled, allowed` instead — which is where every other third-party daemon
/// on a typical machine lives, for the same reason.
enum Ext4Barrier {

    private static let label = "dev.h3ct0r.ext4mac.barrier"
    private static let plist = "/Library/LaunchDaemons/dev.h3ct0r.ext4mac.barrier.plist"
    private static let program = "/Library/PrivilegedHelperTools/ext4barrierd"

    static func command(_ argument: String?) -> Int32 {
        switch argument {
        case nil, "status":
            return report()
        case "on", "install", "off", "uninstall":
            print("Installing and removing the barrier daemon are root operations:")
            print("")
            print("    sudo make install-barrier")
            print("    sudo make uninstall-barrier")
            print("")
            print("Run them from the source tree.")
            return 2
        default:
            FileHandle.standardError.write(
                "Ext4Mac: barrier takes status\n".data(using: .utf8)!)
            return 2
        }
    }

    /// Whether launchd currently has the service. Asking launchd rather than
    /// looking at files is the difference between "it was installed" and "it
    /// will answer", and only the second one is worth reporting.
    private static func isLoaded() -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["print", "system/\(label)"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            return false
        }
        task.waitUntilExit()
        return task.terminationStatus == 0
    }

    private static func report() -> Int32 {
        let installed = FileManager.default.fileExists(atPath: plist)
            && FileManager.default.fileExists(atPath: program)
        let loaded = isLoaded()

        if installed && loaded {
            print("write barrier daemon: installed and running")
            print("")
            print("Removable media can be written with the journal's barriers")
            print("reaching the drive. Eject anyway when you can: a barrier makes")
            print("a crash recoverable, not free.")
            return 0
        }

        if installed {
            print("write barrier daemon: installed, but launchd does not have it")
            print("")
            print("    sudo launchctl bootstrap system \(plist)")
            return 1
        }

        print("write barrier daemon: not installed")
        print("")
        print("Without it there is no write barrier at all: FSKit's metadataFlush")
        print("fails for this module, and the sandbox refuses the device ioctl that")
        print("would replace it. Removable media stays read-only by default.")
        print("")
        print("    sudo make install-barrier      from the source tree")
        return 1
    }
}
