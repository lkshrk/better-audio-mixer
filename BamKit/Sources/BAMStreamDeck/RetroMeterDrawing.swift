import AppKit
import CoreText
import Foundation

/// Gauge geometry shared by the retro key and dial, plus the dial LCD canvases and live layers.
@MainActor
enum RetroMeterDrawing {
    private static var lcdLevelBarSVGCache: [String: String] = [:]

    /// Circular arc from 165° (silence) to 15° (clip) in bottom-left coordinates.
    struct Gauge {
        var center: NSPoint
        var radius: CGFloat
        var needleLength: CGFloat { radius - 12 }
        var hubRadius: CGFloat { radius * 0.075 }

        func offset(dx: CGFloat, dy: CGFloat) -> Gauge {
            Gauge(center: NSPoint(x: center.x + dx, y: center.y + dy), radius: radius)
        }
    }

    static let sweepStart: CGFloat = 165
    static let sweepEnd: CGFloat = 15
    static let tickCount = 11

    static let keyGauge = Gauge(center: NSPoint(x: 72, y: 16), radius: 62)
    static let lcdSize = NSSize(width: 200, height: 100)
    static let lcdGauge = Gauge(center: NSPoint(x: 100, y: 2), radius: 58)
    static let lcdNeedleLayer = NSRect(x: 0, y: 0, width: 200, height: 64)
    static let lcdHeaderOrigin = NSPoint(x: 8, y: 66)
    static let lcdValueRect = NSRect(x: 112, y: 66, width: 80, height: 28)
    static let lcdChannelBar = NSRect(x: 8, y: 40, width: 184, height: 16)
    static let lcdChannelRail = NSRect(x: 8, y: 20, width: 184, height: 8)
    static let lcdLeftBar = NSRect(x: 26, y: 42, width: 166, height: 14)
    static let lcdRightBar = NSRect(x: 26, y: 20, width: 166, height: 14)

    static func angle(for fraction: CGFloat) -> CGFloat {
        (sweepStart - (sweepStart - sweepEnd) * max(0, min(1, fraction))) * .pi / 180
    }

    static func point(center: NSPoint, radius: CGFloat, angle: CGFloat) -> NSPoint {
        NSPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
    }

    // MARK: - Gauge face (raster)

    static func drawGauge(_ g: Gauge, volumeFraction: CGFloat?, accent: RGB, muted: Bool) {
        let arc = NSBezierPath()
        arc.appendArc(withCenter: g.center, radius: g.radius, startAngle: sweepStart, endAngle: sweepEnd, clockwise: true)
        arc.lineWidth = 2
        Palette.rail.nsColor.setStroke()
        arc.stroke()

        for i in 0..<tickCount {
            let frac = CGFloat(i) / CGFloat(tickCount - 1)
            let major = i % 5 == 0
            let a = angle(for: frac)
            let path = NSBezierPath()
            path.move(to: point(center: g.center, radius: g.radius - 1, angle: a))
            path.line(to: point(center: g.center, radius: g.radius - (major ? 10 : 7), angle: a))
            path.lineWidth = major ? 2 : 1.2
            tickColor(frac, muted: muted).setStroke()
            path.stroke()
        }

        if let volumeFraction {
            let a = angle(for: volumeFraction)
            let path = NSBezierPath()
            path.move(to: point(center: g.center, radius: g.radius - 3, angle: a))
            path.line(to: point(center: g.center, radius: g.radius + 4, angle: a))
            path.lineWidth = 3.5
            path.lineCapStyle = .round
            (muted ? Palette.mutedRed : accent).nsColor.setStroke()
            path.stroke()
        }
    }

    private static func tickColor(_ fraction: CGFloat, muted: Bool) -> NSColor {
        if muted { return Palette.rail.nsColor }
        return fraction > Palette.segmentBands[1].upTo ? Palette.mutedRed.nsColor : Palette.tick.nsColor
    }

