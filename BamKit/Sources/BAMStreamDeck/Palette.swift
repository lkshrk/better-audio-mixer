import AppKit

struct RGB: Hashable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    init(_ red: Double, _ green: Double, _ blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    var nsColor: NSColor { NSColor(calibratedRed: red, green: green, blue: blue, alpha: 1) }

    func nsColor(alpha: Double) -> NSColor {
        NSColor(calibratedRed: red, green: green, blue: blue, alpha: alpha)
    }

    var hex: String {
        String(format: "#%02X%02X%02X", Self.channel(red), Self.channel(green), Self.channel(blue))
    }

    private static func channel(_ value: Double) -> Int {
        Int((max(0, min(1, value)) * 255).rounded())
    }
}

/// Every colour the plugin draws; renderers never spell out a hex of their own.
enum Palette {
    /// Devices pick by a stable hash of their mix id; master is fixed purple.
    static let accents: [RGB] = [
        RGB(0.36, 0.62, 1.00),
        RGB(0.30, 0.80, 0.45),
        RGB(1.00, 0.55, 0.30),
        RGB(0.95, 0.40, 0.55),
        RGB(0.30, 0.78, 0.82),
    ]
    static let masterAccent = RGB(0.70, 0.45, 0.95)

    static let mutedRed = RGB(1.00, 0.30, 0.30)
    static let text = RGB(1, 1, 1)
    static let needle = RGB(0.86, 0.86, 0.86)
    /// Unlit segments, empty rails, gauge arcs and minor ticks.
    static let rail = RGB(0.22, 0.22, 0.22)
    static let tick = RGB(0.48, 0.48, 0.48)
    static let tile = RGB(0.11, 0.11, 0.12)
    static let tileBorder = RGB(0.33, 0.33, 0.35)
    static let lcdBackground = RGB(0.05, 0.05, 0.05)

    static let segmentGreen = RGB(0.22, 0.83, 0.33)
    static let segmentAmber = RGB(1.00, 0.62, 0.25)
    /// Meter bands from the bottom up: each colour runs until its `upTo` fraction.
    static let segmentBands: [(upTo: CGFloat, color: RGB)] = [
        (0.60, segmentGreen), (0.85, segmentAmber), (1.00, mutedRed),
    ]

    static let mutedValueOpacity = 0.6
    static let mutedBorderWidth: CGFloat = 4

    static func accent(forID id: String) -> RGB {
        var h: UInt64 = 1469598103934665603 // FNV-1a
        for byte in id.utf8 { h = (h ^ UInt64(byte)) &* 1099511628211 }
        return accents[Int(h % UInt64(accents.count))]
    }

    /// Meter colour for a segment at fractional position p (0 bottom … 1 top).
    static func segment(_ p: CGFloat) -> RGB {
        segmentBands.first { p <= $0.upTo }?.color ?? mutedRed
    }

    /// Hard-edged gradient stops that reproduce `segment` across a continuous bar.
    static var segmentGradientStops: [(offset: CGFloat, color: RGB)] {
        var stops: [(CGFloat, RGB)] = []
        var start: CGFloat = 0
        for band in segmentBands {
            stops.append((start, band.color))
            stops.append((band.upTo, band.color))
            start = band.upTo
        }
        return stops
    }
}
