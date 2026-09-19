import AppKit

/// Icon + Title-case name band shared by every styled key and dial canvas, rasterized once per variant.
@MainActor
enum KeyHeader {

    struct Spec: Hashable {
        let width: CGFloat
        let icon: CGFloat
        let font: CGFloat
        var height: CGFloat { icon }
        var gap: CGFloat { icon * 0.28 }

        static let key = Spec(width: 116, icon: 32, font: 15)
        static let compact = Spec(width: 116, icon: 28, font: 13)
        static let dial = Spec(width: 104, icon: 28, font: 13)
    }

    struct Input: Hashable {
        let glyph: KeyImage.Glyph?
        let monogram: String
        let accent: RGB
        let name: String
        let spec: Spec
        var muted = false
    }

    private static var cache: [Input: String] = [:]

    static func render(_ input: Input) -> String? {
        if let cached = cache[input] { return cached }
        let image = PNGCanvas.render(width: Int(input.spec.width), height: Int(input.spec.height)) {
            draw(input, at: .zero)
            return true
        }
        if cache.count > 128 { cache.removeAll(keepingCapacity: true) }
        cache[input] = image
        return image
    }

    /// Draws the header into the current context with its bottom-left corner at `origin`.
    static func draw(_ input: Input, at origin: NSPoint) {
        let spec = input.spec
        let iconRect = NSRect(x: origin.x, y: origin.y, width: spec.icon, height: spec.icon)
        GlyphDrawing.drawGlyphOrMonogram(input.glyph, monogram: input.monogram, accent: input.accent,
                                         in: iconRect.insetBy(dx: 1, dy: 1), scale: 0.84, mono: true)
        if input.muted { GlyphDrawing.drawSlash(in: iconRect, width: spec.icon * 0.11) }

        let nameX = origin.x + spec.icon + spec.gap
        let nameWidth = spec.width - spec.icon - spec.gap
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: spec.font, weight: .bold),
            .foregroundColor: Palette.text.nsColor,
            .paragraphStyle: para,
        ]
        let text = NSAttributedString(string: displayName(input.name), attributes: attrs)
        let h = text.size().height
        text.draw(in: NSRect(x: nameX, y: iconRect.midY - h / 2, width: nameWidth, height: h))
    }

    static func displayName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "--" : trimmed
    }

    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" })
        let chars = words.prefix(2).compactMap { $0.first }
        return chars.isEmpty ? "?" : String(chars).uppercased()
    }
}
