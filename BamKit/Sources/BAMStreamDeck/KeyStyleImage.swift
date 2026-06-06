import AppKit
import Foundation

/// Renders a rich Stream Deck *keypad* key for a device/master volume control.
/// Each style keeps the group identity prominent and treats the live meter as part
/// of the control language instead of secondary decoration.
///
/// Output is a `data:image/png;base64,…` URI ready for `setImage`. Like `KeyImage`, it
/// draws into an `NSBitmapImageRep`-backed context (not `NSImage.lockFocus`) so it works
/// in the faceless plugin process. Coordinate origin is bottom-left (AppKit default);
/// the `top(_:)` helper converts top-down layout offsets.
enum KeyStyleImage {

    enum KeyStyle: String {
        case channel // compact channel strip: group identity + live meter + volume rail
        case meter   // meter-focused tile: larger live signal display + volume marker
        case retro   // VU-style gauge with live needle + red volume needle
    }

    private static let side: CGFloat = 144

    static func render(style: KeyStyle, glyph: KeyImage.Glyph? = nil, monogram: String, accent: NSColor,
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
        case .channel: drawChannel(glyph: glyph, monogram: monogram, accent: accent, name: name, pct: pct, level: level, muted: muted)
        case .meter:   drawMeterFocus(glyph: glyph, monogram: monogram, accent: accent, name: name, pct: pct, level: level, muted: muted)
        case .retro:   drawRetro(glyph: glyph, monogram: monogram, accent: accent, name: name, pct: pct, level: level, muted: muted)
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

    /// Colored rounded chip with the BAM icon/emoji, falling back to initials.
    private static func drawChip(rect: NSRect, accent: NSColor, glyph: KeyImage.Glyph?,
                                 text: String, fontSize: CGFloat) {
        accent.setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.28, yRadius: rect.width * 0.28).fill()
        if let glyph, drawGlyph(glyph, in: rect.insetBy(dx: 7, dy: 7), tintSymbols: true) {
            return
        }
        let f = NSFont.systemFont(ofSize: fontSize, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: NSColor.white]
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

    // MARK: - Style: channel

    private static func drawChannel(glyph: KeyImage.Glyph?, monogram: String, accent: NSColor, name: String,
                                    pct: Int, level: Float, muted: Bool) {
        let chip = NSRect(x: 12, y: top(52), width: 40, height: 40)
        drawChip(rect: chip, accent: initialsColor(muted, accent), glyph: glyph, text: monogram, fontSize: 17)
        drawText(name, x: 60, topY: 14, size: 13, weight: .semibold, color: .white, maxWidth: 72)

        if muted {
            drawText("MUTED", x: 60, topY: 37, size: 18, weight: .heavy, color: mutedRed, maxWidth: 72)
        } else {
            drawText("\(pct)%", x: 60, topY: 34, size: 27, weight: .heavy, color: .white, maxWidth: 72)
        }

        let segs = 12
        let mx = side - 24.0, mw = 12.0
        let myTop = top(18.0), myBot = 34.0
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

        let track = NSRect(x: 12, y: 16, width: side - 48, height: 8)
        NSColor(calibratedWhite: 0.22, alpha: 1).setFill()
        NSBezierPath(roundedRect: track, xRadius: 4, yRadius: 4).fill()
        let fillW = track.width * CGFloat(max(0, min(100, pct))) / 100
        if fillW > 1 {
            (muted ? mutedRed : accent).setFill()
            NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: fillW, height: track.height),
                         xRadius: 4, yRadius: 4).fill()
        }
    }

    // MARK: - Style: meter

    private static func drawMeterFocus(glyph: KeyImage.Glyph?, monogram: String, accent: NSColor, name: String,
                                       pct: Int, level: Float, muted: Bool) {
        drawText(name, x: 12, topY: 12, size: 13, weight: .semibold, color: .white, maxWidth: side - 24)

        let chip = NSRect(x: 12, y: top(56), width: 36, height: 36)
        drawChip(rect: chip, accent: initialsColor(muted, accent), glyph: glyph, text: monogram, fontSize: 16)
        if muted {
            drawText("MUTED", x: 56, topY: 36, size: 20, weight: .heavy, color: mutedRed, maxWidth: 76)
        } else {
            drawText("\(pct)%", x: 58, topY: 33, size: 24, weight: .heavy, color: .white, maxWidth: 74)
        }

        let segs = 18
        let bx = 12.0, bw = side - 24.0, by = top(92.0), bh = 16.0
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

        let tx = 12.0, tw = side - 24.0, ty = top(126.0), th = 8.0
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

    // MARK: - Style: retro

    private static func drawRetro(glyph: KeyImage.Glyph?, monogram: String, accent: NSColor, name: String,
                                  pct: Int, level: Float, muted: Bool) {
        RetroMeterDrawing.drawKeyFrame(side: side, name: name, glyph: glyph, monogram: monogram,
                                       accent: accent, pct: pct, level: level,
                                       muted: muted)
    }
}
