// Renders a macOS-style 1024x1024 app icon from Ghidra's dragon PNG.
// Usage: swift make_icon.swift <GhidraIcon256.png> <out.png> [light|dark]
import AppKit

let args = CommandLine.arguments
guard args.count >= 3, let dragon = NSImage(contentsOfFile: args[1]) else {
    fputs("usage: make_icon.swift <in.png> <out.png>\n", stderr)
    exit(1)
}

let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
ctx.interpolationQuality = .high

// Standard macOS icon grid: 824pt tile centered on a 1024 canvas
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let path = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.shadowBlurRadius = 28
shadow.set()
NSColor.white.setFill()
path.fill()
NSGraphicsContext.restoreGraphicsState()

let dark = args.count > 3 && args[3] == "dark"
let gradient = dark
    ? NSGradient(starting: NSColor(calibratedRed: 0.20, green: 0.21, blue: 0.27, alpha: 1),
                 ending: NSColor(calibratedRed: 0.06, green: 0.06, blue: 0.09, alpha: 1))!
    : NSGradient(starting: NSColor(calibratedRed: 0.98, green: 0.97, blue: 0.95, alpha: 1),
                 ending: NSColor(calibratedRed: 0.86, green: 0.84, blue: 0.80, alpha: 1))!
gradient.draw(in: path, angle: -90)

let inset: CGFloat = 150
dragon.draw(in: tile.insetBy(dx: inset * 0.6, dy: inset * 0.6),
            from: .zero, operation: .sourceOver, fraction: 1.0)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
