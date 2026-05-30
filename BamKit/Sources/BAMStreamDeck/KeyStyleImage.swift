import AppKit
import Foundation

/// Renders a rich Stream Deck *keypad* key for a device/master volume control: a dark
/// rounded card with a colored monogram chip, the source name, the volume %, and a live
/// level visualization. Three styles select the visualization (see `KeyStyle`).
///
/// Output is a `data:image/png;base64,…` URI ready for `setImage`. Like `KeyImage`, it
/// draws into an `NSBitmapImageRep`-backed context (not `NSImage.lockFocus`) so it works
/// in the faceless plugin process. Coordinate origin is bottom-left (AppKit default);
/// the `top(_:)` helper converts top-down layout offsets.
enum KeyStyleImage {

    enum KeyStyle: String {
        case meter   // vertical LED peak meter + horizontal volume bar
        case bars    // horizontal segmented LVL bar + VOL capsule with knob
        case radial  // 270° volume arc around a centered monogram
    }

    private static let side: CGFloat = 144

    static func render(style: KeyStyle, monogram: String, accent: NSColor,
                       name: String, pct: Int, level: Float, muted: Bool) -> String? {
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
        case .meter:  drawMeter(monogram: monogram, accent: accent, name: name, pct: pct, level: level, muted: muted)
        case .bars:   drawBars(monogram: monogram, accent: accent, name: name, pct: pct, level: level, muted: muted)
        case .radial: drawRadial(monogram: monogram, accent: accent, name: name, pct: pct, level: level, muted: muted)
        }

