import AppKit
import Foundation

/// Renders a rich Stream Deck *keypad* key for a device/master volume control.
/// Each style keeps the group identity prominent and treats the live meter as part
/// of the control language instead of secondary decoration.
///
/// Output is a data URI ready for `setImage`. Retro uses a PNG because the dial texture
/// is raster-heavy; segmented channel/meter styles can also render as SVG to avoid
/// rebuilding and sending a full key PNG for each live meter step.
@MainActor
enum KeyStyleImage {

    enum KeyStyle: String {
        case channel // compact channel strip: group identity + live meter + volume rail
        case meter   // meter-focused tile: larger live signal display + volume marker
        case retro   // VU-style gauge with live needle + red volume needle
    }

    private static let side: CGFloat = 144
    private static let header = HeaderLayout(icon: NSRect(x: 16, y: top(42), width: 28, height: 28),
                                             nameX: 52, nameTopY: 21, nameWidth: 74,
                                             iconFontSize: 14)
    private static let volumeRail = NSRect(x: 26, y: 16, width: 92, height: 7)
    private static let volumeValueRect = NSRect(x: 14, y: top(94), width: 112, height: 50)
    private static var tintedIconCache: [String: String] = [:]
    private static var volumeValueCache: [Int: String] = [:]

    private struct HeaderLayout {
        let icon: NSRect
        let nameX: CGFloat
        let nameTopY: CGFloat
        let nameWidth: CGFloat
        let iconFontSize: CGFloat
    }

    static func render(style: KeyStyle, glyph: KeyImage.Glyph? = nil, monogram: String, accent: NSColor,
                       name: String, pct: Int, level: Float, leftLevel: Float? = nil,
                       rightLevel: Float? = nil, muted: Bool) -> String? {
        let px = Int(side)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high

        drawBackground()
        switch style {
        case .channel: drawChannel(glyph: glyph, monogram: monogram, accent: accent, name: name, pct: pct, level: level, muted: muted)
        case .meter:   drawMeterFocus(glyph: glyph, monogram: monogram, accent: accent, name: name, pct: pct,
                                       leftLevel: leftLevel ?? level, rightLevel: rightLevel ?? level, muted: muted)
        case .retro:   drawRetro(glyph: glyph, monogram: monogram, accent: accent, name: name, pct: pct, level: level, muted: muted)
        }

        ctx.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return "data:image/png;base64," + png.base64EncodedString()
    }

    static func renderOptimized(style: KeyStyle, glyph: KeyImage.Glyph? = nil,
                                monogram: String, accent: NSColor, name: String,
                                pct: Int, level: Float, leftLevel: Float? = nil,
                                rightLevel: Float? = nil, muted: Bool) -> String? {
        switch style {
        case .channel:
            return renderChannelSVG(glyph: glyph, monogram: monogram, accent: accent,
                                    name: name, pct: pct, level: level, muted: muted)
        case .meter:
            return renderMeterSVG(glyph: glyph, monogram: monogram, accent: accent,
                                  name: name, pct: pct, leftLevel: leftLevel ?? level,
                                  rightLevel: rightLevel ?? level, muted: muted)
        case .retro:
            return render(style: style, glyph: glyph, monogram: monogram, accent: accent,
                          name: name, pct: pct, level: level, leftLevel: leftLevel,
                          rightLevel: rightLevel, muted: muted)
        }
    }

    // MARK: - Shared

    private static let mutedRed = NSColor(calibratedRed: 1.0, green: 0.30, blue: 0.30, alpha: 1)

    /// Convert a top-down y offset into the bottom-left coordinate space.
    private static func top(_ y: CGFloat) -> CGFloat { side - y }

    private static func drawBackground() {
        NSGraphicsContext.current?.cgContext.clear(CGRect(x: 0, y: 0, width: side, height: side))
    }

    private static func svgDataURI(_ svg: String) -> String {
        "data:image/svg+xml;base64," + Data(svg.utf8).base64EncodedString()
    }

