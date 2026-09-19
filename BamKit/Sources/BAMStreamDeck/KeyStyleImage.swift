import AppKit
import Foundation

/// Styled keypad key as SVG: charcoal tile, cached header and value rasters, live meter or needle.
@MainActor
enum KeyStyleImage {

    enum KeyStyle: String {
        case channel // volume value + segment column + volume rail
        case meter   // stereo segment bars + volume rail
        case retro   // VU gauge with live needle
    }

    struct Input: Hashable {
        var style: KeyStyle
        var glyph: KeyImage.Glyph?
        var monogram: String
        var accent: RGB
        var name: String
        var pct: Int
        var level: Float
        var leftLevel: Float?
        var rightLevel: Float?
        var muted: Bool
    }

    static let side: CGFloat = 144
    private static let tileInset: CGFloat = 4
    private static let headerOrigin = NSPoint(x: 14, y: 12)
    static let volumeValueRect = NSRect(x: 14, y: 50, width: 100, height: 44)
    static let retroValueRect = NSRect(x: 14, y: 42, width: 116, height: 22)
    static let retroGaugeBand = NSRect(x: 4, y: 64, width: 136, height: 72)
    private static let volumeRail = NSRect(x: 20, y: 118, width: 104, height: 8)

    private static var valueCache: [String: String] = [:]
    private static var gaugeBandCache: [String: String] = [:]

    static func render(_ input: Input) -> String? {
        let header = KeyHeader.render(KeyHeader.Input(
            glyph: input.glyph, monogram: input.monogram, accent: input.accent, name: input.name,
            spec: input.style == .retro ? .compact : .key, muted: input.muted))
        let body: String?
        switch input.style {
        case .channel: body = channelBody(input)
        case .meter:   body = meterBody(input)
        case .retro:   body = retroBody(input)
        }
        guard let body else { return nil }
        let spec: KeyHeader.Spec = input.style == .retro ? .compact : .key
        let svg = """
        <svg width="144" height="144" viewBox="0 0 144 144" xmlns="http://www.w3.org/2000/svg">
        \(tile(muted: input.muted))
        \(header.map { svgImage($0, NSRect(origin: headerOrigin, size: NSSize(width: spec.width, height: spec.height))) } ?? "")
        \(body)
        </svg>
        """
        return PNGCanvas.svgDataURI(svg)
    }

    // MARK: - Shared pieces (SVG, top-down coordinates)

    private static func tile(muted: Bool) -> String {
        let outer = "<rect x=\"\(f(tileInset))\" y=\"\(f(tileInset))\" width=\"\(f(side - 2 * tileInset))\" height=\"\(f(side - 2 * tileInset))\" rx=\"16\" fill=\"\(Palette.tile.hex)\" stroke=\"\(Palette.tileBorder.hex)\" stroke-width=\"1.5\"/>"
        guard muted else { return outer }
        let w = Palette.mutedBorderWidth
        let inset = tileInset + 1 + w / 2
        return outer + "<rect x=\"\(f(inset))\" y=\"\(f(inset))\" width=\"\(f(side - 2 * inset))\" height=\"\(f(side - 2 * inset))\" rx=\"\(f(16 - inset + tileInset))\" fill=\"none\" stroke=\"\(Palette.mutedRed.hex)\" stroke-width=\"\(f(w))\"/>"
    }

    private static func svgImage(_ uri: String, _ r: NSRect, opacity: Double = 1) -> String {
        let alpha = opacity < 1 ? " opacity=\"\(f(opacity))\"" : ""
        return "<image href=\"\(uri)\" x=\"\(f(r.minX))\" y=\"\(f(r.minY))\" width=\"\(f(r.width))\" height=\"\(f(r.height))\" preserveAspectRatio=\"xMidYMid meet\"\(alpha)/>"
    }

    private static func svgValue(pct: Int, rect: NSRect, fontSize: CGFloat, muted: Bool) -> String {
        guard let image = cachedValue(pct: pct, rect: rect, fontSize: fontSize) else { return "" }
        return svgImage(image, rect, opacity: muted ? Palette.mutedValueOpacity : 1)
    }

