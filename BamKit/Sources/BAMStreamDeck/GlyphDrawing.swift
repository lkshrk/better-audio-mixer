import AppKit

@MainActor
enum GlyphDrawing {

    static let emojiSymbols: [String: String] = [
        "🎧": "headphones", "🎤": "mic.fill", "🎙": "mic.fill",
        "🎵": "music.note", "🎶": "music.note.list",
        "🎮": "gamecontroller.fill", "🕹": "gamecontroller.fill",
        "🌐": "globe", "🌍": "globe.europe.africa.fill", "🌎": "globe.americas.fill",
        "🌏": "globe.asia.australia.fill",
        "💬": "bubble.left.fill", "🗣": "person.wave.2.fill",
        "📺": "tv", "🎬": "film", "🎥": "video.fill", "📹": "video.fill",
        "🔊": "speaker.wave.3.fill", "🔈": "speaker.fill", "🔔": "bell.fill", "📻": "radio",
        "🎹": "pianokeys", "🎸": "guitars",
        "💻": "laptopcomputer", "🖥": "desktopcomputer", "📱": "iphone",
        "📞": "phone.fill", "☎": "phone.fill", "🤖": "cpu.fill",
    ]

    /// SF Symbol standing in for `emoji` when a mono line glyph is wanted; nil when there is no equivalent.
    static func symbolName(forEmoji emoji: String) -> String? {
        let stripped = emoji.unicodeScalars.filter { !Self.isPresentationModifier($0) }
        return emojiSymbols[String(String.UnicodeScalarView(stripped))]
    }

    private static func isPresentationModifier(_ scalar: Unicode.Scalar) -> Bool {
        (0xFE00...0xFE0F).contains(scalar.value) || (0x1F3FB...0x1F3FF).contains(scalar.value)
    }

    /// Emoji (colour, or mono in the text colour) or a white SF Symbol centred in `rect`; false when it cannot draw.
    @discardableResult
    static func draw(_ glyph: KeyImage.Glyph, in rect: NSRect, scale: CGFloat, mono: Bool = false) -> Bool {
        guard let cg = NSGraphicsContext.current?.cgContext else { return false }
        cg.saveGState()
        defer { cg.restoreGState() }
        cg.beginTransparencyLayer(auxiliaryInfo: nil)
        defer { cg.endTransparencyLayer() }
        switch glyph {
        case .emoji(let value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }
            if mono, let name = symbolName(forEmoji: trimmed) {
                return drawSymbol(name, in: rect, scale: scale)
            }
            let font = NSFont.systemFont(ofSize: rect.height * scale)
            let str = NSAttributedString(string: trimmed, attributes: [.font: font])
            let size = str.size()
            str.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
            if mono {
                Palette.text.nsColor.set()
                rect.fill(using: .sourceAtop)
            }
            return true
        case .symbol(let name):
            return drawSymbol(name, in: rect, scale: scale)
        }
    }

    private static func drawSymbol(_ name: String, in rect: NSRect, scale: CGFloat) -> Bool {
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return false }
        let config = NSImage.SymbolConfiguration(pointSize: rect.height * scale, weight: .medium)
        let image = symbol.withSymbolConfiguration(config) ?? symbol
        let size = image.size
        let fit = min(rect.width / max(size.width, 1), rect.height / max(size.height, 1))
        let dest = NSRect(x: rect.midX - size.width * fit / 2,
                          y: rect.midY - size.height * fit / 2,
                          width: size.width * fit, height: size.height * fit)
        image.draw(in: dest, from: .zero, operation: .sourceOver, fraction: 1)
        Palette.text.nsColor.set()
        dest.fill(using: .sourceAtop)
        return true
    }

    /// Glyph, else the monogram in the accent colour, so every caller shares one fallback.
    static func drawGlyphOrMonogram(_ glyph: KeyImage.Glyph?, monogram: String, accent: RGB,
                                    in rect: NSRect, scale: CGFloat, mono: Bool = false) {
        if let glyph, draw(glyph, in: rect, scale: scale, mono: mono) { return }
        let font = NSFont.systemFont(ofSize: rect.height * 0.5, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: accent.nsColor]
        let s = NSAttributedString(string: monogram, attributes: attrs)
        let size = s.size()
        s.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }

    /// Red diagonal across `rect`, bottom-left to top-right, the shared muted mark.
    static func drawSlash(in rect: NSRect, width: CGFloat) {
        let inset = rect.width * 0.12
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX + inset, y: rect.minY + inset))
        path.line(to: NSPoint(x: rect.maxX - inset, y: rect.maxY - inset))
        path.lineWidth = width
        path.lineCapStyle = .round
        Palette.mutedRed.nsColor.setStroke()
        path.stroke()
    }
}

@MainActor
enum PNGCanvas {

    /// Bitmap-backed context rather than `NSImage.lockFocus`: its TIFF path fails in the faceless plugin process.
    static func render(width: Int, height: Int, _ body: () -> Bool) -> String? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high
        ctx.cgContext.clear(CGRect(x: 0, y: 0, width: width, height: height))
        let ok = body()
        ctx.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard ok, let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return "data:image/png;base64," + png.base64EncodedString()
    }

    private static let svgAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-_.~ =:/,;()'\"<>")
        return set
    }()

    /// Percent-encoded UTF-8, the form Stream Deck documents for inline SVG.
    static func svgDataURI(_ svg: String) -> String {
        let compact = svg.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")
        let encoded = compact.addingPercentEncoding(withAllowedCharacters: svgAllowed) ?? compact
        return "data:image/svg+xml;charset=utf8," + encoded
    }
}
