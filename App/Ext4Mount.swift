//
//  Ext4Mount.swift — asking macOS to mount a volume we have just unlocked
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  After a container is unlocked there is nothing to prompt the system to look
//  at it again: DiskArbitration already probed the disk, found a volume it
//  could not mount, and moved on. So the mount has to be asked for.
//
//  Through DiskArbitration rather than mount(8), so the volume lands under
//  /Volumes with the name and ownership it would have had if it had never been
//  locked -- and so the request goes through the same machinery Finder uses.
//

import Foundation
import DiskArbitration

enum Ext4Mount {

    enum Outcome {
        case mounted
        case refused(String)
        case noSuchDisk
    }

    /// Ask for a mount and wait for the answer.
    ///
    /// DiskArbitration replies on a run loop, so one is run here until the
    /// callback arrives or the deadline passes. `timeout` is generous on
    /// purpose: the mount replays a journal, which on a large dirty volume is
    /// not instant.
    static func mount(bsdName: String, timeout: TimeInterval = 60) -> Outcome {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName) else {
            return .noSuchDisk
        }
        guard let runLoop = CFRunLoopGetCurrent() else { return .noSuchDisk }
        DASessionScheduleWithRunLoop(session, runLoop, CFRunLoopMode.defaultMode.rawValue)
        defer { DASessionUnscheduleFromRunLoop(session, runLoop, CFRunLoopMode.defaultMode.rawValue) }

        // A class so the callback can reach it through a raw pointer, and so
        // the answer outlives the run loop that produced it.
        final class Answer { var outcome: Outcome? }
        let answer = Answer()

        DADiskMount(disk, nil, DADiskMountOptions(kDADiskMountOptionDefault),
                    { _, dissenter, context in
            guard let context else { return }
            let answer = Unmanaged<Answer>.fromOpaque(context).takeUnretainedValue()
            if let dissenter {
                let text = DADissenterGetStatusString(dissenter) as String?
                    ?? "status \(DADissenterGetStatus(dissenter))"
                answer.outcome = .refused(text)
            } else {
                answer.outcome = .mounted
            }
            CFRunLoopStop(CFRunLoopGetCurrent())
        }, Unmanaged.passUnretained(answer).toOpaque())

        CFRunLoopRunInMode(.defaultMode, timeout, false)
        return answer.outcome ?? .refused("timed out waiting for DiskArbitration")
    }

    /// `Ext4Mac mount /dev/diskN` — for a volume whose key is already stored.
    static func command(_ argument: String) -> Int32 {
        let bsd = argument.hasPrefix("/dev/") ? String(argument.dropFirst(5)) : argument
        switch mount(bsdName: bsd) {
        case .mounted:
            print("mounted \(bsd)")
            return 0
        case .noSuchDisk:
            FileHandle.standardError.write("Ext4Mac: no such disk: \(bsd)\n".data(using: .utf8)!)
            return 1
        case .refused(let why):
            FileHandle.standardError.write("Ext4Mac: \(bsd) was not mounted: \(why)\n".data(using: .utf8)!)
            return 1
        }
    }
}
