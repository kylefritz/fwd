import AppKit

/// fwd's mark: two solid, rounded chevrons, `>>`. The menu bar glyph and the
/// app icon are both drawn from this one shape.
enum FwdMark {
    /// The chevrons as thick round-capped strokes, in a unit square (y up).
    static func path(in rect: CGRect) -> CGPath {
        let s = min(rect.width, rect.height)
        let origin = CGPoint(x: rect.midX - s / 2, y: rect.midY - s / 2)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: origin.x + x * s, y: origin.y + y * s) }
        let line = CGMutablePath()
        // Each chevron is 0.28 wide plus the stroke; the pair is centred.
        for dx in [0.0, 0.33] {
            line.move(to: p(0.195 + dx, 0.80))
            line.addLine(to: p(0.475 + dx, 0.50))
            line.addLine(to: p(0.195 + dx, 0.20))
        }
        return line.copy(strokingWithWidth: 0.15 * s, lineCap: .round, lineJoin: .round, miterLimit: 10)
    }

    enum Look { case idle, forwarding, attention, updateReady }

    /// An 18 pt template image for the menu bar. Idle is the mark at half
    /// strength; attention and a waiting update add a badge, cut out of
    /// the mark so it reads at this size.
    static func menuBarImage(_ look: Look) -> NSImage {
        let size = NSSize(width: 22, height: 18)
        let image = NSImage(size: size, flipped: false) { bounds in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            let markRect = CGRect(x: 0, y: 0, width: 18, height: 18).insetBy(dx: 0.5, dy: 0.5)
            cg.addPath(path(in: markRect))
            cg.setFillColor(NSColor.black.withAlphaComponent(look == .idle ? 0.5 : 1).cgColor)
            cg.fillPath()

            guard look == .attention || look == .updateReady else { return true }
            let badge = CGRect(x: bounds.maxX - 6, y: look == .attention ? bounds.maxY - 6 : 0, width: 6, height: 6)
            cg.setBlendMode(.clear)
            cg.fillEllipse(in: badge.insetBy(dx: -1.5, dy: -1.5))
            cg.setBlendMode(.normal)
            cg.setFillColor(NSColor.black.cgColor)
            cg.fillEllipse(in: badge)
            return true
        }
        image.isTemplate = true
        return image
    }

    /// The app icon at `pixels` square: white chevrons on a violet-to-purple
    /// rounded square, sized to macOS's icon grid.
    static func appIcon(pixels: Int) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let cg = context.cgContext
        let s = CGFloat(pixels)
        // Apple's grid: an 824/1024 rounded square centred on the canvas.
        let tile = CGRect(x: 0, y: 0, width: s, height: s).insetBy(dx: s * 100 / 1024, dy: s * 100 / 1024)
        let shape = CGPath(roundedRect: tile, cornerWidth: s * 185 / 1024, cornerHeight: s * 185 / 1024, transform: nil)

        cg.saveGState()
        cg.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.03,
                     color: NSColor.black.withAlphaComponent(0.3).cgColor)
        cg.addPath(shape)
        cg.setFillColor(NSColor.black.cgColor)
        cg.fillPath()
        cg.restoreGState()

        cg.saveGState()
        cg.addPath(shape)
        cg.clip()
        let colors = [NSColor(srgbRed: 0.72, green: 0.52, blue: 1.00, alpha: 1).cgColor,
                      NSColor(srgbRed: 0.42, green: 0.22, blue: 0.86, alpha: 1).cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
            cg.drawLinearGradient(gradient, start: CGPoint(x: tile.minX, y: tile.maxY),
                                  end: CGPoint(x: tile.maxX, y: tile.minY), options: [])
        }
        cg.restoreGState()

        cg.saveGState()
        cg.setShadow(offset: CGSize(width: 0, height: -s * 0.008), blur: s * 0.02,
                     color: NSColor.black.withAlphaComponent(0.25).cgColor)
        cg.addPath(path(in: tile.insetBy(dx: tile.width * 0.17, dy: tile.height * 0.17)))
        cg.setFillColor(NSColor.white.cgColor)
        cg.fillPath()
        cg.restoreGState()
        context.flushGraphics()
        return rep
    }

    /// Writes an `.iconset` folder for `iconutil`. Used by scripts/bundle.sh.
    static func writeIconset(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
                guard let png = appIcon(pixels: points * scale)?.representation(using: .png, properties: [:]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                try png.write(to: dir.appendingPathComponent(name))
            }
        }
    }
}
