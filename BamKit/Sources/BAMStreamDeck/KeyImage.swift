import AppKit
import Foundation

/// One glyph centred on a transparent key, with a red slash while muted; no tile, no chip.
@MainActor
enum KeyImage {

    enum Glyph: Hashable {
        case emoji(String)
        case symbol(String)
    }

    private static let side: CGFloat = 144
    private static let glyphBox = NSRect(x: side * 0.17, y: side * 0.17, width: side * 0.66, height: side * 0.66)

    /// Nil for an unrenderable glyph.
    static func render(_ glyph: Glyph, muted: Bool, mono: Bool = false) -> String? {
        PNGCanvas.render(width: Int(side), height: Int(side)) {
            guard GlyphDrawing.draw(glyph, in: glyphBox, scale: 0.91, mono: mono) else { return false }
            if muted { GlyphDrawing.drawSlash(in: glyphBox.insetBy(dx: -4, dy: -4), width: side * 0.08) }
            return true
        }
    }
}