    /// Needle and hub as SVG elements inside a canvas `height` tall (top-down coordinates).
    static func needleSVG(_ g: Gauge, canvasHeight: CGFloat, fraction: CGFloat, muted: Bool) -> String {
        let end = point(center: g.center, radius: g.needleLength, angle: angle(for: fraction))
        let color = muted ? Palette.rail : Palette.needle
        return String(format: """
        <line x1="%.2f" y1="%.2f" x2="%.2f" y2="%.2f" stroke="%@" stroke-width="2.2" stroke-linecap="round"/> \
        <circle cx="%.2f" cy="%.2f" r="%.2f" fill="%@"/>
        """, Double(g.center.x), Double(canvasHeight - g.center.y), Double(end.x), Double(canvasHeight - end.y),
           color.hex, Double(g.center.x), Double(canvasHeight - g.center.y), Double(g.hubRadius), color.hex)
    }

    private static func peakTickSVG(_ g: Gauge, canvasHeight: CGFloat, fraction: CGFloat) -> String {
        let a = angle(for: fraction)
        let outer = point(center: g.center, radius: g.radius - 1, angle: a)
        let inner = point(center: g.center, radius: g.radius - 9, angle: a)
        return String(format: """
        <line x1="%.2f" y1="%.2f" x2="%.2f" y2="%.2f" stroke="%@" stroke-opacity="0.7" stroke-width="2" stroke-linecap="round"/>
        """, Double(outer.x), Double(canvasHeight - outer.y), Double(inner.x), Double(canvasHeight - inner.y),
           Palette.text.hex)
    }

    static func keyNeedleSVG(step: Int, muted: Bool) -> String {
        needleSVG(keyGauge, canvasHeight: KeyStyleImage.side,
                  fraction: MeterScale.fraction(step: step, steps: MeterScale.keyNeedleSteps), muted: muted)
    }

    // MARK: - Dial LCD (200×100)

    struct LCDInput: Hashable {
        var style: KeyStyleImage.KeyStyle
        var glyph: KeyImage.Glyph?
        var monogram: String
        var accent: RGB
        var name: String
        var pct: Int
        var muted: Bool
    }

    static func renderLCDStatic(_ input: LCDInput) -> String? {
        PNGCanvas.render(width: Int(lcdSize.width), height: Int(lcdSize.height)) {
            Palette.lcdBackground.nsColor.setFill()
            NSRect(origin: .zero, size: lcdSize).fill()
            KeyHeader.draw(KeyHeader.Input(glyph: input.glyph, monogram: input.monogram, accent: input.accent,
                                           name: input.name, spec: .dial, muted: input.muted),
                           at: lcdHeaderOrigin)
            drawLCDValue(pct: input.pct, muted: input.muted)
            switch input.style {
            case .channel:
                drawTrack(lcdChannelBar)
                drawVolumeRail(lcdChannelRail, pct: input.pct, muted: input.muted, accent: input.accent)
            case .meter:
                drawTrack(lcdLeftBar)
                drawSideLabel("L", rect: NSRect(x: 8, y: lcdLeftBar.minY, width: 16, height: lcdLeftBar.height))
                drawTrack(lcdRightBar)
                drawSideLabel("R", rect: NSRect(x: 8, y: lcdRightBar.minY, width: 16, height: lcdRightBar.height))
            case .retro:
                drawGauge(lcdGauge, volumeFraction: CGFloat(max(0, min(100, input.pct))) / 100,
                          accent: input.accent, muted: input.muted)
            }
            return true
        }
    }

