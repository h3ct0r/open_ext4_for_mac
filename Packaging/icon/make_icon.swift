//
//  make_icon.swift — the app icon, drawn rather than imported
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Run:  swift Packaging/icon/make_icon.swift App/Ext4Mac.icns
//
//  The plan called for an SVG rendered with sips. sips does not rasterise SVG
//  at all, and pulling in librsvg or Inkscape to draw a rounded rectangle and
//  four letters would make the icon un-rebuildable on a machine that has
//  neither. So the source of the icon is this file: CoreGraphics, in the
//  toolchain the project already requires, producing every size iconutil
//  wants.
//
//  The mark is the name. In a Dock of blue squircles a dark one carrying the
//  word "ext4" says what the program is without anyone having to recognise a
//  drawing of a disk, and the file system's name is the one word every user of
//  this app already knows.
//
//  It is drawn differently at different sizes, which is the whole reason an
//  .icns holds ten images rather than one scaled picture:
//
//    128 px and up   the wordmark with the accent bar beneath it
//    32 to 64 px     the wordmark alone, larger; the bar becomes a smudge
//    16 px           "e4" -- four letters at that size are grey mush, and a
//                    thing that cannot be read should not pretend to be words
//
//  Rendered at 5x and looked at before it was chosen; the 16 px comparison is
//  in the commit that introduced it.
//

import AppKit
import Foundation

let output = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "App/Ext4Mac.icns"

let slate = NSColor(calibratedRed: 0.20, green: 0.23, blue: 0.28, alpha: 1)
let slateDark = NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.13, alpha: 1)
let accent = NSColor(calibratedRed: 0.36, green: 0.62, blue: 1, alpha: 1)
let paper = NSColor(calibratedWhite: 1, alpha: 0.97)

func draw(size s: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                              pixelsWide: Int(s), pixelsHigh: Int(s),
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // The rounded square every macOS icon sits in: inset off the canvas edge,
    // with the continuous corner at 22.37% of the body, and a diagonal wash so
    // it does not read as flat.
    let inset = s * 0.086
    let body = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: body,
                       cornerWidth: body.width * 0.2237,
                       cornerHeight: body.height * 0.2237, transform: nil))
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [slate.cgColor, slateDark.cgColor] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: body.minX, y: body.maxY),
                           end: CGPoint(x: body.maxX, y: body.minY), options: [])
    ctx.restoreGState()

    func word(_ text: String, points: CGFloat, weight: NSFont.Weight, baseline: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: points, weight: weight),
            .foregroundColor: paper,
        ]
        let ns = text as NSString
        let measured = ns.size(withAttributes: attributes)
        ns.draw(at: NSPoint(x: body.midX - measured.width / 2, y: baseline),
                withAttributes: attributes)
    }

    if s >= 128 {
        word("ext4", points: s * 0.30, weight: .bold, baseline: body.midY - s * 0.075)
        // The accent bar: a drive slot, and the one piece of colour.
        ctx.setFillColor(accent.cgColor)
        let bar = CGRect(x: body.midX - body.width * 0.26,
                         y: body.minY + body.height * 0.17,
                         width: body.width * 0.52, height: body.height * 0.055)
        ctx.addPath(CGPath(roundedRect: bar, cornerWidth: bar.height / 2,
                           cornerHeight: bar.height / 2, transform: nil))
        ctx.fillPath()
    } else if s >= 32 {
        word("ext4", points: s * 0.335, weight: .bold, baseline: body.midY - s * 0.125)
    } else {
        word("e4", points: s * 0.46, weight: .bold, baseline: body.midY - s * 0.175)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("Ext4Mac-\(getpid()).iconset", isDirectory: true)
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                        (256, 1), (256, 2), (512, 1), (512, 2)] {
    let rep = draw(size: CGFloat(points * scale))
    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("could not encode \(points)@\(scale)x")
    }
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    try png.write(to: iconset.appendingPathComponent(name))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { exit(iconutil.terminationStatus) }
try? FileManager.default.removeItem(at: iconset)
print("wrote \(output)")