    private static func escapedXML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func hex(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.deviceRGB) ?? color
        let r = Int((max(0, min(1, c.redComponent)) * 255).rounded())
        let g = Int((max(0, min(1, c.greenComponent)) * 255).rounded())
        let b = Int((max(0, min(1, c.blueComponent)) * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    private static func svgY(bottom: CGFloat, height: CGFloat) -> CGFloat {
        side - bottom - height
    }

    /// Dial-style icon: transparent background, white/tinted glyph, initials fallback.
    private static func drawIcon(rect: NSRect, accent: NSColor, glyph: KeyImage.Glyph?,
                                 text: String, fontSize: CGFloat) {
        if let glyph, drawGlyph(glyph, in: rect.insetBy(dx: 2, dy: 2), tintSymbols: true) {
            return
        }
        let f = NSFont.systemFont(ofSize: fontSize, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: accent]
        let s = NSAttributedString(string: text, attributes: attrs)
        let sz = s.size()
        s.draw(at: NSPoint(x: rect.midX - sz.width / 2, y: rect.midY - sz.height / 2))
    }

    @discardableResult
    private static func drawGlyph(_ glyph: KeyImage.Glyph, in rect: NSRect, tintSymbols: Bool) -> Bool {
        switch glyph {
        case .emoji(let value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }
            let font = NSFont.systemFont(ofSize: rect.height * 0.82)
            let str = NSAttributedString(string: trimmed, attributes: [.font: font])
            let size = str.size()
            let point = NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
            str.draw(at: point)
            if tintSymbols {
                NSColor.white.set()
                rect.fill(using: .sourceAtop)
            }
            return true
        case .symbol(let name):
            guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
                return false
            }
            let config = NSImage.SymbolConfiguration(pointSize: rect.height * 0.82, weight: .regular)
            let image = symbol.withSymbolConfiguration(config) ?? symbol
            let size = image.size
            let scale = min(rect.width / max(size.width, 1), rect.height / max(size.height, 1))
            let dest = NSRect(x: rect.midX - size.width * scale / 2,
                              y: rect.midY - size.height * scale / 2,
                              width: size.width * scale, height: size.height * scale)
            image.draw(in: dest, from: .zero, operation: .sourceOver, fraction: 1)
            if tintSymbols {
                NSColor.white.set()
                dest.fill(using: .sourceAtop)
            }
            return true
        }
    }

    /// Draw text whose top-left sits at (`x`, top offset `topY`), clipped to `maxWidth`.
    @discardableResult
    private static func drawText(_ string: String, x: CGFloat, topY: CGFloat,
                                 size: CGFloat, weight: NSFont.Weight, color: NSColor,
                                 maxWidth: CGFloat,
                                 alignment: NSTextAlignment = .left) -> CGFloat {
        let f = NSFont.systemFont(ofSize: size, weight: weight)
        let para = NSMutableParagraphStyle()
        para.alignment = alignment
        para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: color, .paragraphStyle: para]
        let s = NSAttributedString(string: string, attributes: attrs)
        let h = s.size().height
        let rect = NSRect(x: x, y: top(topY) - h, width: maxWidth, height: h)
        s.draw(in: rect)
        return h
    }

    private static func drawCenteredText(_ string: String, rect: NSRect,
                                         size: CGFloat, weight: NSFont.Weight,
                                         color: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
        let attributed = NSAttributedString(string: string, attributes: attrs)
        let textHeight = attributed.size().height
        let centered = NSRect(x: rect.minX,
                              y: rect.midY - textHeight / 2,
                              width: rect.width,
                              height: textHeight)
        attributed.draw(in: centered)
    }

    private static func drawMuteStrike() {
        let shadow = NSBezierPath()
        shadow.move(to: NSPoint(x: 18, y: 20))
        shadow.line(to: NSPoint(x: side - 18, y: side - 20))
        shadow.lineWidth = 9
        shadow.lineCapStyle = .round
        NSColor(calibratedWhite: 0.02, alpha: 0.68).setStroke()
        shadow.stroke()

        let strike = NSBezierPath()
        strike.move(to: NSPoint(x: 18, y: 20))
        strike.line(to: NSPoint(x: side - 18, y: side - 20))
        strike.lineWidth = 6
        strike.lineCapStyle = .round
        mutedRed.setStroke()
        strike.stroke()
    }

