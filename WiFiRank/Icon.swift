// WiFi Rank's icon: Wi-Fi arcs above the winner's step of a podium.
// Drawn in code so the app icon (every size) and the menu bar icon always match.
import AppKit

private func hexColor(_ v: Int) -> NSColor {
    NSColor(srgbRed: CGFloat(v >> 16 & 255) / 255, green: CGFloat(v >> 8 & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
}

/// The podium and arcs inside `r`. `gold` colours the winner's step; `numbered` adds a "1"
/// on it, which only reads at larger sizes.
private func podium(in r: NSRect, ink: NSColor, gold: NSColor, goldDark: NSColor?, numbered: Bool) {
    func x(_ v: CGFloat) -> CGFloat { r.minX + v * r.width }
    func y(_ v: CGFloat) -> CGFloat { r.minY + v * r.height }
    func s(_ v: CGFloat) -> CGFloat { v * r.width }
    func step(_ left: CGFloat, _ height: CGFloat) -> NSBezierPath {
        NSBezierPath(roundedRect: NSRect(x: x(left), y: y(0.04), width: s(0.27), height: s(height)), xRadius: s(0.045), yRadius: s(0.045))
    }
    ink.setFill()
    step(0.04, 0.30).fill()   // second place
    step(0.69, 0.20).fill()   // third place
    let winner = step(0.365, 0.45)
    if let goldDark {
        NSGradient(starting: gold, ending: goldDark)!.draw(in: winner, angle: -90)
    } else {
        gold.setFill()
        winner.fill()
    }
    if numbered {
        let f = NSFont.systemFont(ofSize: s(0.21), weight: .heavy)
        let one = NSAttributedString(string: "1", attributes: [.font: f, .foregroundColor: (goldDark ?? gold).blended(withFraction: 0.35, of: .black)!])
        let size = one.size()
        one.draw(at: NSPoint(x: x(0.5) - size.width / 2, y: y(0.04) + s(0.45) / 2 - size.height / 2))
    }
    // Wi-Fi arcs above the winner, with a clear gap over the step.
    let centre = NSPoint(x: x(0.5), y: y(0.64))
    for radius in [0.13, 0.25] {
        let arc = NSBezierPath()
        arc.appendArc(withCenter: centre, radius: s(radius), startAngle: 42, endAngle: 138, clockwise: false)
        arc.lineWidth = s(0.075)
        arc.lineCapStyle = .round
        ink.setStroke()
        arc.stroke()
    }
    ink.setFill()
    NSBezierPath(ovalIn: NSRect(x: centre.x - s(0.052), y: centre.y - s(0.052), width: s(0.104), height: s(0.104))).fill()
}

/// The app icon at a given pixel size: a blue rounded tile on Apple's icon grid, soft shadow,
/// glass highlight, white podium with a gold winner.
func makeAppIcon(size: CGFloat = 512) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
        let tile = NSRect(x: size * 0.098, y: size * 0.098, width: size * 0.804, height: size * 0.804)
        let shape = NSBezierPath(roundedRect: tile, xRadius: size * 0.185, yRadius: size * 0.185)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = size * 0.028
        shadow.shadowOffset = NSSize(width: 0, height: -size * 0.012)
        shadow.set()
        hexColor(0x1E4FD8).setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(starting: hexColor(0x5B9DFF), ending: hexColor(0x1D47C9))!.draw(in: shape, angle: -90)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        NSGradient(starting: NSColor.white.withAlphaComponent(0.24), ending: NSColor.white.withAlphaComponent(0))!
            .draw(in: NSRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height / 2), angle: -90)
        NSGraphicsContext.restoreGraphicsState()
        let glyph = tile.insetBy(dx: tile.width * 0.19, dy: tile.height * 0.19)
        podium(in: glyph, ink: .white, gold: hexColor(0xFFD54A), goldDark: hexColor(0xF5A300), numbered: size >= 96)
        return true
    }
}

/// The menu bar icon: the same podium as a black-and-white template, so macOS tints it for
/// light and dark menu bars. Proportions tuned for 18 points.
func makeMenuBarIcon() -> NSImage {
    let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { r in
        podium(in: r.insetBy(dx: 0.5, dy: 0.5), ink: .black, gold: .black, goldDark: nil, numbered: false)
        return true
    }
    img.isTemplate = true
    img.accessibilityDescription = "WiFi Rank"
    return img
}
