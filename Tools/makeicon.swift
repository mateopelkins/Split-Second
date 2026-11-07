import AppKit

// Draws the app icon, a stopwatch with one split marked. Usage: makeicon out.png
let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: size, height: size)
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
}
let silver = color(0xE9E9EC)
let dial = color(0x141416)
let purple = color(0x9B6DFF)

// Tile, on the standard macOS icon grid.
let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
shadow.set()
dial.setFill()
tile.fill()
NSGraphicsContext.restoreGraphicsState()
NSGradient(starting: color(0x2E2E33), ending: color(0x0E0E10))!.draw(in: tile, angle: -90)
// A faint rim, so the tile holds its shape on a dark Dock.
NSColor.white.withAlphaComponent(0.16).setStroke()
let rim = NSBezierPath(roundedRect: NSRect(x: 103, y: 103, width: 818, height: 818), xRadius: 182, yRadius: 182)
rim.lineWidth = 6
rim.stroke()

let center = NSPoint(x: 512, y: 472)
let radius: CGFloat = 262

// Crown and side button.
silver.setFill()
NSBezierPath(roundedRect: NSRect(x: 462, y: 762, width: 100, height: 58), xRadius: 18, yRadius: 18).fill()
NSBezierPath(rect: NSRect(x: 488, y: 716, width: 48, height: 60)).fill()
NSGraphicsContext.saveGraphicsState()
let side = NSAffineTransform()
side.translateX(by: center.x, yBy: center.y)
side.rotate(byDegrees: -42)
side.concat()
NSBezierPath(roundedRect: NSRect(x: -32, y: radius + 8, width: 64, height: 46), xRadius: 14, yRadius: 14).fill()
NSGraphicsContext.restoreGraphicsState()

// Dial.
NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)).fill()
let inner = radius - 40
dial.setFill()
NSBezierPath(ovalIn: NSRect(x: center.x - inner, y: center.y - inner, width: inner * 2, height: inner * 2)).fill()

// Quarter marks.
silver.withAlphaComponent(0.55).setStroke()
for angle in stride(from: 0.0, to: 360.0, by: 90.0) {
    let mark = NSBezierPath()
    mark.lineWidth = 16
    mark.lineCapStyle = .round
    let radians = angle * .pi / 180
    mark.move(to: NSPoint(x: center.x + cos(radians) * (inner - 34), y: center.y + sin(radians) * (inner - 34)))
    mark.line(to: NSPoint(x: center.x + cos(radians) * (inner - 70), y: center.y + sin(radians) * (inner - 70)))
    mark.stroke()
}

// The one colored part: the hand.
let radians = 35.0 * .pi / 180
let hand = NSBezierPath()
hand.lineWidth = 26
hand.lineCapStyle = .round
hand.move(to: center)
hand.line(to: NSPoint(x: center.x + cos(radians) * (inner - 44), y: center.y + sin(radians) * (inner - 44)))
purple.setStroke()
hand.stroke()
purple.setFill()
NSBezierPath(ovalIn: NSRect(x: center.x - 32, y: center.y - 32, width: 64, height: 64)).fill()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
