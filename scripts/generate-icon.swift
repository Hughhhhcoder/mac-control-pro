#!/usr/bin/env swift
// Original vector fan mark. No third-party or Apple SF Symbol assets are exported.
import AppKit
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon.iconset"
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.scaleBy(x: CGFloat(pixels)/1024, y: CGFloat(pixels)/1024)
        let tile = NSBezierPath(roundedRect: NSRect(x: 52, y: 52, width: 920, height: 920), xRadius: 210, yRadius: 210)
        NSGradient(starting: NSColor(calibratedRed: 0.08, green: 0.69, blue: 0.65, alpha: 1), ending: NSColor(calibratedRed: 0.015, green: 0.24, blue: 0.32, alpha: 1))!.draw(in: tile, angle: -70)
        ctx.saveGState()
        ctx.translateBy(x: 512, y: 512)
        for _ in 0..<4 {
            let blade = NSBezierPath()
            blade.move(to: NSPoint(x: 55, y: 55))
            blade.curve(to: NSPoint(x: 110, y: 325), controlPoint1: NSPoint(x: -35, y: 200), controlPoint2: NSPoint(x: -25, y: 340))
            blade.curve(to: NSPoint(x: 292, y: 186), controlPoint1: NSPoint(x: 235, y: 315), controlPoint2: NSPoint(x: 345, y: 265))
            blade.curve(to: NSPoint(x: 55, y: 55), controlPoint1: NSPoint(x: 255, y: 95), controlPoint2: NSPoint(x: 130, y: 85))
            blade.close(); NSColor.white.withAlphaComponent(0.94).setFill(); blade.fill()
            ctx.rotate(by: .pi/2)
        }
        NSColor.white.setFill(); NSBezierPath(ovalIn: NSRect(x: -65, y: -65, width: 130, height: 130)).fill()
        ctx.restoreGState()
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(output)/icon_\(size)x\(size)\(suffix).png"))
    }
}
