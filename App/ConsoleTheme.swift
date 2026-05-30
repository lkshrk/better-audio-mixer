import AppKit
import BamCore
import SwiftUI

// MARK: - Theme tokens

/// The BAM design token set, resolved for dark or light. Mirrors `buildTheme`
/// in the design handoff (shared.jsx).
struct Theme {
    var dark: Bool
    var accent: Color
    var accentInk: Color
    var glow: Color
    var soft: Color
    var bg: Color
    var bar: Color
    var panel: Color
    var surface: Color
    var surface2: Color
    var sink: Color
    var line: Color
    var line2: Color
    var text: Color
    var dim: Color
    var faint: Color
    var ghost: Color
    var stripW: CGFloat
    var gap: CGFloat

    static let accentHex = Color(hex: "c084fc")

    static func make(dark: Bool) -> Theme {
        dark
            ? Theme(
                dark: true, accent: accentHex, accentInk: Color(hex: "1a1020"),
                glow: accentHex.opacity(0.45), soft: accentHex.opacity(0.16),
                bg: Color(hex: "17161c"), bar: Color(hex: "1b1a20"),
                panel: Color(hex: "17161c"), surface: Color(hex: "222129"),
                surface2: Color(hex: "26242e"), sink: Color(hex: "121216"),
                line: .white.opacity(0.06), line2: .white.opacity(0.11),
                text: Color(hex: "e9e9ee"), dim: Color(hex: "8a8a93"),
                faint: Color(hex: "6a6a73"), ghost: .white.opacity(0.16),
                stripW: 108, gap: 12)
            : Theme(
                dark: false, accent: accentHex, accentInk: .white,
                glow: accentHex.opacity(0.28), soft: accentHex.opacity(0.14),
                bg: Color(hex: "ececef"), bar: Color(hex: "f4f4f6"),
                panel: Color(hex: "f6f6f8"), surface: .white,
                surface2: .white, sink: Color(hex: "e7e7ea"),
                line: .black.opacity(0.09), line2: .black.opacity(0.14),
                text: .black.opacity(0.88), dim: .black.opacity(0.52),
                faint: .black.opacity(0.34), ghost: .black.opacity(0.14),
                stripW: 108, gap: 12)
    }
}

private struct ThemeKey: EnvironmentKey { static let defaultValue = Theme.make(dark: true) }
extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

// MARK: - Color helpers

extension Color {
    init(hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        let v = UInt64(s, radix: 16) ?? 0
        self = Color(red: Double((v >> 16) & 0xff) / 255,
                     green: Double((v >> 8) & 0xff) / 255,
                     blue: Double(v & 0xff) / 255)
    }

    private var srgb: (r: Double, g: Double, b: Double) {
        let n = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return (Double(n.redComponent), Double(n.greenComponent), Double(n.blueComponent))
    }

    /// Shift each channel by `amt` (in -255…255), matching shared.jsx `shade`.
    func shaded(_ amt: Double) -> Color {
        let c = srgb
        let f = amt / 255
        func clamp(_ x: Double) -> Double { min(1, max(0, x + f)) }
        return Color(red: clamp(c.r), green: clamp(c.g), blue: clamp(c.b))
    }

    var luminance: Double {
        let c = srgb
        return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
    }

    /// Ink color for text drawn on top of this fill (shared.jsx `pickInk`).
    var ink: Color { luminance > 0.62 ? .black.opacity(0.78) : .white }
}

/// Stable vivid identity color for an id when no explicit hue is stored.
enum Palette {
    static func hue(for id: String) -> Double { Double(abs(id.hashValue) % 360) / 360.0 }
    static func color(hue: Double) -> Color { Color(hue: hue, saturation: 0.5, brightness: 0.92) }
    static func color(forID id: String) -> Color { color(hue: hue(for: id)) }
}

enum Console {
    static func destLabel(_ dest: MixDestination, devices: [AudioDevice]) -> String {
        switch dest {
        case .virtualSlot(let s): return "BAM \(s)"
        case .hardware(let uid): return devices.first { $0.uid == uid }?.name ?? "Output"
        }
    }
}

/// dB label for a 0…1 linear fader value. 0.001 ⇒ −∞.
func consoleDb(_ level: Double) -> String {
    if level <= 0.001 { return "\u{2212}\u{221e}" }
    let db = 20 * log10(level)
    if db >= 0 { return String(format: "+%.1f", db) }
    return String(format: "%.1f", db)
}

// MARK: - Meter

/// LED-segment level meter. Vertical by default; horizontal for compact rows.
struct Meter: View {
    @Environment(\.theme) private var t
    let level: Float
    var active: Bool = true
    var width: CGFloat = 7
    var height: CGFloat = 150
    var horizontal: Bool = false

    private var segs: Int { max(8, Int(((horizontal ? width : height) / 9).rounded())) }

