//
//  Ext4DiskUtilityInstall.swift — putting ext2/3/4 in Disk Utility's Erase menu
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Disk Utility and `diskutil listFilesystems` read /Library/Filesystems, so a
//  small bundle there is what makes ext4 an option people can pick instead of
//  a command they have to be told. Installing it needs root, and until now the
//  instruction was `sudo make install-diskutil` in a text file -- which asks a
//  user to have a source checkout, a terminal, and the willingness to run make
//  as root to get a menu entry.
//
//  So the app offers it, with the standard macOS administrator prompt. The
//  same four commands the Makefile target runs, in one authorised shell script
//  rather than a helper tool: this is a one-shot copy a person asked for, not
//  a privileged service worth installing and keeping.
//
//  Declining is not an error. The prompt's own Cancel returns -128, which is
//  mapped to `cancelled` and shown as nothing at all.
//

import Foundation
import os

enum Ext4DiskUtilityInstall {
    private static let log = Logger(subsystem: "dev.h3ct0r.ext4", category: "diskutil")

    static let destination = SetupPaths.diskUtilityBundle

    enum Outcome: Equatable {
        case installed
        case cancelled
        case failed(String)
        /// osascript is absent or refused (managed Macs can forbid it). The
        /// user is given the commands instead of a dead end.
        case unavailable(String)
    }

    /// Is the bundle in place, and does diskutil actually list it? The second
    /// half matters: a copied bundle with the wrong ownership is present and
    /// ignored.
    static func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: destination + "/Contents/Info.plist")
    }

    /// `CFBundleVersion` of a .fs bundle, as a number. The installed copy and
    /// the one inside this app are different files, and until now nothing
    /// compared them: a bundle installed months ago reported itself as
    /// "installed" while lacking the change that lets Disk Utility erase a
    /// physical disk.
    private static func version(ofBundleAt path: String) -> Int {
        guard let data = FileManager.default.contents(atPath: path + "/Contents/Info.plist"),
              let plist = try? PropertyListSerialization.propertyList(
                    from: data, options: [], format: nil) as? [String: Any] else { return 0 }
        return Int(plist["CFBundleVersion"] as? String ?? "0") ?? 0
    }

    static func installedVersion() -> Int { version(ofBundleAt: destination) }

    static func bundledVersion() -> Int {
        guard let source else { return 0 }
        return version(ofBundleAt: source.path)
    }

    static func state() -> SetupBundleState {
        guard isInstalled() else { return .absent }
        return installedVersion() < bundledVersion() ? .outdated : .current
    }

    static func diskUtilityListsExt() -> Bool {
        let out = Shell.run("/usr/sbin/diskutil", ["listFilesystems"], deadline: 15)
        return out.status == 0 && out.stdout.lowercased().contains("ext4")
    }

    /// The copy inside the app bundle, which is what gets installed.
    static var source: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("ext4.fs")
    }

    static func install() -> Outcome {
        guard let source, FileManager.default.fileExists(
                atPath: source.appendingPathComponent("Contents/Info.plist").path) else {
            return .failed("this build of Ext4Mac does not carry the Disk Utility bundle")
        }
        // Single-quoted, with any embedded quote escaped, because the path is
        // whatever the app was dragged to and a shell is being handed it.
        let script = """
            rm -rf '\(destination)' && \
            cp -R '\(shellQuoted(source.path))' '\(destination)' && \
            chown -R root:wheel '\(destination)' && \
            chmod -R go-w '\(destination)'
            """
        return run(script, what: "install")
    }

    static func uninstall() -> Outcome {
        run("rm -rf '\(destination)'", what: "remove")
    }

    static func manualCommands() -> String {
        let path = source?.path ?? "/Applications/Ext4Mac.app/Contents/Resources/ext4.fs"
        return """
            sudo rm -rf \(destination)
            sudo cp -R "\(path)" \(destination)
            sudo chown -R root:wheel \(destination)
            sudo chmod -R go-w \(destination)
            """
    }

    // MARK: -

    private static func shellQuoted(_ path: String) -> String {
        path.replacingOccurrences(of: "'", with: "'\\''")
    }

    private static func run(_ script: String, what: String) -> Outcome {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/osascript") else {
            return .unavailable("osascript is not available on this Mac")
        }
        // The script travels as an argument, not inside the AppleScript
        // source: anything interpolated into `do shell script "…"` has to
        // survive two levels of quoting, and a path with a space in it is the
        // normal case, not the edge one.
        let out = Shell.run("/usr/bin/osascript",
                            ["-e", "on run argv",
                             "-e", "do shell script (item 1 of argv) with administrator privileges",
                             "-e", "end run",
                             script],
                            deadline: 120)
        if out.status == 0 {
            log.info("disk utility bundle: \(what, privacy: .public) succeeded")
            return .installed
        }
        let stderr = out.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        // -128 is "User canceled", which is a decision and not a failure.
        if stderr.contains("-128") || stderr.lowercased().contains("user canceled") {
            return .cancelled
        }
        if stderr.contains("-1743") || stderr.lowercased().contains("not authorized") {
            return .unavailable("this Mac does not allow Ext4Mac to ask for administrator rights")
        }
        log.error("disk utility bundle: \(what, privacy: .public) failed: \(stderr, privacy: .public)")
        return .failed(stderr.isEmpty ? "the administrator command failed" : stderr)
    }
}
