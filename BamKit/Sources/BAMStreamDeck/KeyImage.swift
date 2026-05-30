import AppKit
import Foundation

/// Renders a Stream Deck key image: a single glyph (emoji or SF Symbol) centered on
/// a transparent background, with an optional red "muted" slash drawn corner-to-corner.
/// Output is a `data:image/png;base64,…` URI ready for `setImage`.
///
/// Draws into an `NSBitmapImageRep`-backed context rather than `NSImage.lockFocus`,
/// because the latter's `tiffRepresentation` fails in the plugin's faceless process
/// ("CGImageDestinationFinalize failed for public.tiff").
enum KeyImage {

    enum Glyph {
        case emoji(String)
        case symbol(String) // SF Symbol name
    }

    private static let side = 144 // Stream Deck @2x key resolution

    /// Returns nil if the glyph can't be rendered (e.g. unknown symbol, empty emoji).
    /// `tint` forces the glyph to a white silhouette — used on the dark dial LCD
    /// where multicolor emoji (e.g. dark musical notes) read poorly.
    static func render(_ glyph: Glyph, muted: Bool, tint: Bool = false) -> String? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high

        let ok = drawGlyph(glyph, side: CGFloat(side), tint: tint)
        if ok, muted { drawSlash(side: CGFloat(side)) }

        ctx.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard ok, let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return "data:image/png;base64," + png.base64EncodedString()
    }

    private static func drawGlyph(_ glyph: Glyph, side: CGFloat, tint: Bool) -> Bool {
        switch glyph {
        case .emoji(let s):
            let trimmed = s.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return false }
            let font = NSFont.systemFont(ofSize: side * 0.6)
            let str = NSAttributedString(string: trimmed, attributes: [.font: font])
            let bounds = str.size()
            str.draw(at: NSPoint(x: (side - bounds.width) / 2,
                                 y: (side - bounds.height) / 2))
            if tint { // flatten multicolor emoji to a white silhouette
                NSColor.white.set()
                NSRect(x: 0, y: 0, width: side, height: side).fill(using: .sourceAtop)
            }
            return true
        case .symbol(let name):
            guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
                return false
            }
            let config = NSImage.SymbolConfiguration(pointSize: side * 0.5, weight: .regular)
            let img = symbol.withSymbolConfiguration(config) ?? symbol
            let s = img.size
            let scale = min(side * 0.66 / max(s.width, 1), side * 0.66 / max(s.height, 1))
            let w = s.width * scale, h = s.height * scale
            let dest = NSRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h)
            img.draw(in: dest, from: .zero, operation: .sourceOver, fraction: 1.0)
            // Tint the (monochrome) symbol white so it reads on the dark key.
            NSColor.white.set()
            dest.fill(using: .sourceAtop)
            return true
        }
    }

    private static func drawSlash(side: CGFloat) {
        let inset = side * 0.18
        let path = NSBezierPath()
        path.move(to: NSPoint(x: inset, y: inset))
        path.line(to: NSPoint(x: side - inset, y: side - inset))
        path.lineWidth = side * 0.09
        path.lineCapStyle = .round
        NSColor.systemRed.setStroke()
        path.stroke()
    }
}
