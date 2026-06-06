import AppKit
import CoreText
import Foundation

enum RetroMeterDrawing {
    private static let mutedRed = NSColor(calibratedRed: 1.0, green: 0.25, blue: 0.25, alpha: 1)
    private static let meterGreen = NSColor(calibratedRed: 0.15, green: 0.85, blue: 0.36, alpha: 1)
    private static let meterAmber = NSColor(calibratedRed: 1.0, green: 0.68, blue: 0.20, alpha: 1)
    @MainActor private static var lcdLevelBarSVGCache: [String: String] = [:]

    static func drawKeyFrame(side: CGFloat, name: String, glyph: KeyImage.Glyph? = nil,
                             monogram: String, accent: NSColor,
                             pct: Int, level: Float, muted: Bool) {
        drawFace(rect: NSRect(x: 14, y: 20, width: side - 28, height: side - 44),
                 cornerRadius: 8, glyph: glyph, label: monogram, name: name, pct: pct,
                 level: level, muted: muted, accent: accent, compact: true)
    }

    static func renderLCD(name: String, glyph: KeyImage.Glyph? = nil,
                          monogram: String, accent: NSColor,
                          pct: Int, level: Float, muted: Bool,
                          style: KeyStyleImage.KeyStyle = .retro) -> String? {
        renderLCDFrame(name: name, glyph: glyph, monogram: monogram, accent: accent,
                       pct: pct, level: level, muted: muted, style: style,
                       includeLiveMeters: true)
    }

    static func renderRetroLCDStatic(name: String, glyph: KeyImage.Glyph? = nil,
                                     monogram: String, accent: NSColor,
                                     pct: Int, muted: Bool) -> String? {
        renderLCDFrame(name: name, glyph: glyph, monogram: monogram, accent: accent,
                       pct: pct, level: 0, muted: muted, style: .retro,
                       includeLiveMeters: false)
    }

    static func renderLCDStatic(style: KeyStyleImage.KeyStyle,
                                name: String, glyph: KeyImage.Glyph? = nil,
                                monogram: String, accent: NSColor,
                                pct: Int, muted: Bool) -> String? {
        renderLCDFrame(name: name, glyph: glyph, monogram: monogram, accent: accent,
                       pct: pct, level: 0, muted: muted, style: style,
                       includeLiveMeters: false)
    }

    static func retroLCDLevelNeedleStep(level: Float, muted: Bool) -> Int {
        guard !muted else { return 0 }
        let clamped = max(0, min(1, level))
        return Int((clamped * 90).rounded())
    }

    static func lcdLevelBarStep(level: Float, muted: Bool) -> Int {
        guard !muted else { return 0 }
        let clamped = max(0, min(1, level))
        return Int((clamped * 100).rounded())
    }

    @MainActor static func renderLCDLevelBarSVG(width: Int, height: Int, step: Int,
                                                peakStep: Int? = nil, muted: Bool) -> String {
        let normalizedStep = max(0, min(100, step))
        let normalizedPeak = max(0, min(100, peakStep ?? normalizedStep))
        let cacheKey = "\(width)|\(height)|\(normalizedStep)|\(normalizedPeak)|\(muted ? 1 : 0)"
        if let cached = lcdLevelBarSVGCache[cacheKey] { return cached }

        let fillWidth = Double(width) * Double(normalizedStep) / 100
        let coverWidth = max(0, Double(width) - fillWidth)
        let peakX = min(Double(width) - 2, max(1, Double(width) * Double(normalizedPeak) / 100))
        let radius = min(2.0, Double(height) / 4)
        let opacity = muted ? "0.45" : "1"
        let peakOpacity = muted ? "0.55" : "1"
        let svg = String(format: """
        <svg width="%d" height="%d" viewBox="0 0 %d %d" xmlns="http://www.w3.org/2000/svg">
          <defs>
            <linearGradient id="meter" x1="0" y1="0" x2="%d" y2="0" gradientUnits="userSpaceOnUse">
              <stop offset="0%%" stop-color="#26D65E"/>
              <stop offset="30%%" stop-color="#26D65E"/>
              <stop offset="60%%" stop-color="#FFD43B"/>
              <stop offset="75%%" stop-color="#FF9A2E"/>
              <stop offset="90%%" stop-color="#FF3C4E"/>
              <stop offset="100%%" stop-color="#FF3C4E"/>
            </linearGradient>
          </defs>
          <rect x="0" y="0" width="%d" height="%d" rx="%.2f" fill="url(#meter)" opacity="%@"/>
          <rect x="%.2f" y="0" width="%.2f" height="%d" rx="%.2f" fill="#292929"/>
          <rect x="%.2f" y="0" width="4" height="%d" rx="1" fill="#050505" opacity="%@"/>
          <rect x="%.2f" y="0" width="2" height="%d" rx="1" fill="#FF3636" opacity="%@"/>
        </svg>
        """, width, height, width, height,
           width, width, height, radius, opacity,
           fillWidth, coverWidth, height, radius,
           peakX - 1, height, peakOpacity,
           peakX, height, peakOpacity)
        let uri = "data:image/svg+xml;base64," + Data(svg.utf8).base64EncodedString()
        if lcdLevelBarSVGCache.count > 512 { lcdLevelBarSVGCache.removeAll(keepingCapacity: true) }
        lcdLevelBarSVGCache[cacheKey] = uri
        return uri
    }

