//
//  event_probe.swift — drive VolumeEventStore from a test
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  The store is the extension's only way to tell anybody anything, and almost
//  everything that can be wrong with it has nothing to do with FSKit: a
//  half-written file the app reads mid-write, a log that grows without bound,
//  a label off a stranger's disk that turns into a path, a schema that does
//  not survive a round trip. None of that needs a mounted volume, an installed
//  extension or a user who has approved anything -- and on a machine where the
//  extension's container write policy is wedged, none of it can be reached
//  through the extension at all.
//
//  So this links the same Shared/ sources the extension and the app do, and
//  drives them directly. It is a test binary: it never ships, it is built only
//  by `make tools`, and it takes the directory it works in as an argument
//  rather than knowing anything about containers.
//

import Foundation

func die(_ message: String) -> Never {
    FileHandle.standardError.write("event_probe: \(message)\n".data(using: .utf8)!)
    exit(2)
}

let argv = Array(CommandLine.arguments.dropFirst())
guard let verb = argv.first else {
    print("""
    usage: event_probe <verb> <events-dir> [args]

      write  <dir> <kind> <device> [uuid] [reason] [bridge-line...]
      latest <dir> <key>            the stored JSON for one volume
      all    <dir>                  one line per volume with an event
      recent <dir> [n]              the last n history entries
      count  <dir>                  how many history lines there are
      logsize <dir>                 bytes in events.log
      flood  <dir> <n> <device> [uuid]   n events, to make the log rotate
      hammer <dir> <key> [seconds]      read one volume flat out, classify every read
    """)
    exit(2)
}
guard argv.count >= 2 else { die("no directory") }
let dir = URL(fileURLWithPath: argv[1], isDirectory: true)
let rest = Array(argv.dropFirst(2))

func event(kind: String, device: String, uuid: String?, reason: String,
           bridge: [String]) -> VolumeEvent {
    guard let k = VolumeEvent.Kind(rawValue: kind) else { die("unknown kind '\(kind)'") }
    return VolumeEvent(kind: k, device: device, uuid: uuid,
                       reason: reason, bridge: bridge, build: "probe")
}

switch verb {
case "write":
    guard rest.count >= 2 else { die("write needs <kind> <device>") }
    let uuid   = rest.count > 2 && !rest[2].isEmpty ? rest[2] : nil
    let reason = rest.count > 3 ? rest[3] : "written by event_probe"
    let bridge = rest.count > 4 ? Array(rest.dropFirst(4)) : []
    let ok = VolumeEventStore.record(
        event(kind: rest[0], device: rest[1], uuid: uuid, reason: reason, bridge: bridge),
        in: dir)
    print(ok ? "recorded" : "NOT RECORDED")
    exit(ok ? 0 : 1)

case "latest":
    guard let key = rest.first else { die("latest needs <key>") }
    guard let e = VolumeEventStore.latest(forKey: key, in: dir) else {
        print("none"); exit(1)
    }
    let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
    print(String(data: try! enc.encode(e), encoding: .utf8)!)

case "all":
    for e in VolumeEventStore.all(in: dir) {
        print("\(e.device) \(e.kind.rawValue) \(e.uuid ?? "-")")
    }

case "recent":
    let n = rest.first.flatMap(Int.init) ?? VolumeEventStore.recentCount
    for e in VolumeEventStore.recent(n, in: dir) {
        print("\(e.device) \(e.kind.rawValue) \(e.reason)")
    }

case "count":
    print(VolumeEventStore.recent(1_000_000, in: dir).count)

case "logsize":
    let log = dir.appendingPathComponent("events.log")
    let size = (try? FileManager.default.attributesOfItem(atPath: log.path)[.size] as? Int) ?? 0
    print(size)

case "flood":
    guard rest.count >= 2, let n = Int(rest[0]) else { die("flood needs <n> <device> [uuid]") }
    let floodUUID = rest.count > 2 && !rest[2].isEmpty ? rest[2] : nil
    // A reason long enough that a few hundred of these cross the rotation
    // threshold without the test having to write a hundred thousand events.
    let filler = String(repeating: "x", count: 400)
    for i in 0..<n {
        _ = VolumeEventStore.record(
            event(kind: "refused", device: rest[1], uuid: floodUUID,
                  reason: "flood \(i) \(filler)", bridge: []),
            in: dir)
    }
    print("wrote \(n)")

// Read one volume's file as fast as possible for a few seconds, and classify
// every read. This is the only way to ask whether the write is atomic: a
// reader that spawns a process per read never lands inside the window, so a
// deliberately torn writer passes such a test -- which is exactly what
// happened to the first version of this cell.
//
// absent   the file is not there. Fine: nothing has been written yet.
// complete it decoded. Fine.
// torn     it is there and it does not decode. That is the failure, and it is
//          what the app would show the user as a volume with no explanation.
case "hammer":
    guard let key = rest.first else { die("hammer needs <key> [seconds]") }
    let seconds = rest.count > 1 ? (Double(rest[1]) ?? 3) : 3
    let url = dir.appendingPathComponent("\(VolumeEvent.sanitised(key)).json")
    var absent = 0, complete = 0, torn = 0
    let decoder = JSONDecoder()
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        guard let data = try? Data(contentsOf: url) else { absent += 1; continue }
        if (try? decoder.decode(VolumeEvent.self, from: data)) != nil { complete += 1 }
        else { torn += 1 }
    }
    print("absent=\(absent) complete=\(complete) torn=\(torn)")

default:
    die("unknown verb '\(verb)'")
}
