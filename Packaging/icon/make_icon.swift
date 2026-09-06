//
//  make_icon.swift — the app icon, drawn rather than imported
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  Run:  swift Packaging/icon/make_icon.swift App/Ext4Mac.icns
//
//  The plan called for an SVG rendered with sips. sips does not rasterise SVG
//  at all, and pulling in librsvg or Inkscape to draw one rounded rectangle
//  would make the icon un-rebuildable on a machine that has neither. So the
//  source of the icon is this file: CoreGraphics, in the toolchain the project
//  already requires, producing every size iconutil wants.
//
//  The mark is the same external drive the menu-bar item uses, so the thing in
//  the Dock and the thing in the menu bar are recognisably one program.
//

import AppKit
import Foundation

let output = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "App/Ext4Mac.icns"

func draw(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                              pixelsWide: Int(size), pixelsHigh: Int(size),
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = size

    // The rounded square every macOS icon sits in, inset the way the template
    // grid asks for, with a diagonal wash so it does not read as flat.
    let inset = s * 0.086
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let squircle = CGPath(roundedRect: rect,
                          cornerWidth: rect.width * 0.2237,
                          cornerHeight: rect.height * 0.2237, transform: nil)
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let colours = [CGColor(red: 0.20, green: 0.44, blue: 0.86, alpha: 1),
                   CGColor(red: 0.12, green: 0.24, blue: 0.55, alpha: 1)] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: colours, locations: [0, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: rect.minX, y: rect.maxY),
                           end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
    ctx.restoreGState()

    // The drive: a rounded body, a slot, and the light that says it is doing
    // something -- the shape the menu-bar symbol has.
    let bodyWidth = rect.width * 0.62
    let bodyHeight = bodyWidth * 0.60
    let body = CGRect(x: rect.midX - bodyWidth / 2,
                      y: rect.midY - bodyHeight / 2 + rect.height * 0.055,
                      width: bodyWidth, height: bodyHeight)
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.96))
    ctx.addPath(CGPath(roundedRect: body, cornerWidth: bodyHeight * 0.22,
                       cornerHeight: bodyHeight * 0.22, transform: nil))
    ctx.fillPath()

    let slot = CGRect(x: body.minX + body.width * 0.12,
                      y: body.minY + body.height * 0.24,
                      width: body.width * 0.52, height: body.height * 0.16)
    ctx.setFillColor(CGColor(red: 0.12, green: 0.24, blue: 0.55, alpha: 1))
    ctx.addPath(CGPath(roundedRect: slot, cornerWidth: slot.height / 2,
                       cornerHeight: slot.height / 2, transform: nil))
    ctx.fillPath()

    let light = CGRect(x: body.maxX - body.width * 0.22,
                       y: body.minY + body.height * 0.22,
                       width: body.height * 0.20, height: body.height * 0.20)
    ctx.setFillColor(CGColor(red: 0.30, green: 0.80, blue: 0.42, alpha: 1))
    ctx.fillEllipse(in: light)

    // The wordmark, only where it can be read. At 16 and 32 points it would be
    // three grey pixels pretending to be letters.
    if s >= 128 {
        let text = "ext4" as NSString
        let font = NSFont.systemFont(ofSize: s * 0.13, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.95),
            .kern: s * 0.008,
        ]
        let measured = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: rect.midX - measured.width / 2,
                              y: body.minY - measured.height - s * 0.035),
                  withAttributes: attributes)
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
    let pixels = CGFloat(points * scale)
    let rep = draw(size: pixels)
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