        ctx.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return "data:image/png;base64," + png.base64EncodedString()
    }

    // MARK: - Shared

    private static let cardBG = NSColor(calibratedWhite: 0.10, alpha: 1)
    private static let mutedRed = NSColor(calibratedRed: 1.0, green: 0.30, blue: 0.30, alpha: 1)

    /// Convert a top-down y offset into the bottom-left coordinate space.
    private static func top(_ y: CGFloat) -> CGFloat { side - y }

    private static func drawBackground() {
        let r = NSRect(x: 0, y: 0, width: side, height: side)
        cardBG.setFill()
        NSBezierPath(roundedRect: r, xRadius: 20, yRadius: 20).fill()
    }

    /// Colored rounded chip with centered white initials.
    private static func drawChip(rect: NSRect, accent: NSColor, text: String, fontSize: CGFloat) {
        accent.setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.28, yRadius: rect.width * 0.28).fill()
        let f = NSFont.systemFont(ofSize: fontSize, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: NSColor.white]
        let s = NSAttributedString(string: text, attributes: attrs)
        let sz = s.size()
        s.draw(at: NSPoint(x: rect.midX - sz.width / 2, y: rect.midY - sz.height / 2))
    }

    /// Draw text whose top-left sits at (`x`, top offset `topY`), clipped to `maxWidth`.
    @discardableResult
    private static func drawText(_ string: String, x: CGFloat, topY: CGFloat,
                                 size: CGFloat, weight: NSFont.Weight, color: NSColor,
                                 maxWidth: CGFloat) -> CGFloat {
        let f = NSFont.systemFont(ofSize: size, weight: weight)
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: color, .paragraphStyle: para]
        let s = NSAttributedString(string: string, attributes: attrs)
        let h = s.size().height
        let rect = NSRect(x: x, y: top(topY) - h, width: maxWidth, height: h)
        s.draw(in: rect)
        return h
    }

    private static func initialsColor(_ muted: Bool, _ accent: NSColor) -> NSColor {
        muted ? mutedRed : accent
    }

    /// Peak-meter color for a segment at fractional position p (0 bottom … 1 top).
    private static func segColor(_ p: CGFloat) -> NSColor {
        if p > 0.85 { return NSColor(calibratedRed: 1.0, green: 0.30, blue: 0.30, alpha: 1) }
        if p > 0.6  { return NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.25, alpha: 1) }
        return NSColor(calibratedRed: 0.22, green: 0.83, blue: 0.33, alpha: 1)
    }

    // MARK: - Style: meter

    private static func drawMeter(monogram: String, accent: NSColor, name: String,
                                  pct: Int, level: Float, muted: Bool) {
        let chip = NSRect(x: 14, y: top(50), width: 36, height: 36)
        drawChip(rect: chip, accent: initialsColor(muted, accent), text: monogram, fontSize: 16)
        drawText(name, x: 58, topY: 16, size: 13, weight: .semibold, color: .white, maxWidth: 74)

        // Big volume % (or MUTE).
        if muted {
            drawText("MUTE", x: 58, topY: 40, size: 22, weight: .heavy, color: mutedRed, maxWidth: 74)
        } else {
            drawText("\(pct)%", x: 58, topY: 38, size: 26, weight: .heavy, color: .white, maxWidth: 74)
        }

        // Vertical LED peak meter on the right edge.
        let segs = 12
        let mx = side - 26.0, mw = 14.0
        let myTop = top(18.0), myBot = 30.0
        let gap = 3.0
        let segH = (myTop - myBot - gap * CGFloat(segs - 1)) / CGFloat(segs)
        let lit = muted ? 0 : Int((CGFloat(max(0, min(1, level))) * CGFloat(segs)).rounded())
        for i in 0..<segs {
            let p = CGFloat(i) / CGFloat(segs - 1)
            let y = myBot + CGFloat(i) * (segH + gap)
            let r = NSRect(x: mx, y: y, width: mw, height: segH)
            let on = i < lit
            (on ? segColor(p) : NSColor(calibratedWhite: 0.22, alpha: 1)).setFill()
            NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2).fill()
        }

        // Slim horizontal volume bar along the bottom.
        let track = NSRect(x: 14, y: 16, width: side - 56, height: 7)
        NSColor(calibratedWhite: 0.22, alpha: 1).setFill()
        NSBezierPath(roundedRect: track, xRadius: 3.5, yRadius: 3.5).fill()
        let fillW = track.width * CGFloat(max(0, min(100, pct))) / 100
        if fillW > 1 {
            (muted ? mutedRed : accent).setFill()
            NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: fillW, height: track.height),
                         xRadius: 3.5, yRadius: 3.5).fill()
        }
    }

    // MARK: - Style: bars

    private static func drawBars(monogram: String, accent: NSColor, name: String,
                                 pct: Int, level: Float, muted: Bool) {
        let chip = NSRect(x: 14, y: top(48), width: 34, height: 34)
        drawChip(rect: chip, accent: initialsColor(muted, accent), text: monogram, fontSize: 15)
        drawText(name, x: 56, topY: 14, size: 13, weight: .semibold, color: .white, maxWidth: 76)
        if muted {
            drawText("MUTE", x: 56, topY: 34, size: 16, weight: .heavy, color: mutedRed, maxWidth: 76)
        } else {
            drawText("\(pct)%", x: 56, topY: 32, size: 18, weight: .heavy, color: .white, maxWidth: 76)
        }

        // LVL: horizontal segmented level bar.
        drawText("LVL", x: 14, topY: 76, size: 9, weight: .bold, color: NSColor(calibratedWhite: 0.55, alpha: 1), maxWidth: 30)
        let segs = 14
        let bx = 14.0, bw = side - 28.0, by = top(98.0), bh = 12.0
        let gap = 2.0
        let segW = (bw - gap * CGFloat(segs - 1)) / CGFloat(segs)
        let lit = muted ? 0 : Int((CGFloat(max(0, min(1, level))) * CGFloat(segs)).rounded())
        for i in 0..<segs {
            let p = CGFloat(i) / CGFloat(segs - 1)
            let r = NSRect(x: bx + CGFloat(i) * (segW + gap), y: by, width: segW, height: bh)
            let on = i < lit
            (on ? segColor(p) : NSColor(calibratedWhite: 0.20, alpha: 1)).setFill()
            NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2).fill()
        }

        // VOL: capsule track with a knob at the volume position.
        drawText("VOL", x: 14, topY: 110, size: 9, weight: .bold, color: NSColor(calibratedWhite: 0.55, alpha: 1), maxWidth: 30)
        let tx = 14.0, tw = side - 28.0, ty = top(130.0), th = 8.0
        NSColor(calibratedWhite: 0.22, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: tx, y: ty, width: tw, height: th), xRadius: 4, yRadius: 4).fill()
        let frac = CGFloat(max(0, min(100, pct))) / 100
        (muted ? mutedRed : accent).setFill()
        NSBezierPath(roundedRect: NSRect(x: tx, y: ty, width: tw * frac, height: th), xRadius: 4, yRadius: 4).fill()
        let knobX = tx + tw * frac
        let kr = 9.0
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: knobX - kr, y: ty + th / 2 - kr, width: kr * 2, height: kr * 2)).fill()
    }

    // MARK: - Style: radial

    private static func drawRadial(monogram: String, accent: NSColor, name: String,
                                   pct: Int, level: Float, muted: Bool) {
        drawText(name, x: 12, topY: 12, size: 13, weight: .semibold, color: .white, maxWidth: side - 24)

        let cx = side / 2, cy = top(82.0)
        let radius = 42.0
        let lw = 9.0
        // Gauge sweeps 270°: from 225° clockwise down to -45° (i.e. 225 → -45).
        let startA = 225.0, endA = -45.0
        let trackPath = NSBezierPath()
        trackPath.appendArc(withCenter: NSPoint(x: cx, y: cy), radius: radius,
                            startAngle: startA, endAngle: endA, clockwise: true)
        trackPath.lineWidth = lw
        trackPath.lineCapStyle = .round
        NSColor(calibratedWhite: 0.20, alpha: 1).setStroke()
        trackPath.stroke()

        let frac = CGFloat(max(0, min(100, pct))) / 100
        let sweepEnd = startA - 270.0 * frac
        if frac > 0.001 {
            let fillPath = NSBezierPath()
            fillPath.appendArc(withCenter: NSPoint(x: cx, y: cy), radius: radius,
                               startAngle: startA, endAngle: sweepEnd, clockwise: true)
            fillPath.lineWidth = lw
            fillPath.lineCapStyle = .round
            (muted ? mutedRed : accent).setStroke()
            fillPath.stroke()
        }

        // Centered monogram chip.
        let chipSide = 40.0
        let chip = NSRect(x: cx - chipSide / 2, y: cy - chipSide / 2, width: chipSide, height: chipSide)
        drawChip(rect: chip, accent: initialsColor(muted, accent), text: monogram, fontSize: 17)

        // % or MUTE below the gauge.
        let label = muted ? "MUTE" : "\(pct)%"
        let f = NSFont.systemFont(ofSize: muted ? 18 : 22, weight: .heavy)
        let attrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: muted ? mutedRed : NSColor.white]
        let s = NSAttributedString(string: label, attributes: attrs)
        let sz = s.size()
        s.draw(at: NSPoint(x: cx - sz.width / 2, y: 14))
    }
}
