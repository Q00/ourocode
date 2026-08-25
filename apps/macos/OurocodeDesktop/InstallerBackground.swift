#!/usr/bin/env swift

import AppKit

guard CommandLine.arguments.count == 2 else {
    fputs("usage: InstallerBackground.swift OUTPUT.png\n", stderr)
    exit(64)
}

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let logicalSize = NSSize(width: 660, height: 420)
let backingScale = 2
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(logicalSize.width) * backingScale,
    pixelsHigh: Int(logicalSize.height) * backingScale,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fputs("failed to create Retina installer background\n", stderr)
    exit(1)
}
bitmap.size = logicalSize

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.cgContext.scaleBy(x: CGFloat(backingScale), y: CGFloat(backingScale))

let bounds = NSRect(origin: .zero, size: logicalSize)
NSColor(
    deviceRed: 243.0 / 255.0,
    green: 244.0 / 255.0,
    blue: 246.0 / 255.0,
    alpha: 1
).setFill()
bounds.fill()

// Finder supplies the accessible "Install Ourocode" window title and the
// two named items. The background only reinforces their spatial relationship;
// no required instruction is trapped in decorative pixels.
let arrowPath = NSBezierPath()
arrowPath.lineWidth = 1.5
arrowPath.lineCapStyle = .round
arrowPath.lineJoinStyle = .round
arrowPath.move(to: NSPoint(x: 310, y: 190))
arrowPath.line(to: NSPoint(x: 350, y: 190))
arrowPath.move(to: NSPoint(x: 342, y: 198))
arrowPath.line(to: NSPoint(x: 350, y: 190))
arrowPath.line(to: NSPoint(x: 342, y: 182))
NSColor(
    deviceRed: 99.0 / 255.0,
    green: 102.0 / 255.0,
    blue: 109.0 / 255.0,
    alpha: 1
).setStroke()
arrowPath.stroke()

context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [.interlaced: false]) else {
    fputs("failed to render installer background\n", stderr)
    exit(1)
}

try FileManager.default.createDirectory(
    at: output.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
try png.write(to: output, options: .atomic)