    static func renderRetroLCDLevelNeedleSVG(step: Int, muted: Bool) -> String {
        let normalizedStep = max(0, min(90, step))
        let fraction = CGFloat(normalizedStep) / 90
        let angle = lcdAngle(for: fraction)
        let center = CGPoint(x: 82, y: 65)
        let end = CGPoint(x: center.x + cos(angle) * 54,
                          y: center.y - sin(angle) * 40)
        let stroke = muted ? "#616161" : "#F0F0F0"
        let svg = String(format: """
        <svg width="164" height="56" viewBox="0 0 164 56" xmlns="http://www.w3.org/2000/svg">
          <line x1="82" y1="65" x2="%.2f" y2="%.2f" stroke="%@" stroke-width="2.2" stroke-linecap="round"/>
        </svg>
        """, Double(end.x), Double(end.y), stroke)
        let encoded = Data(svg.utf8).base64EncodedString()
        return "data:image/svg+xml;base64," + encoded
    }

    private static func renderLCDFrame(name: String, glyph: KeyImage.Glyph? = nil,
                                       monogram: String, accent: NSColor,
                                       pct: Int, level: Float, muted: Bool,
                                       style: KeyStyleImage.KeyStyle,
                                       includeLiveMeters: Bool) -> String? {
        let width = 200
        let height = 100
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high

        NSColor(calibratedWhite: 0.05, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        switch style {
        case .channel:
            drawChannelLCD(name: name, glyph: glyph, monogram: monogram, accent: accent,
                           pct: pct, level: level, muted: muted,
                           includeLevelMeter: includeLiveMeters)
        case .meter:
            drawMeterFocusLCD(name: name, glyph: glyph, monogram: monogram, accent: accent,
                              pct: pct, level: level, muted: muted,
                              includeLevelMeter: includeLiveMeters)
        case .retro:
            drawLCDReferencePanel(name: name, glyph: glyph, monogram: monogram, accent: accent,
                                  pct: pct, level: level, muted: muted,
                                  includeLevelNeedle: includeLiveMeters)
        }

        ctx.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return "data:image/png;base64," + png.base64EncodedString()
    }

    private static func drawChannelLCD(name: String, glyph: KeyImage.Glyph?, monogram: String, accent: NSColor,
                                       pct: Int, level: Float, muted: Bool,
                                       includeLevelMeter: Bool) {
        drawLabel(shortLCDName(name), rect: NSRect(x: 16, y: 68, width: 104, height: 18),
                  size: 13, color: .white, align: .left)
        drawLabel(muted ? "MUTED" : "\(pct)%",
                  rect: NSRect(x: 126, y: 62, width: 58, height: 25),
                  size: muted ? 12 : 21, color: muted ? mutedRed : .white, align: .right)

        drawLevelBar(rect: NSRect(x: 56, y: 40, width: 128, height: 17),
                     level: level, muted: muted, includeFill: includeLevelMeter)
        drawVolumeRail(rect: NSRect(x: 56, y: 20, width: 128, height: 8), pct: pct, muted: muted, accent: accent)
    }

    private static func drawMeterFocusLCD(name: String, glyph: KeyImage.Glyph?, monogram: String, accent: NSColor,
                                          pct: Int, level: Float, muted: Bool,
                                          includeLevelMeter: Bool) {
        drawLabel(shortLCDName(name), rect: NSRect(x: 16, y: 68, width: 104, height: 18),
                  size: 13, color: .white, align: .left)
        drawLabel(muted ? "MUTED" : "\(pct)%",
                  rect: NSRect(x: 126, y: 62, width: 58, height: 25),
                  size: muted ? 12 : 21, color: muted ? mutedRed : .white, align: .right)

        drawLevelBar(rect: NSRect(x: 71, y: 41, width: 113, height: 13),
                     level: level, muted: muted, includeFill: includeLevelMeter)
        drawMeterSideLabel("L", rect: NSRect(x: 54, y: 41, width: 15, height: 13))
        drawLevelBar(rect: NSRect(x: 71, y: 21, width: 113, height: 13),
                     level: level, muted: muted, includeFill: includeLevelMeter)
        drawMeterSideLabel("R", rect: NSRect(x: 54, y: 21, width: 15, height: 13))
        _ = glyph
        _ = monogram
    }

    private static func drawStereoMeters(left: NSRect, right: NSRect, level: Float, muted: Bool) {
        drawVerticalMeter(rect: left, level: level, muted: muted)
        drawVerticalMeter(rect: right, level: level, muted: muted)
    }

    private static func drawVerticalMeter(rect: NSRect, level: Float, muted: Bool) {
        NSColor(calibratedWhite: 0.16, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
        let frac = muted ? CGFloat(0) : CGFloat(max(0, min(1, level)))
        guard frac > 0 else { return }
        let fillHeight = rect.height * frac
        let fill = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: fillHeight)
        meterGreen.setFill()
        NSBezierPath(roundedRect: NSRect(x: fill.minX, y: fill.minY, width: fill.width, height: min(fill.height, rect.height * 0.78)),
                     xRadius: 3, yRadius: 3).fill()
        if frac > 0.78 {
            meterAmber.setFill()
            let amberY = rect.minY + rect.height * 0.78
            let amberH = min(fill.maxY - amberY, rect.height * 0.14)
            NSRect(x: rect.minX, y: amberY, width: rect.width, height: max(0, amberH)).fill()
        }
        if frac > 0.92 {
            mutedRed.setFill()
            let redY = rect.minY + rect.height * 0.92
            NSRect(x: rect.minX, y: redY, width: rect.width, height: max(0, fill.maxY - redY)).fill()
        }
    }

    private static func drawLevelBar(rect: NSRect, level: Float, muted: Bool, includeFill: Bool = true) {
        NSColor(calibratedWhite: 0.16, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
        guard includeFill else { return }
        let frac = muted ? CGFloat(0) : CGFloat(max(0, min(1, level)))
        guard frac > 0 else { return }
        let fill = NSRect(x: rect.minX, y: rect.minY, width: rect.width * frac, height: rect.height)
        meterGreen.setFill()
        NSBezierPath(roundedRect: NSRect(x: fill.minX, y: fill.minY, width: fill.width * 0.78, height: fill.height),
                     xRadius: 3, yRadius: 3).fill()
        if frac > 0.78 {
            meterAmber.setFill()
            let amberX = rect.minX + rect.width * 0.78
            let amberW = min(fill.maxX - amberX, rect.width * 0.14)
            NSRect(x: amberX, y: rect.minY, width: max(0, amberW), height: rect.height).fill()
        }
        if frac > 0.92 {
            mutedRed.setFill()
            let redX = rect.minX + rect.width * 0.92
            NSRect(x: redX, y: rect.minY, width: max(0, fill.maxX - redX), height: rect.height).fill()
        }
    }

    private static func drawVolumeRail(rect: NSRect, pct: Int, muted: Bool, accent: NSColor) {
        NSColor(calibratedWhite: 0.22, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
        let frac = CGFloat(max(0, min(100, pct))) / 100
        (muted ? mutedRed : accent).setFill()
        NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.minY, width: rect.width * frac, height: rect.height),
                     xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
    }

    private static func drawLCDReferencePanel(name: String, glyph: KeyImage.Glyph?, monogram: String, accent: NSColor,
                                              pct: Int, level: Float, muted: Bool,
                                              includeLevelNeedle: Bool) {
        _ = glyph
        _ = monogram
        drawLabel(shortLCDName(name), rect: NSRect(x: 16, y: 68, width: 104, height: 18),
                  size: 13, color: .white, align: .left)
        drawLabel(muted ? "MUTED" : "\(pct)%",
                  rect: NSRect(x: 126, y: 62, width: 58, height: 25),
                  size: muted ? 12 : 21, color: muted ? mutedRed : .white, align: .right)

        let dial = NSRect(x: 18, y: 5, width: 164, height: 56)
        let center = NSPoint(x: dial.midX, y: dial.minY - 9)
        let radiusX: CGFloat = 80
        let radiusY: CGFloat = 62
        drawLCDHalfDialTexture(in: dial, center: center, radiusX: radiusX, radiusY: radiusY,
                               accent: muted ? mutedRed : accent)

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: dial).addClip()
        let volFraction = min(0.90, max(0.10, CGFloat(max(0, min(100, pct))) / 100))
        drawLCDArc(center: center, radiusX: radiusX, radiusY: radiusY,
                   volumeFraction: volFraction, muted: muted)

        if includeLevelNeedle {
            let levelAngle = lcdAngle(for: muted ? 0 : CGFloat(max(0, min(1, level))))
            drawNeedle(center: center, radiusX: radiusX - 26, radiusY: radiusY - 22, angle: levelAngle,
                       color: NSColor(calibratedWhite: muted ? 0.38 : 0.94, alpha: 1),
                       width: 2.2)
        }
        let volAngle = lcdAngle(for: volFraction)
        drawNeedle(center: center, radiusX: radiusX - 15, radiusY: radiusY - 14, angle: volAngle,
                   color: muted ? mutedRed : NSColor(calibratedRed: 1, green: 0.12, blue: 0.08, alpha: 1),
                   width: 2.8)

        NSColor(calibratedWhite: 0.02, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)).fill()
        (muted ? mutedRed : accent).setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4)).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawLCDHalfDialTexture(in rect: NSRect, center: NSPoint,
                                               radiusX: CGFloat, radiusY: CGFloat,
                                               accent: NSColor) {
        let circleRect = NSRect(x: center.x - radiusX, y: center.y - radiusY,
                                width: radiusX * 2, height: radiusY * 2)
        let circle = NSBezierPath(ovalIn: circleRect)
        let clip = NSBezierPath(rect: rect)
        NSColor(calibratedWhite: 0.115, alpha: 1).setFill()
        NSGraphicsContext.saveGraphicsState()
        clip.addClip()
        circle.fill()

        for i in 0..<13 {
            let inset = CGFloat(i) * 5.4
            let alpha = i % 2 == 0 ? 0.09 : 0.045
            NSColor(calibratedWhite: 0.22, alpha: alpha).setStroke()
            let ring = NSBezierPath(ovalIn: circleRect.insetBy(dx: inset, dy: inset))
            ring.lineWidth = 0.7
            ring.stroke()
        }
        for i in 0..<28 {
            let x = rect.minX + CGFloat((i * 37) % Int(rect.width))
            let y = rect.minY + CGFloat((i * 19) % Int(rect.height))
            NSColor(calibratedWhite: i % 3 == 0 ? 0.23 : 0.17, alpha: 0.22).setFill()
            NSRect(x: x, y: y, width: 1, height: 1).fill()
        }

        NSColor(calibratedWhite: 0.38, alpha: 1).setStroke()
        circle.lineWidth = 1.8
        circle.stroke()
        accent.withAlphaComponent(0.45).setStroke()
        let inner = NSBezierPath(ovalIn: circleRect.insetBy(dx: 7, dy: 7))
        inner.lineWidth = 1.0
        inner.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawLCDArc(center: NSPoint, radiusX: CGFloat, radiusY: CGFloat,
                                   volumeFraction: CGFloat, muted: Bool) {
        for i in 0...24 {
            let frac = CGFloat(i) / 24
            let angle = lcdAngle(for: frac)
            let major = i % 12 == 0
            let mid = i % 4 == 0
            let innerX = radiusX - (major ? 14 : mid ? 10 : 6)
            let innerY = radiusY - (major ? 11 : mid ? 8 : 5)
            let outer = point(center: center, radiusX: radiusX, radiusY: radiusY, angle: angle)
            let inner = point(center: center, radiusX: innerX, radiusY: innerY, angle: angle)
            let path = NSBezierPath()
            path.move(to: inner)
            path.line(to: outer)
            path.lineWidth = major ? 2.6 : mid ? 2.0 : 1.5
            let isVolumeTick = abs(frac - volumeFraction) <= 0.5 / 24
            (muted
                ? NSColor(calibratedWhite: 0.28, alpha: 1)
                : isVolumeTick
                    ? NSColor(calibratedRed: 1, green: 0.12, blue: 0.08, alpha: 1)
                    : NSColor(calibratedWhite: 0.48, alpha: 1)
            ).setStroke()
            path.stroke()
        }

        let arc = NSBezierPath()
        for i in 0...64 {
            let frac = CGFloat(i) / 64
            let p = point(center: center, radiusX: radiusX - 18, radiusY: radiusY - 14,
                          angle: lcdAngle(for: frac))
            if i == 0 { arc.move(to: p) } else { arc.line(to: p) }
        }
        arc.lineWidth = 1.8
        NSColor(calibratedWhite: 0.30, alpha: 1).setStroke()
        arc.stroke()
    }

    private static func drawRetroReadout(pct: Int, muted: Bool) {
        if muted {
            drawLabel("MUTED", rect: NSRect(x: 154, y: 52, width: 38, height: 18),
                      size: 10, color: mutedRed, align: .right)
            return
        }
        drawLabel("\(max(0, min(100, pct)))", rect: NSRect(x: 158, y: 48, width: 32, height: 25),
                  size: 19, color: .white, align: .right)
        drawLabel("%", rect: NSRect(x: 179, y: 36, width: 11, height: 10),
                  size: 7, color: NSColor(calibratedWhite: 0.78, alpha: 1), align: .right)
    }

    private static func drawFace(rect: NSRect, cornerRadius: CGFloat, glyph: KeyImage.Glyph?,
                                 label: String, name: String,
                                 pct: Int, level: Float, muted: Bool, accent: NSColor,
                                 compact: Bool) {
        NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
        NSColor(calibratedWhite: 0.26, alpha: 1).setStroke()
        let border = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1),
                                  xRadius: cornerRadius, yRadius: cornerRadius)
        border.lineWidth = 1
        border.stroke()

        let center = NSPoint(x: rect.midX, y: rect.minY + rect.height * 0.20)
        let radius = rect.width * (compact ? 0.42 : 0.38)
        drawTicks(center: center, radius: radius, muted: muted)

        let levelAngle = angle(for: muted ? 0 : CGFloat(max(0, min(1, level))))
        drawNeedle(center: center, radius: radius * 0.92, angle: levelAngle,
                   color: NSColor(calibratedWhite: 0.86, alpha: 1), width: compact ? 2.2 : 2)

        let volumeAngle = angle(for: CGFloat(max(0, min(100, pct))) / 100)
        drawNeedle(center: center, radius: radius * 0.72, angle: volumeAngle,
                   color: muted ? mutedRed : NSColor(calibratedRed: 1, green: 0.18, blue: 0.14, alpha: 1),
                   width: compact ? 2.8 : 2.4)

        NSColor(calibratedWhite: 0.04, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10)).fill()

        let iconRect = NSRect(x: rect.minX + 8, y: rect.maxY - 24, width: 16, height: 16)
        if glyph == nil || !drawGlyph(glyph!, in: iconRect, tintSymbols: true) {
            drawLabel(label, rect: NSRect(x: rect.minX + 8, y: rect.maxY - 22, width: 34, height: 15),
                      size: compact ? 9 : 8, color: muted ? mutedRed : accent, align: .left)
        }
        drawLabel(shortName(name), rect: NSRect(x: rect.minX + 42, y: rect.maxY - 22,
                                                width: rect.width - 50, height: 15),
                  size: compact ? 10 : 9, color: .white, align: .left)
        if compact {
            drawReadout(x: rect.maxX - 42, y: rect.minY + 12, pct: pct, muted: muted)
        }
    }

    private static func drawTicks(center: NSPoint, radius: CGFloat, muted: Bool) {
        for i in 0...10 {
            let frac = CGFloat(i) / 10
            let angle = angle(for: frac)
            let outer = point(center: center, radius: radius, angle: angle)
            let inner = point(center: center, radius: radius - (i % 5 == 0 ? 8 : 5), angle: angle)
            let path = NSBezierPath()
            path.move(to: inner)
            path.line(to: outer)
            path.lineWidth = i % 5 == 0 ? 1.4 : 1
            tickColor(frac, muted: muted).setStroke()
            path.stroke()
        }
    }

    private static func drawNeedle(center: NSPoint, radius: CGFloat, angle: CGFloat,
                                   color: NSColor, width: CGFloat) {
        let end = point(center: center, radius: radius, angle: angle)
        let path = NSBezierPath()
        path.move(to: center)
        path.line(to: end)
        path.lineWidth = width
        path.lineCapStyle = .round
        color.setStroke()
        path.stroke()
    }

    private static func drawNeedle(center: NSPoint, radiusX: CGFloat, radiusY: CGFloat, angle: CGFloat,
                                   color: NSColor, width: CGFloat) {
        let end = point(center: center, radiusX: radiusX, radiusY: radiusY, angle: angle)
        let path = NSBezierPath()
        path.move(to: center)
        path.line(to: end)
        path.lineWidth = width
        path.lineCapStyle = .round
        color.setStroke()
        path.stroke()
    }

    @discardableResult
    private static func drawGlyph(_ glyph: KeyImage.Glyph, in rect: NSRect, tintSymbols: Bool) -> Bool {
        switch glyph {
        case .emoji(let value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }
            let font = NSFont.systemFont(ofSize: rect.height * 0.92)
            let str = NSAttributedString(string: trimmed, attributes: [.font: font])
            let size = str.size()
            str.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
            return true
        case .symbol(let name):
            guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
                return false
            }
            let config = NSImage.SymbolConfiguration(pointSize: rect.height * 0.9, weight: .regular)
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

    private static func drawReadout(x: CGFloat, y: CGFloat, pct: Int, muted: Bool) {
        let value = muted ? "MUTED" : "\(pct)"
        let unit = muted ? "" : "dB"
        drawLabel(value, rect: NSRect(x: x, y: y, width: 34, height: 22),
                  size: muted ? 9 : 20, color: muted ? mutedRed : .white, align: .right)
        if !unit.isEmpty {
            drawLabel(unit, rect: NSRect(x: x, y: y - 14, width: 34, height: 12),
                      size: 8, color: NSColor(calibratedWhite: 0.78, alpha: 1), align: .right)
        }
    }

    private static func drawLabel(_ text: String, rect: NSRect, size: CGFloat,
                                  color: NSColor, align: NSTextAlignment) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = align
        paragraph.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: size, weight: .bold),
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
        NSAttributedString(string: text, attributes: attrs).draw(in: rect)
    }

    private static func drawMeterSideLabel(_ text: String, rect: NSRect) {
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(calibratedWhite: 0.70, alpha: 1)
        ]
        let label = NSAttributedString(string: text, attributes: attrs)
        let line = CTLineCreateWithAttributedString(label)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let x = rect.midX - width / 2
        let baseline = rect.midY - (font.ascender + font.descender) / 2

        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        cg.saveGState()
        cg.textMatrix = .identity
        cg.textPosition = CGPoint(x: x, y: baseline)
        CTLineDraw(line, cg)
        cg.restoreGState()
    }

    private static func angle(for fraction: CGFloat) -> CGFloat {
        (-145 + 110 * max(0, min(1, fraction))) * .pi / 180
    }

    private static func lcdAngle(for fraction: CGFloat) -> CGFloat {
        (180 - 180 * max(0, min(1, fraction))) * .pi / 180
    }

    private static func point(center: NSPoint, radius: CGFloat, angle: CGFloat) -> NSPoint {
        NSPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
    }

    private static func point(center: NSPoint, radiusX: CGFloat, radiusY: CGFloat, angle: CGFloat) -> NSPoint {
        NSPoint(x: center.x + cos(angle) * radiusX, y: center.y + sin(angle) * radiusY)
    }

    private static func tickColor(_ fraction: CGFloat, muted: Bool) -> NSColor {
        if muted { return NSColor(calibratedWhite: 0.28, alpha: 1) }
        if fraction > 0.82 { return mutedRed }
        return NSColor(calibratedWhite: 0.48, alpha: 1)
    }

    private static func shortName(_ name: String) -> String {
        name.isEmpty ? "GROUP" : name.uppercased()
    }

    private static func shortLCDName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "--" : trimmed.uppercased()
    }
}
