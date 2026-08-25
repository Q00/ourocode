#!/usr/bin/env swift

import AppKit

guard CommandLine.arguments.count == 2 else {
    fputs("usage: AppIconGenerator.swift OUTPUT.png\n", stderr)
    exit(64)
}

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()

let tile = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 196, yRadius: 196)
NSGraphicsContext.current?.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.34)
shadow.shadowBlurRadius = 44
shadow.shadowOffset = NSSize(width: 0, height: -18)
shadow.set()
NSColor(srgbRed: 0.035, green: 0.038, blue: 0.046, alpha: 1).setFill()
tile.fill()
NSGraphicsContext.current?.restoreGraphicsState()

NSGraphicsContext.current?.saveGraphicsState()
tile.addClip()
let gradient = NSGradient(colors: [
    NSColor(srgbRed: 0.12, green: 0.13, blue: 0.15, alpha: 1),
    NSColor(srgbRed: 0.035, green: 0.038, blue: 0.046, alpha: 1)
])!
gradient.draw(in: NSRect(x: 64, y: 64, width: 896, height: 896), angle: -70)
NSGraphicsContext.current?.restoreGraphicsState()

let ringRect = NSRect(x: 246, y: 246, width: 532, height: 532)
let ring = NSBezierPath()
ring.appendArc(withCenter: NSPoint(x: 512, y: 512), radius: ringRect.width / 2, startAngle: 34, endAngle: 326, clockwise: false)
ring.lineWidth = 62
ring.lineCapStyle = .round
NSColor(white: 0.94, alpha: 1).setStroke()
ring.stroke()

let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 704, y: 324))
arrow.line(to: NSPoint(x: 775, y: 300))
arrow.line(to: NSPoint(x: 753, y: 372))
arrow.close()
NSColor(srgbRed: 0.40, green: 0.85, blue: 0.76, alpha: 1).setFill()
arrow.fill()

let cursor = NSBezierPath()
cursor.move(to: NSPoint(x: 462, y: 450))
cursor.line(to: NSPoint(x: 514, y: 512))
cursor.line(to: NSPoint(x: 462, y: 574))
cursor.move(to: NSPoint(x: 540, y: 574))
cursor.line(to: NSPoint(x: 618, y: 574))
cursor.lineWidth = 30
cursor.lineCapStyle = .round
NSColor(srgbRed: 0.40, green: 0.85, blue: 0.76, alpha: 1).setStroke()
cursor.stroke()

image.unlockFocus()
guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("failed to render app icon\n", stderr)
    exit(1)
}
try png.write(to: output, options: .atomic)