    var body: some View {
        let frac = active ? CGFloat(RMSMeter.fraction(dbFS: level)) : 0
        let lit = Int((CGFloat(segs) * frac).rounded(.up))
        Group {
            if horizontal {
                HStack(spacing: 1.5) { cells(lit) }
            } else {
                VStack(spacing: 1.5) { cells(lit, reversed: true) }
            }
        }
        .padding(1.5)
        .frame(width: horizontal ? height : width, height: horizontal ? width : height)
        .animation(.linear(duration: 0.12), value: active)
    }

    @ViewBuilder private func cells(_ lit: Int, reversed: Bool = false) -> some View {
        ForEach(0..<segs, id: \.self) { i in
            let idx = reversed ? segs - 1 - i : i
            let frac = CGFloat(idx + 1) / CGFloat(segs)
            let c: Color = frac > 0.8 ? Color(hex: "ff5b5b")
                : frac > 0.62 ? Color(hex: "ffcf4d") : Color(hex: "36d07a")
            RoundedRectangle(cornerRadius: 1.5)
                .fill(c)
                .opacity(idx < lit ? 1 : 0.12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Volume taper
// AudioTaper is defined in BamCore (public). ConsoleTheme gets it via `import BamCore`.

// MARK: - Fader

struct Fader: View {
    @Environment(\.theme) private var t
    @Binding var value: Double
    var accentTrack: Bool = true
    var disabled: Bool = false
    var height: CGFloat = 150
    /// When true the slider position maps 1:1 to `value` (no cube taper). Used by
    /// the master strip, where `value` is the hardware device's volume scalar —
    /// already perceptual — rather than a raw linear router gain.
    var linear: Bool = false
    var onCommit: () -> Void = {}

    private let cap = CGSize(width: 22, height: 18)

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let v = CGFloat(linear ? min(1, max(0, value)) : AudioTaper.position(fromGain: value))
            ZStack(alignment: .bottom) {
                Capsule().fill(t.sink).frame(width: 4)
                    .overlay(Capsule().stroke(t.line, lineWidth: 1))
                Capsule()
                    .fill(accentTrack ? t.accent : t.ghost)
                    .frame(width: 4, height: max(0, (h - cap.height) * v) + cap.height / 2)
                    .shadow(color: accentTrack ? t.glow : .clear, radius: 5)
                capView
                    .offset(y: -(h - cap.height) * v)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .opacity(disabled ? 0.35 : 1)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        guard !disabled else { return }
                        let p = 1 - Double((g.location.y - cap.height / 2) / (h - cap.height))
                        value = linear ? min(1, max(0, p)) : AudioTaper.gain(fromPosition: p)
                    }
                    .onEnded { _ in if !disabled { onCommit() } }
            )
        }
        .frame(width: 26, height: height)
    }

    private var capView: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(LinearGradient(
                colors: t.dark ? [Color(hex: "3a3a44"), Color(hex: "2a2a32")]
                               : [.white, Color(hex: "e9e9ee")],
                startPoint: .top, endPoint: .bottom))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(t.line2, lineWidth: 0.5))
            .overlay(
                Capsule().fill(t.accent.opacity(0.85))
                    .frame(height: 1.5).padding(.horizontal, 4))
            .frame(width: cap.width, height: cap.height)
            .shadow(color: .black.opacity(t.dark ? 0.55 : 0.22), radius: 3, y: 2)
    }
}

// MARK: - Knob

struct Knob: View {
    @Environment(\.theme) private var t
    @Binding var value: Double
    var size: CGFloat = 38
    var disabled: Bool = false
    var onCommit: () -> Void = {}

    @State private var dragStart: Double?

    private var angle: Double { -135 + value * 270 }

    var body: some View {
        let v = CGFloat(min(1, max(0, value)))
        ZStack {
            Circle().trim(from: 0, to: 0.75)
                .stroke(t.sink, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(135))
            Circle().trim(from: 0, to: 0.75 * v)
                .stroke(disabled ? t.ghost : t.accent,
                        style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(135))
                .shadow(color: disabled ? .clear : t.glow, radius: 4)
            knobBody
        }
        .frame(width: size, height: size)
        .opacity(disabled ? 0.3 : 1)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    guard !disabled else { return }
                    if dragStart == nil { dragStart = value }
                    let nv = (dragStart ?? value) + Double(-g.translation.height / 180)
                    value = min(1, max(0, nv))
                }
                .onEnded { _ in dragStart = nil; if !disabled { onCommit() } }
        )
    }

    private var knobBody: some View {
        ZStack(alignment: .top) {
            Circle()
                .fill(RadialGradient(
                    colors: t.dark ? [Color(hex: "33333d"), Color(hex: "1f1f26")]
                                   : [.white, Color(hex: "eaeaef")],
                    center: .init(x: 0.5, y: 0.25), startRadius: 0, endRadius: size * 0.6))
                .overlay(Circle().stroke(t.line2, lineWidth: 0.5))
            Capsule()
                .fill(disabled ? t.faint : t.accent)
                .frame(width: 2, height: size * 0.22)
                .padding(.top, 4)
                .rotationEffect(.degrees(angle))
        }
        .padding(7)
    }
}

// MARK: - Device icon glyph