    static func renderLCDLevelBarSVG(width: Int, height: Int, step: Int, peakStep: Int? = nil, muted: Bool) -> String {
        let normalizedStep = max(0, min(MeterScale.lcdBarSteps, step))
        let normalizedPeak = max(0, min(MeterScale.lcdBarSteps, peakStep ?? normalizedStep))
        let cacheKey = "\(width)|\(height)|\(normalizedStep)|\(normalizedPeak)|\(muted ? 1 : 0)"
        if let cached = lcdLevelBarSVGCache[cacheKey] { return cached }

        let w = Double(width), h = Double(height)
        let fillWidth = w * Double(normalizedStep) / Double(MeterScale.lcdBarSteps)
        let radius = min(2.0, h / 4)
        let stops = Palette.segmentGradientStops.map {
            "<stop offset=\"\(KeyStyleImage.f($0.offset * 100))%\" stop-color=\"\($0.color.hex)\"/>"
        }.joined()
        let fill = normalizedStep > 0
            ? "<rect x=\"0\" y=\"0\" width=\"\(KeyStyleImage.f(fillWidth))\" height=\"\(height)\" rx=\"\(KeyStyleImage.f(radius))\" fill=\"url(#meter)\"/>"
            : ""
        var peak = ""
        if normalizedPeak > 0 && !muted {
            let peakX = min(w - 2, max(1, w * Double(normalizedPeak) / Double(MeterScale.lcdBarSteps)))
            peak = "<rect x=\"\(KeyStyleImage.f(peakX - 1.5))\" y=\"0\" width=\"4\" height=\"\(height)\" fill=\"\(Palette.lcdBackground.hex)\"/>"
                + "<rect x=\"\(KeyStyleImage.f(peakX - 0.5))\" y=\"0\" width=\"2\" height=\"\(height)\" fill=\"\(Palette.text.hex)\"/>"
        }
        let svg = """
        <svg width="\(width)" height="\(height)" viewBox="0 0 \(width) \(height)" xmlns="http://www.w3.org/2000/svg">
        <defs><linearGradient id="meter" x1="0" y1="0" x2="\(width)" y2="0" gradientUnits="userSpaceOnUse">\(stops)</linearGradient></defs>
        <rect x="0" y="0" width="\(width)" height="\(height)" rx="\(KeyStyleImage.f(radius))" fill="\(Palette.rail.hex)"/>
        \(fill)
        \(peak)
        </svg>
        """
        let uri = PNGCanvas.svgDataURI(svg)
        if lcdLevelBarSVGCache.count > 512 { lcdLevelBarSVGCache.removeAll(keepingCapacity: true) }
        lcdLevelBarSVGCache[cacheKey] = uri
        return uri
    }

    /// Needle layer in `lcdNeedleLayer` coordinates; the peak tick is left out at step 0.
    static func renderRetroLCDNeedleSVG(step: Int, peakStep: Int = 0, muted: Bool) -> String {
        let layer = lcdNeedleLayer
        let gauge = lcdGauge.offset(dx: -layer.minX, dy: -layer.minY)
        let fraction = MeterScale.fraction(step: step, steps: MeterScale.lcdNeedleSteps)
        var body = needleSVG(gauge, canvasHeight: layer.height, fraction: fraction, muted: muted)
        if peakStep > 0 && !muted {
            body = peakTickSVG(gauge, canvasHeight: layer.height,
                               fraction: MeterScale.fraction(step: peakStep, steps: MeterScale.lcdNeedleSteps)) + body
        }
        let svg = """
        <svg width="\(Int(layer.width))" height="\(Int(layer.height))" viewBox="0 0 \(Int(layer.width)) \(Int(layer.height))" xmlns="http://www.w3.org/2000/svg">
        \(body)
        </svg>
        """
        return PNGCanvas.svgDataURI(svg)
    }

    // MARK: - LCD pieces (raster, bottom-left coordinates)

    private static func drawLCDValue(pct: Int, muted: Bool) {
        let para = NSMutableParagraphStyle()
        para.alignment = .right
        let text = muted ? "Muted" : "\(max(0, min(100, pct)))%"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: muted ? 16 : 23, weight: .heavy),
            .foregroundColor: (muted ? Palette.mutedRed : Palette.text).nsColor,
            .paragraphStyle: para,
        ]
        let s = NSAttributedString(string: text, attributes: attrs)
        let h = s.size().height
        s.draw(in: NSRect(x: lcdValueRect.minX, y: lcdValueRect.midY - h / 2, width: lcdValueRect.width, height: h))
    }

    private static func drawTrack(_ rect: NSRect) {
        Palette.rail.nsColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
    }

    private static func drawVolumeRail(_ rect: NSRect, pct: Int, muted: Bool, accent: RGB) {
        Palette.rail.nsColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
        let frac = CGFloat(max(0, min(100, pct))) / 100
        guard frac > 0 else { return }
        (muted ? Palette.mutedRed : accent).nsColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.minY, width: rect.width * frac, height: rect.height),
                     xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
    }

    private static func drawSideLabel(_ text: String, rect: NSRect) {
        let font = NSFont.systemFont(ofSize: 11, weight: .heavy)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Palette.tick.nsColor]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        cg.saveGState()
        cg.textMatrix = .identity
        cg.textPosition = CGPoint(x: rect.midX - width / 2, y: rect.midY - (font.ascender + font.descender) / 2)
        CTLineDraw(line, cg)
        cg.restoreGState()
    }
}
