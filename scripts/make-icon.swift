// Draws the 1024 px app icon: a house on a blue rounded square. Run via `make icon`.
import AppKit

let size = 1024
let out = CommandLine.arguments.dropFirst().first ?? "icon.png"
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// macOS icon grid: 824 px body centred in 1024, corner radius ~185.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(srgbRed: 0.25, green: 0.78, blue: 0.98, alpha: 1),
           ending: NSColor(srgbRed: 0.04, green: 0.45, blue: 0.80, alpha: 1))!.draw(in: shape, angle: -90)

let config = NSImage.SymbolConfiguration(pointSize: 440, weight: .semibold)
    .applying(.init(paletteColors: [.white]))
let house = NSImage(systemSymbolName: "house.fill", accessibilityDescription: nil)!.withSymbolConfiguration(config)!
let h = house.size
house.draw(in: NSRect(x: body.midX - h.width / 2, y: body.midY - h.height / 2 + 10, width: h.width, height: h.height))

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
