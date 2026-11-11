// Renders the onwin application icon with AppKit — no third-party tools, no image assets.
//
//   swift scripts/make-icon.swift <output.iconset> [<output.icns>]
//
// Writes the standard iconset PNGs (icon_16x16.png ... icon_512x512@2x.png). If a second
// argument is given, it also writes an .icns directly (PNG-based chunks), which build-app.sh
// uses when `iconutil` is unavailable.
//
// Design ("Слои"): a light, neutral tile in the colours of onwin's own interface — a Windows program's
// window sitting on top of a Mac window. The back window is teal (OnwinTheme.accent, system teal), the
// front one white with a graphite outline and a teal title bar. Deliberately unlike any other product's logo.

import AppKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write("usage: make-icon.swift <output.iconset> [<output.icns>]\n".data(using: .utf8)!)
    exit(2)
}
let iconsetURL = URL(fileURLWithPath: arguments[1], isDirectory: true)
let icnsURL: URL? = arguments.count >= 3 ? URL(fileURLWithPath: arguments[2]) : nil

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

/// Rounded window: body, optional title bar of `barHeight`, outline. AppKit coordinates (y up).
func drawWindow(_ rect: NSRect, radius: CGFloat, body: NSGradient?, bodyColor: NSColor?, bar: NSGradient?,
                barHeight: CGFloat, outline: NSColor?, outlineWidth: CGFloat, angle: CGFloat) {
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    if let body { body.draw(in: path, angle: angle) }
    if let bodyColor { bodyColor.setFill(); path.fill() }
    if let bar {
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        bar.draw(in: NSRect(x: rect.minX, y: rect.maxY - barHeight, width: rect.width, height: barHeight), angle: 0)
        NSGraphicsContext.restoreGraphicsState()
    }
    if let outline {
        let separator = NSBezierPath()
        separator.move(to: NSPoint(x: rect.minX, y: rect.maxY - barHeight))
        separator.line(to: NSPoint(x: rect.maxX, y: rect.maxY - barHeight))
        separator.lineWidth = outlineWidth * 0.75
        outline.setStroke()
        if bar != nil { separator.stroke() }
        // Stroke inside the rect so the outer size stays exact at every pixel size.
        let inset = outlineWidth / 2
        let border = NSBezierPath(roundedRect: rect.insetBy(dx: inset, dy: inset),
                                  xRadius: radius - inset, yRadius: radius - inset)
        border.lineWidth = outlineWidth
        border.stroke()
    }
}

/// Draws the icon into the current graphics context, in a `side`×`side` canvas.
func drawIcon(side: CGFloat) {
    let s = side / 1024   // design grid is 1024×1024 (macOS icon template: 824 pt body, 100 pt margin)

    let graphite = color(0x3A3A3C)
    let tealLight = color(0x5CCADB)
    let teal = color(0x30B0C7)
    let tealDeep = color(0x2493AA)

    // Tile with drop shadow.
    let tileRect = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let tile = NSBezierPath(roundedRect: tileRect, xRadius: 185 * s, yRadius: 185 * s)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 28 * s
    shadow.shadowOffset = NSSize(width: 0, height: -12 * s)
    shadow.set()
    color(0xEDEDF0).setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    // Neutral, slightly cool "material" surface: white at the top, light grey at the bottom.
    NSGradient(colors: [color(0xFFFFFF), color(0xF3F3F6), color(0xE2E3E8)],
               atLocations: [0, 0.45, 1], colorSpace: .sRGB)?
        .draw(in: tileRect, angle: -90)

    // Back window — the Mac: teal, no outline.
    let back = NSRect(x: 262 * s, y: 432 * s, width: 392 * s, height: 316 * s)
    drawWindow(back, radius: 60 * s,
               body: NSGradient(colors: [tealLight, tealDeep]), bodyColor: nil,
               bar: NSGradient(colors: [NSColor.white.withAlphaComponent(0.28), NSColor.white.withAlphaComponent(0.18)]),
               barHeight: 84 * s, outline: nil, outlineWidth: 0, angle: -60)

    // Front window — the Windows program: white body, teal title bar, graphite outline, soft shadow.
    let front = NSRect(x: 370 * s, y: 276 * s, width: 392 * s, height: 342 * s)
    NSGraphicsContext.saveGraphicsState()
    let frontShadow = NSShadow()
    frontShadow.shadowColor = color(0x0B3A44, 0.30)
    frontShadow.shadowBlurRadius = 36 * s
    frontShadow.shadowOffset = NSSize(width: 0, height: -14 * s)
    frontShadow.set()
    NSColor.white.setFill()
    NSBezierPath(roundedRect: front, xRadius: 60 * s, yRadius: 60 * s).fill()
    NSGraphicsContext.restoreGraphicsState()
    drawWindow(front, radius: 60 * s, body: nil, bodyColor: .white,
               bar: NSGradient(colors: [teal, tealDeep]), barHeight: 92 * s,
               outline: graphite, outlineWidth: 22 * s, angle: 0)

    NSGraphicsContext.restoreGraphicsState()

    // Hairline rim so the light tile stays visible on a light Dock / Finder background.
    let rim = NSBezierPath(roundedRect: tileRect.insetBy(dx: 1.5 * s, dy: 1.5 * s), xRadius: 183.5 * s, yRadius: 183.5 * s)
    rim.lineWidth = max(3 * s, 0.5)
    NSColor.black.withAlphaComponent(0.10).setStroke()
    rim.stroke()
}

func renderPNG(pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    // A fresh bitmap rep is zero-filled, i.e. fully transparent.
    drawIcon(side: CGFloat(pixels))
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

// iconset file name → pixel size
let iconsetFiles: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

do {
    try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
} catch {
    FileHandle.standardError.write("cannot create \(iconsetURL.path): \(error)\n".data(using: .utf8)!)
    exit(1)
}

var pngBySize: [Int: Data] = [:]
for size in Set(iconsetFiles.map { $0.1 }) {
    guard let png = renderPNG(pixels: size) else {
        FileHandle.standardError.write("failed to render \(size)px icon\n".data(using: .utf8)!)
        exit(1)
    }
    pngBySize[size] = png
}
for (name, size) in iconsetFiles {
    do {
        try pngBySize[size]!.write(to: iconsetURL.appendingPathComponent(name))
    } catch {
        FileHandle.standardError.write("cannot write \(name): \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

if let icnsURL {
    // ICNS: 'icns' + total length (BE), then chunks of OSType + chunk length (BE, incl. 8-byte header) + PNG.
    let chunks: [(String, Int)] = [
        ("ic11", 32), ("ic12", 64), ("ic07", 128), ("ic13", 256),
        ("ic08", 256), ("ic14", 512), ("ic09", 512), ("ic10", 1024),
    ]
    func bigEndian32(_ value: Int) -> [UInt8] {
        [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }
    var body: [UInt8] = []
    for (type, size) in chunks {
        let png = pngBySize[size]!
        body += Array(type.utf8)
        body += bigEndian32(png.count + 8)
        body += [UInt8](png)
    }
    var file: [UInt8] = Array("icns".utf8)
    file += bigEndian32(body.count + 8)
    file += body
    do {
        try Data(file).write(to: icnsURL)
    } catch {
        FileHandle.standardError.write("cannot write \(icnsURL.path): \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}
print("icon: \(iconsetURL.path)")
