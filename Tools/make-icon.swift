// Draw the app icon as a 1024 px PNG: a deck of three host cards, each with a status symbol,
// on a blue background.
// Usage: swift make-icon.swift <output.png>

import AppKit

let size = 1024.0

func symbol(_ name: String, size: Double, colors: [NSColor]) -> NSImage? {
    let config = NSImage.SymbolConfiguration(pointSize: size, weight: .bold)
        .applying(.init(paletteColors: colors))
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
}

func drawCentred(_ image: NSImage, at centre: NSPoint) {
    let s = image.size
    image.draw(in: NSRect(x: centre.x - s.width / 2, y: centre.y - s.height / 2, width: s.width, height: s.height))
}

let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
    // Background.
    let inset = rect.insetBy(dx: 100, dy: 100)
    let shape = NSBezierPath(roundedRect: inset, xRadius: 185, yRadius: 185)
    NSGradient(starting: NSColor(red: 0.20, green: 0.45, blue: 0.85, alpha: 1),
               ending: NSColor(red: 0.07, green: 0.16, blue: 0.40, alpha: 1))!
        .draw(in: shape, angle: -90)

    // Three host cards. Top to bottom: ready, ready, offline.
    let statuses: [(String, [NSColor])] = [
        ("checkmark.circle.fill", [.white, NSColor(red: 0.20, green: 0.78, blue: 0.35, alpha: 1)]),
        ("checkmark.circle.fill", [.white, NSColor(red: 0.20, green: 0.78, blue: 0.35, alpha: 1)]),
        ("xmark.circle", [NSColor(red: 0.90, green: 0.25, blue: 0.25, alpha: 1)]),
    ]
    let cardWidth = 600.0, cardHeight = 160.0, gap = 36.0
    let total = cardHeight * 3 + gap * 2
    var y = (size + total) / 2 - cardHeight
    for (name, colors) in statuses {
        let card = NSRect(x: (size - cardWidth) / 2, y: y, width: cardWidth, height: cardHeight)
        NSColor(white: 1, alpha: 0.95).setFill()
        NSBezierPath(roundedRect: card, xRadius: 36, yRadius: 36).fill()

        if let mark = symbol(name, size: 92, colors: colors) {
            drawCentred(mark, at: NSPoint(x: card.minX + 95, y: card.midY))
        }

        // Two bars for the host name and details.
        NSColor(red: 0.07, green: 0.16, blue: 0.40, alpha: 0.85).setFill()
        NSBezierPath(roundedRect: NSRect(x: card.minX + 175, y: card.midY + 8, width: 300, height: 30),
                     xRadius: 15, yRadius: 15).fill()
        NSColor(red: 0.07, green: 0.16, blue: 0.40, alpha: 0.35).setFill()
        NSBezierPath(roundedRect: NSRect(x: card.minX + 175, y: card.midY - 40, width: 200, height: 24),
                     xRadius: 12, yRadius: 12).fill()

        y -= cardHeight + gap
    }
    return true
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