    private static func cachedValue(pct: Int, rect: NSRect, fontSize: CGFloat) -> String? {
        let clamped = max(0, min(100, pct))
        let key = "\(clamped)|\(Int(fontSize))|\(Int(rect.width))"
        if let cached = valueCache[key] { return cached }
        let image = PNGCanvas.render(width: Int(rect.width), height: Int(rect.height)) {
            let para = NSMutableParagraphStyle()
            para.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .heavy),
                .foregroundColor: Palette.text.nsColor,
                .paragraphStyle: para,
            ]
            let s = NSAttributedString(string: "\(clamped)%", attributes: attrs)
            let h = s.size().height
            s.draw(in: NSRect(x: 0, y: (rect.height - h) / 2, width: rect.width, height: h))
            return true
        }
        valueCache[key] = image
        return image
    }

    private static func svgVolumeRail(pct: Int, accent: RGB) -> String {
        let fillW = volumeRail.width * CGFloat(max(0, min(100, pct))) / 100
        let base = "<rect x=\"\(f(volumeRail.minX))\" y=\"\(f(volumeRail.minY))\" width=\"\(f(volumeRail.width))\" height=\"\(f(volumeRail.height))\" rx=\"4\" fill=\"\(Palette.rail.hex)\"/>"
        guard fillW > 1 else { return base }
        return base + "<rect x=\"\(f(volumeRail.minX))\" y=\"\(f(volumeRail.minY))\" width=\"\(f(fillW))\" height=\"\(f(volumeRail.height))\" rx=\"4\" fill=\"\(accent.hex)\"/>"
    }

    private static func svgSegments(rect: NSRect, count: Int, lit: Int, vertical: Bool) -> String {
        let gap: CGFloat = 2
        let span = vertical ? rect.height : rect.width
        let seg = (span - gap * CGFloat(count - 1)) / CGFloat(count)
        return (0..<count).map { i in
            let p = CGFloat(i) / CGFloat(count - 1)
            let color = i < lit ? Palette.segment(p).hex : Palette.rail.hex
            let r = vertical
                ? NSRect(x: rect.minX, y: rect.maxY - seg - CGFloat(i) * (seg + gap), width: rect.width, height: seg)
                : NSRect(x: rect.minX + CGFloat(i) * (seg + gap), y: rect.minY, width: seg, height: rect.height)
            return "<rect x=\"\(f(r.minX))\" y=\"\(f(r.minY))\" width=\"\(f(r.width))\" height=\"\(f(r.height))\" rx=\"1.5\" fill=\"\(color)\"/>"
        }.joined(separator: " ")
    }

    private static func svgLabel(_ text: String, x: CGFloat, midY: CGFloat) -> String {
        "<text x=\"\(f(x))\" y=\"\(f(midY))\" text-anchor=\"middle\" dominant-baseline=\"central\" font-family=\"-apple-system,BlinkMacSystemFont,'SF Pro Text',sans-serif\" font-size=\"13\" font-weight=\"800\" fill=\"\(Palette.tick.hex)\">\(text)</text>"
    }

    static func f(_ value: Double) -> String { String(format: "%.2f", value) }
    static func f(_ value: CGFloat) -> String { f(Double(value)) }

    // MARK: - Styles

    private static func channelBody(_ input: Input) -> String {
        let count = MeterScale.segmentCount(for: .channel)
        let lit = MeterScale.quantize(input.level, steps: count, muted: input.muted)
        return [
            svgValue(pct: input.pct, rect: volumeValueRect, fontSize: 34, muted: input.muted),
            svgSegments(rect: NSRect(x: 119, y: 50, width: 8, height: 44), count: count, lit: lit, vertical: true),
            svgVolumeRail(pct: input.pct, accent: input.accent),
        ].joined(separator: " ")
    }

    private static func meterBody(_ input: Input) -> String {
        let count = MeterScale.segmentCount(for: .meter)
        let left = MeterScale.quantize(input.leftLevel ?? input.level, steps: count, muted: input.muted)
        let right = MeterScale.quantize(input.rightLevel ?? input.level, steps: count, muted: input.muted)
        let leftBar = NSRect(x: 34, y: 58, width: 92, height: 12)
        let rightBar = NSRect(x: 34, y: 82, width: 92, height: 12)
        return [
            svgLabel("L", x: 22, midY: leftBar.midY),
            svgSegments(rect: leftBar, count: count, lit: left, vertical: false),
            svgLabel("R", x: 22, midY: rightBar.midY),
            svgSegments(rect: rightBar, count: count, lit: right, vertical: false),
            svgVolumeRail(pct: input.pct, accent: input.accent),
        ].joined(separator: " ")
    }

    private static func retroBody(_ input: Input) -> String? {
        guard let band = cachedGaugeBand(pct: input.pct, accent: input.accent, muted: input.muted) else { return nil }
        let step = MeterScale.quantize(input.level, steps: MeterScale.keyNeedleSteps, muted: input.muted)
        return [
            svgValue(pct: input.pct, rect: retroValueRect, fontSize: 24, muted: input.muted),
            svgImage(band, retroGaugeBand),
            RetroMeterDrawing.keyNeedleSVG(step: step, muted: input.muted),
        ].joined(separator: " ")
    }

    /// Arc, ticks and volume tick only, rasterized at the band size so the SVG carries no empty face.
    static func cachedGaugeBand(pct: Int, accent: RGB, muted: Bool) -> String? {
        let key = "\(max(0, min(100, pct)))|\(accent.hex)|\(muted)"
        if let cached = gaugeBandCache[key] { return cached }
        let band = retroGaugeBand
        let image = PNGCanvas.render(width: Int(band.width), height: Int(band.height)) {
            let gauge = RetroMeterDrawing.keyGauge.offset(dx: -band.minX, dy: -(side - band.maxY))
            RetroMeterDrawing.drawGauge(gauge, volumeFraction: CGFloat(max(0, min(100, pct))) / 100,
                                        accent: accent, muted: muted)
            return true
        }
        if gaugeBandCache.count > 64 { gaugeBandCache.removeAll(keepingCapacity: true) }
        gaugeBandCache[key] = image
        return image
    }
}