/// A device icon value is stored in one `String?` field. An ASCII value is an SF
/// Symbol name (line glyph, e.g. "headphones"); a non-ASCII value is a real emoji
/// grapheme. `nil` falls back to the colored monogram chip.
enum DeviceIcon {
    static func isSymbol(_ s: String) -> Bool { s.unicodeScalars.first?.isASCII ?? false }
}

// MARK: - Chip (monogram identity)

struct Chip: View {
    @Environment(\.theme) private var t
    let mono: String
    let color: Color
    var emoji: String? = nil
    var size: CGFloat = 28
    var radius: CGFloat? = nil
    var ring: Bool = false
    var faded: Bool = false

    var body: some View {
        let r = radius ?? size * 0.28
        glyph
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: r)
                    .fill(faded
                        ? AnyShapeStyle(t.surface2)
                        : AnyShapeStyle(LinearGradient(
                            colors: [color, color.shaded(-22)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))))
            .overlay(RoundedRectangle(cornerRadius: r).stroke(.black.opacity(0.25), lineWidth: 0.5))
            .overlay(
                RoundedRectangle(cornerRadius: r)
                    .stroke(t.accent, lineWidth: ring ? 1.5 : 0))
            .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
    }

    @ViewBuilder private var glyph: some View {
        if let e = emoji, DeviceIcon.isSymbol(e) {
            Image(systemName: e)
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(faded ? AnyShapeStyle(t.faint) : AnyShapeStyle(color.ink))
        } else if let e = emoji {
            Text(e)
                .font(.system(size: size * 0.52, weight: .bold))
                .foregroundStyle(.primary)
        } else {
            Text(mono)
                .font(.system(size: size * 0.4, weight: .bold)).tracking(-0.4)
                .foregroundStyle(faded ? AnyShapeStyle(t.faint) : AnyShapeStyle(color.ink))
        }
    }
}

/// Resolved app icons by bundle id (NSWorkspace lookup), cached per process.
@MainActor
enum AppIconCache {
    private static var cache: [String: NSImage?] = [:]
    static func icon(for bundleID: String) -> NSImage? {
        if let hit = cache[bundleID] { return hit }
        let img = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        cache[bundleID] = img
        return img
    }
}

/// The real app icon for a bundle id; falls back to a `Chip` monogram when the
/// app isn't installed/resolvable.
struct AppIcon: View {
    let bundleID: String
    let fallbackMono: String
    let color: Color
    var size: CGFloat = 28
    var radius: CGFloat? = nil

    var body: some View {
        let r = radius ?? size * 0.28
        if let img = AppIconCache.icon(for: bundleID) {
            Image(nsImage: img)
                .resizable().interpolation(.high)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: r))
                .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
        } else {
            Chip(mono: fallbackMono, color: color, size: size, radius: radius)
        }
    }
}

// MARK: - Small controls

struct IconBtn: View {
    @Environment(\.theme) private var t
    let label: String
    var active: Bool = false
    var danger: Bool = false
    var size: CGFloat = 26
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(active ? (danger ? AnyShapeStyle(.white) : AnyShapeStyle(t.accentInk))
                                        : AnyShapeStyle(t.dim))
                .frame(width: size, height: size * 0.84)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(active ? (danger ? Color(hex: "ff5b5b") : t.accent) : t.surface2))
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .stroke(active ? .clear : t.line2, lineWidth: 0.5))
                .shadow(color: active ? (danger ? Color(hex: "ff5b5b").opacity(0.4) : t.glow) : .clear,
                        radius: 6)
        }
        .buttonStyle(.plain)
    }
}

struct Pill: View {
    @Environment(\.theme) private var t
    var tone: Color? = nil
    let content: AnyView

    init(tone: Color? = nil, @ViewBuilder _ content: () -> some View) {
        self.tone = tone
        self.content = AnyView(content())
    }

    var body: some View {
        content
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tone ?? t.dim)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(Capsule().fill(tone?.opacity(0.16) ?? t.surface2))
            .overlay(Capsule().stroke(tone?.opacity(0.3) ?? t.line2, lineWidth: 0.5))
    }
}

struct Tag: View {
    @Environment(\.theme) private var t
    let text: String
    var tone: Color? = nil

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .tracking(0.4)
            .foregroundStyle(tone ?? t.faint)
    }
}

/// The BAM app glyph: three white bars on an accent gradient tile.
struct BamMark: View {
    @Environment(\.theme) private var t
    var size: CGFloat = 20

    var body: some View {
        HStack(spacing: size * 0.085) {
            ForEach([0.4, 0.62, 0.4], id: \.self) { h in
                RoundedRectangle(cornerRadius: size * 0.06)
                    .fill(.white)
                    .frame(width: size * 0.1, height: size * h)
            }
        }
        .frame(width: size, height: size)
        .background(
            RoundedRectangle(cornerRadius: size * 0.26)
                .fill(LinearGradient(
                    colors: [t.accent.shaded(45), t.accent, t.accent.shaded(-58)],
                    startPoint: .topLeading, endPoint: .bottomTrailing)))
        .shadow(color: .black.opacity(0.4), radius: 1.5, y: 1)
    }
}
