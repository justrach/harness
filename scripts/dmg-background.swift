#!/usr/bin/env swift
import AppKit

// The illustration is a text-free ImageGen plate. Finder supplies the actual
// draggable icons; AppKit draws exact, sharp copy over the plate at 1x and 2x.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let output = root.appendingPathComponent("dist/macos")
let source = output.appendingPathComponent("dmg-workshop-imagegen.png")
guard let plate = NSImage(contentsOf: source) else {
    fatalError("Missing \(source.path)")
}
let canvas = NSSize(width: 660, height: 400)

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
}

func label(_ value: String, x: CGFloat, y: CGFloat, width: CGFloat,
           size: CGFloat, weight: NSFont.Weight, ink: NSColor) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: ink,
        .paragraphStyle: paragraph,
    ]
    (value as NSString).draw(in: NSRect(x: x, y: y, width: width, height: size + 9),
                             withAttributes: attributes)
}

func render(scale: Int, filename: String) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                               pixelsWide: 660 * scale, pixelsHigh: 400 * scale,
                               bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0,
                               bitsPerPixel: 0)!
    rep.size = canvas
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    plate.draw(in: NSRect(origin: .zero, size: canvas),
               from: NSRect(origin: .zero, size: plate.size),
               operation: .copy, fraction: 1)

    let ink = color(0x1b1714)
    let muted = color(0x60554b)
    let coral = color(0xd45a43)
    label("CODEGRAFF", x: 220, y: 365, width: 220,
          size: 10, weight: .bold, ink: coral)
    label("Install Harness", x: 160, y: 324, width: 340,
          size: 26, weight: .semibold, ink: ink)
    label("Drag Harness into Applications", x: 145, y: 297, width: 370,
          size: 13, weight: .regular, ink: muted)
    label("Then open Harness from Applications.", x: 135, y: 22, width: 390,
          size: 12, weight: .regular, ink: muted)
    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("Could not render \(filename)")
    }
    try png.write(to: output.appendingPathComponent(filename))
}

try render(scale: 1, filename: "dmg-background.png")
try render(scale: 2, filename: "dmg-background@2x.png")