    private static func drawHeader(glyph: KeyImage.Glyph?, monogram: String,
                                   accent: NSColor, name: String) {
        drawIcon(rect: header.icon, accent: accent, glyph: glyph, text: monogram,
                 fontSize: header.iconFontSize)
        drawText(name, x: header.nameX, topY: header.nameTopY, size: 15,
                 weight: .bold, color: .white, maxWidth: header.nameWidth,
                 alignment: .right)
    }

    private static func drawVolumeRail(pct: Int, accent: NSColor) {
        NSColor(calibratedWhite: 0.22, alpha: 1).setFill()
        NSBezierPath(roundedRect: volumeRail, xRadius: 4, yRadius: 4).fill()
        let fillW = volumeRail.width * CGFloat(max(0, min(100, pct))) / 100
        if fillW > 1 {
            accent.setFill()
            NSBezierPath(roundedRect: NSRect(x: volumeRail.minX, y: volumeRail.minY,
                                             width: fillW, height: volumeRail.height),
                         xRadius: 4, yRadius: 4).fill()
        }
    }

    /// Peak-meter color for a segment at fractional position p (0 bottom … 1 top).
    private static func segColor(_ p: CGFloat) -> NSColor {
        if p > 0.85 { return NSColor(calibratedRed: 1.0, green: 0.30, blue: 0.30, alpha: 1) }
        if p > 0.6  { return NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.25, alpha: 1) }
        return NSColor(calibratedRed: 0.22, green: 0.83, blue: 0.33, alpha: 1)
    }

    private static func segColorHex(_ p: CGFloat) -> String {
        hex(segColor(p))
    }

    private static func svgHeader(glyph: KeyImage.Glyph?, monogram: String,
                                  accent: NSColor, name: String) -> String {
        let iconTop = svgY(bottom: header.icon.minY, height: header.icon.height)
        let icon = svgIcon(glyph: glyph, monogram: monogram, accent: accent,
                           x: header.icon.minX, y: iconTop,
                           width: header.icon.width, height: header.icon.height)
        let safeName = escapedXML(name)
        return """
        \(icon)
        <text x="\(format(header.nameX + header.nameWidth))" y="\(format(header.nameTopY + 12))" text-anchor="end" font-family="-apple-system,BlinkMacSystemFont,'SF Pro Text',sans-serif" font-size="15" font-weight="700" fill="#FFFFFF">\(safeName)</text>
        """
    }

    private static func svgIcon(glyph: KeyImage.Glyph?, monogram: String, accent: NSColor,
                                x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> String {
        guard let glyph else {
            return svgMonogram(monogram, accent: accent, x: x, y: y, width: width, height: height)
        }
        switch glyph {
        case .emoji(let value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return svgMonogram(monogram, accent: accent, x: x, y: y, width: width, height: height)
            }
            if let icon = cachedTintedIconDataURI(.emoji(trimmed), side: Int(width * 2)) {
                return """
                <image href="\(icon)" x="\(format(x))" y="\(format(y))" width="\(format(width))" height="\(format(height))" preserveAspectRatio="xMidYMid meet"/>
                """
            }
            return """
            <text x="\(format(x + width / 2))" y="\(format(y + height / 2 + 1))" text-anchor="middle" dominant-baseline="central" font-family="-apple-system,BlinkMacSystemFont,'Apple Color Emoji','SF Pro Text',sans-serif" font-size="22" font-weight="700" fill="#FFFFFF">\(escapedXML(trimmed))</text>
            """
        case .symbol(let name):
            if let icon = cachedTintedIconDataURI(.symbol(name), side: Int(width * 2)) {
                return """
                <image href="\(icon)" x="\(format(x))" y="\(format(y))" width="\(format(width))" height="\(format(height))" preserveAspectRatio="xMidYMid meet"/>
                """
            }
            return svgMonogram(monogram, accent: accent, x: x, y: y, width: width, height: height)
        }
    }

    private static func cachedTintedIconDataURI(_ glyph: KeyImage.Glyph, side px: Int) -> String? {
        let key = tintedIconCacheKey(glyph, side: px)
        if let cached = tintedIconCache[key] { return cached }
        guard let icon = renderTintedIconDataURI(glyph, side: px) else { return nil }
        tintedIconCache[key] = icon
        return icon
    }

    private static func tintedIconCacheKey(_ glyph: KeyImage.Glyph, side px: Int) -> String {
        switch glyph {
        case .emoji(let value):
            return "e|\(px)|\(value)"
        case .symbol(let name):
            return "s|\(px)|\(name)"
        }
    }

    private static func renderTintedIconDataURI(_ glyph: KeyImage.Glyph, side px: Int) -> String? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

        let size = CGFloat(px)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high
        let ok = drawGlyph(glyph, in: NSRect(x: 2, y: 2, width: size - 4, height: size - 4),
                           tintSymbols: true)
        ctx.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard ok, let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return "data:image/png;base64," + png.base64EncodedString()
    }

    private static func svgMonogram(_ monogram: String, accent: NSColor,
                                    x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> String {
        """
        <text x="\(format(x + width / 2))" y="\(format(y + height / 2 + 1))" text-anchor="middle" dominant-baseline="central" font-family="-apple-system,BlinkMacSystemFont,'SF Pro Text',sans-serif" font-size="14" font-weight="700" fill="\(hex(accent))">\(escapedXML(monogram))</text>
        """
    }

    private static func svgVolumeRail(pct: Int, accent: NSColor) -> String {
        let top = svgY(bottom: volumeRail.minY, height: volumeRail.height)
        let fillW = volumeRail.width * CGFloat(max(0, min(100, pct))) / 100
        let fill = fillW > 1
            ? "<rect x=\"\(format(volumeRail.minX))\" y=\"\(format(top))\" width=\"\(format(fillW))\" height=\"\(format(volumeRail.height))\" rx=\"4\" fill=\"\(hex(accent))\"/>"
            : ""
        return """
        <rect x="\(format(volumeRail.minX))" y="\(format(top))" width="\(format(volumeRail.width))" height="\(format(volumeRail.height))" rx="4" fill="#383838"/>
        \(fill)
        """
    }

    private static func svgMuteStrike() -> String {
        """
        <line x1="18" y1="124" x2="126" y2="20" stroke="#050505" stroke-opacity="0.68" stroke-width="9" stroke-linecap="round"/>
        <line x1="18" y1="124" x2="126" y2="20" stroke="#FF4D4D" stroke-width="6" stroke-linecap="round"/>
        """
    }

    private static func svgVerticalSegments(x: CGFloat, bottom: CGFloat, top: CGFloat,
                                            width: CGFloat, count: Int, lit: Int,
                                            offColor: String) -> String {
        let gap = 2.0
        let segH = (top - bottom - gap * CGFloat(count - 1)) / CGFloat(count)
        return (0..<count).map { i in
            let p = CGFloat(i) / CGFloat(count - 1)
            let segBottom = bottom + CGFloat(i) * (segH + gap)
            let y = svgY(bottom: segBottom, height: segH)
            let color = i < lit ? segColorHex(p) : offColor
            return "<rect x=\"\(format(x))\" y=\"\(format(y))\" width=\"\(format(width))\" height=\"\(format(segH))\" rx=\"2\" fill=\"\(color)\"/>"
        }.joined(separator: "\n")
    }

    private static func svgHorizontalSegments(x: CGFloat, y bottom: CGFloat, width: CGFloat,
                                              height: CGFloat, count: Int, lit: Int) -> String {
        let gap = 2.0
        let segW = (width - gap * CGFloat(count - 1)) / CGFloat(count)
        let top = svgY(bottom: bottom, height: height)
        return (0..<count).map { i in
            let p = CGFloat(i) / CGFloat(count - 1)
            let segX = x + CGFloat(i) * (segW + gap)
            let color = i < lit ? segColorHex(p) : "#333333"
            return "<rect x=\"\(format(segX))\" y=\"\(format(top))\" width=\"\(format(segW))\" height=\"\(format(height))\" rx=\"2\" fill=\"\(color)\"/>"
        }.joined(separator: "\n")
    }

    private static func format(_ value: CGFloat) -> String {
        String(format: "%.2f", Double(value))
    }

    // MARK: - Style: channel

    private static func drawChannel(glyph: KeyImage.Glyph?, monogram: String, accent: NSColor, name: String,
                                    pct: Int, level: Float, muted: Bool) {
        drawHeader(glyph: glyph, monogram: monogram, accent: accent, name: name)

        drawCenteredText("\(pct)%", rect: volumeValueRect, size: 35, weight: .heavy, color: .white)

        drawVerticalSegments(x: 120, bottom: 40, top: 88, width: 6, count: 12,
                             lit: muted ? 0 : litSegments(level: level, count: 12),
                             offColor: NSColor(calibratedWhite: 0.22, alpha: 1))
        drawVolumeRail(pct: pct, accent: accent)
        if muted { drawMuteStrike() }
    }

    private static func renderChannelSVG(glyph: KeyImage.Glyph?, monogram: String,
                                         accent: NSColor, name: String, pct: Int,
                                         level: Float, muted: Bool) -> String {
        let lit = muted ? 0 : litSegments(level: level, count: 12)
        let strike = muted ? svgMuteStrike() : ""
        let value = svgVolumeValue(pct: pct)
        let svg = """
        <svg width="144" height="144" viewBox="0 0 144 144" xmlns="http://www.w3.org/2000/svg">
        \(svgHeader(glyph: glyph, monogram: monogram, accent: accent, name: name))
        \(value)
        \(svgVerticalSegments(x: 120, bottom: 40, top: 88, width: 6, count: 12,
                              lit: lit, offColor: "#383838"))
        \(svgVolumeRail(pct: pct, accent: accent))
        \(strike)
        </svg>
        """
        return svgDataURI(svg)
    }

    private static func svgVolumeValue(pct: Int) -> String {
        let clamped = max(0, min(100, pct))
        if let image = cachedVolumeValueDataURI(pct: clamped) {
            return """
            <image href="\(image)" x="\(format(volumeValueRect.minX))" y="\(format(svgY(bottom: volumeValueRect.minY, height: volumeValueRect.height)))" width="\(format(volumeValueRect.width))" height="\(format(volumeValueRect.height))" preserveAspectRatio="xMidYMid meet"/>
            """
        }
        return """
        <text x="\(format(volumeValueRect.midX))" y="\(format(svgY(bottom: volumeValueRect.minY, height: volumeValueRect.height) + volumeValueRect.height / 2))" text-anchor="middle" dominant-baseline="central" font-family="-apple-system,BlinkMacSystemFont,'SF Pro Display',sans-serif" font-size="35" font-weight="800" fill="#FFFFFF">\(clamped)%</text>
        """
    }

    private static func cachedVolumeValueDataURI(pct: Int) -> String? {
        if let cached = volumeValueCache[pct] { return cached }
        guard let image = renderVolumeValueDataURI(pct: pct) else { return nil }
        volumeValueCache[pct] = image
        return image
    }

    private static func renderVolumeValueDataURI(pct: Int) -> String? {
        let pxW = Int(volumeValueRect.width)
        let pxH = Int(volumeValueRect.height)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pxW, pixelsHigh: pxH,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high
        drawCenteredText("\(pct)%", rect: NSRect(x: 0, y: 0, width: volumeValueRect.width,
                                                 height: volumeValueRect.height),
                         size: 35, weight: .heavy, color: .white)
        ctx.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return "data:image/png;base64," + png.base64EncodedString()
    }

    // MARK: - Style: meter

    private static func drawMeterFocus(glyph: KeyImage.Glyph?, monogram: String, accent: NSColor, name: String,
                                       pct: Int, leftLevel: Float, rightLevel: Float, muted: Bool) {
        drawHeader(glyph: glyph, monogram: monogram, accent: accent, name: name)

        let segs = 18
        let bx = 34.0, bw = 94.0, bh = 11.0
        let leftBarY = top(76)
        let rightBarY = top(96)
        drawCenteredText("L", rect: NSRect(x: 12, y: leftBarY, width: 16, height: bh),
                         size: 14, weight: .heavy, color: .white)
        drawCenteredText("R", rect: NSRect(x: 12, y: rightBarY, width: 16, height: bh),
                         size: 14, weight: .heavy, color: .white)

        drawHorizontalSegments(x: bx, y: leftBarY, width: bw, height: bh, count: segs,
                               lit: muted ? 0 : litSegments(level: leftLevel, count: segs))
        drawHorizontalSegments(x: bx, y: rightBarY, width: bw, height: bh, count: segs,
                               lit: muted ? 0 : litSegments(level: rightLevel, count: segs))
        drawVolumeRail(pct: pct, accent: accent)
        if muted { drawMuteStrike() }
    }

    private static func renderMeterSVG(glyph: KeyImage.Glyph?, monogram: String,
                                       accent: NSColor, name: String, pct: Int,
                                       leftLevel: Float, rightLevel: Float, muted: Bool) -> String {
        let segs = 18
        let bx = 34.0, bw = 94.0, bh = 11.0
        let leftBarY = top(76)
        let rightBarY = top(96)
        let leftLit = muted ? 0 : litSegments(level: leftLevel, count: segs)
        let rightLit = muted ? 0 : litSegments(level: rightLevel, count: segs)
        let strike = muted ? svgMuteStrike() : ""
        let svg = """
        <svg width="144" height="144" viewBox="0 0 144 144" xmlns="http://www.w3.org/2000/svg">
        \(svgHeader(glyph: glyph, monogram: monogram, accent: accent, name: name))
        <text x="20" y="\(format(svgY(bottom: leftBarY, height: bh) + bh / 2 + 1))" text-anchor="middle" dominant-baseline="central" font-family="-apple-system,BlinkMacSystemFont,'SF Pro Text',sans-serif" font-size="14" font-weight="800" fill="#FFFFFF">L</text>
        \(svgHorizontalSegments(x: bx, y: leftBarY, width: bw, height: bh, count: segs, lit: leftLit))
        <text x="20" y="\(format(svgY(bottom: rightBarY, height: bh) + bh / 2 + 1))" text-anchor="middle" dominant-baseline="central" font-family="-apple-system,BlinkMacSystemFont,'SF Pro Text',sans-serif" font-size="14" font-weight="800" fill="#FFFFFF">R</text>
        \(svgHorizontalSegments(x: bx, y: rightBarY, width: bw, height: bh, count: segs, lit: rightLit))
        \(svgVolumeRail(pct: pct, accent: accent))
        \(strike)
        </svg>
        """
        return svgDataURI(svg)
    }

    private static func litSegments(level: Float, count: Int) -> Int {
        Int((CGFloat(max(0, min(1, level))) * CGFloat(count)).rounded())
    }

    private static func drawVerticalSegments(x: CGFloat, bottom: CGFloat, top: CGFloat,
                                             width: CGFloat, count: Int, lit: Int,
                                             offColor: NSColor) {
        let gap = 2.0
        let segH = (top - bottom - gap * CGFloat(count - 1)) / CGFloat(count)
        for i in 0..<count {
            let p = CGFloat(i) / CGFloat(count - 1)
            let y = bottom + CGFloat(i) * (segH + gap)
            let r = NSRect(x: x, y: y, width: width, height: segH)
            let on = i < lit
            (on ? segColor(p) : offColor).setFill()
            NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2).fill()
        }
    }

    private static func drawHorizontalSegments(x: CGFloat, y: CGFloat, width: CGFloat,
                                               height: CGFloat, count: Int, lit: Int) {
        let gap = 2.0
        let segW = (width - gap * CGFloat(count - 1)) / CGFloat(count)
        for i in 0..<count {
            let p = CGFloat(i) / CGFloat(count - 1)
            let r = NSRect(x: x + CGFloat(i) * (segW + gap), y: y, width: segW, height: height)
            let on = i < lit
            (on ? segColor(p) : NSColor(calibratedWhite: 0.20, alpha: 1)).setFill()
            NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2).fill()
        }
    }

    // MARK: - Style: retro

    private static func drawRetro(glyph: KeyImage.Glyph?, monogram: String, accent: NSColor, name: String,
                                  pct: Int, level: Float, muted: Bool) {
        drawHeader(glyph: glyph, monogram: monogram, accent: accent, name: name)
        RetroMeterDrawing.drawKeyFrame(side: side, name: "", glyph: nil, monogram: monogram,
                                       accent: accent, pct: pct, level: level,
                                       muted: muted)
        drawCenteredText("\(pct)%", rect: volumeValueRect, size: 35, weight: .heavy, color: .white)
        if muted { drawMuteStrike() }
    }
}
