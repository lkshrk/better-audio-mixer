import AppKit
import BamCore
import SwiftUI

// MARK: - Theme tokens

/// The BAM design token set; mirrors `buildTheme` in the design handoff (shared.jsx).
struct Theme {
    var dark: Bool
    var accent: Color
    var accentInk: Color
    var glow: Color
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
    static let danger = Color(hex: "ff5b5b")
    static let warning = Color(hex: "f2b84b")
    static let standard = make(dark: true)

    static func make(dark: Bool) -> Theme {
        dark
            ? Theme(
                dark: true, accent: accentHex, accentInk: Color(hex: "1a1020"),
                glow: accentHex.opacity(0.45),
                bg: Color(hex: "17161c"), bar: Color(hex: "1b1a20"),
                panel: Color(hex: "17161c"), surface: Color(hex: "222129"),
                surface2: Color(hex: "26242e"), sink: Color(hex: "121216"),
                line: .white.opacity(0.06), line2: .white.opacity(0.11),
                text: Color(hex: "e9e9ee"), dim: Color(hex: "8a8a93"),
                faint: Color(hex: "6a6a73"), ghost: .white.opacity(0.16),
                stripW: 108, gap: 12)
            : Theme(
                dark: false, accent: accentHex, accentInk: .white,
                glow: accentHex.opacity(0.28),
                bg: Color(hex: "ececef"), bar: Color(hex: "f4f4f6"),
                panel: Color(hex: "f6f6f8"), surface: .white,
                surface2: .white, sink: Color(hex: "e7e7ea"),
                line: .black.opacity(0.09), line2: .black.opacity(0.14),
                text: .black.opacity(0.88), dim: .black.opacity(0.52),
                faint: .black.opacity(0.34), ghost: .black.opacity(0.14),
                stripW: 108, gap: 12)
    }
}

private struct ThemeKey: EnvironmentKey { static let defaultValue = Theme.standard }
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
    static func hue(for id: String) -> Double {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in id.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
        return Double(hash % 360) / 360.0
    }
    static func color(hue: Double) -> Color { Color(hue: hue, saturation: 0.5, brightness: 0.92) }
    static func color(forID id: String) -> Color { color(hue: hue(for: id)) }
}

// MARK: - Meter

/// Vertical LED-segment level meter.
struct Meter: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.theme) private var t
    let level: Float
    var peak: Float = RMSMeter.floorDB
    var active: Bool = true
    var width: CGFloat = 5
    var height: CGFloat = 150

    private static let low = Color(hex: "36d07a")
    private static let mid = Color(hex: "ffcf4d")
    private static let high = Theme.danger
    @MainActor private static var cellColorCache: [Int: [Color]] = [:]

    @MainActor private static func cellColors(segs: Int) -> [Color] {
        if let cached = cellColorCache[segs] { return cached }
        let colors = (0..<segs).map { idx -> Color in
            let frac = CGFloat(idx + 1) / CGFloat(segs)
            return frac > 0.8 ? high : frac > 0.62 ? mid : low
        }
        cellColorCache[segs] = colors
        return colors
    }

    private var segs: Int { max(8, Int((height / 9).rounded())) }

    var body: some View {
        let frac = active ? CGFloat(RMSMeter.fraction(dbFS: level)) : 0
        let peakFrac = active ? CGFloat(RMSMeter.fraction(dbFS: peak)) : 0
        let lit = Int((CGFloat(segs) * frac).rounded(.up))
        let colors = Self.cellColors(segs: segs)
        VStack(spacing: 1.5) {
            ForEach((0..<segs).reversed(), id: \.self) { idx in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(colors[idx])
                    .opacity(idx < lit ? 1 : 0.12)
                    // Fast attack, gentle release: avoids flicker at segment boundaries.
                    .animation(reduceMotion || !active ? nil : .easeOut(duration: idx < lit ? 0.04 : 0.22),
                               value: idx < lit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(1.5)
        .frame(width: width, height: height)
        .overlay(alignment: .bottom) {
            if peakFrac > 0 {
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(peakFrac > 0.8 ? Self.high : t.accent)
                    .frame(width: width, height: 2)
                    .offset(y: -(0.5 + (height - 3) * peakFrac))
            }
        }
    }
}

// MARK: - Fader

struct Fader: View {
    @Environment(\.theme) private var t
    @Binding var value: Double
    var accentTrack: Bool = true
    var disabled: Bool = false
    var dimmed: Bool = false
    var height: CGFloat = 150
    /// Position maps 1:1 to `value` (no cube taper); the master strip's hardware scalar is already perceptual.
    var linear: Bool = false
    var accessibilityLabel: String = "Level"
    /// Throttled live value during the drag; `onCommit` fires once on release.
    var onChange: (Double) -> Void = { _ in }
    var onCommit: () -> Void = {}

    @State private var lastChange: TimeInterval = 0
    private let cap = CGSize(width: 22, height: 18)

    private var percent: Int {
        linear ? Int((min(1, max(0, value)) * 100).rounded()) : AudioTaper.percent(fromGain: value)
    }

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let v = CGFloat(linear ? min(1, max(0, value)) : AudioTaper.position(fromGain: value))
            ZStack(alignment: .bottom) {
                Capsule().fill(t.sink).frame(width: 6)
                    .overlay(Capsule().stroke(t.line, lineWidth: 1))
                Capsule()
                    .fill(accentTrack ? t.accent : t.ghost)
                    .frame(width: 6, height: max(0, (h - cap.height) * v) + cap.height / 2)
                    .shadow(color: accentTrack ? t.glow : .clear, radius: 5)
                capView
                    .offset(y: -(h - cap.height) * v)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .opacity(disabled ? 0.35 : dimmed ? 0.45 : 1)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        guard !disabled else { return }
                        let p = 1 - Double((g.location.y - cap.height / 2) / (h - cap.height))
                        value = linear ? min(1, max(0, p)) : AudioTaper.gain(fromPosition: p)
                        let now = Date.timeIntervalSinceReferenceDate
                        guard now - lastChange >= Tuning.faderChangeInterval else { return }
                        lastChange = now
                        onChange(value)
                    }
                    .onEnded { _ in
                        guard !disabled else { return }
                        lastChange = 0
                        onCommit()
                    }
            )
        }
        .frame(width: 26, height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue("\(percent) percent")
        .accessibilityAdjustableAction { direction in
            nudge(by: direction == .increment ? 0.05 : -0.05)
        }
    }

    /// Moves the perceptual position by `delta` and routes it through the drag path.
    func nudge(by delta: Double) {
        guard !disabled else { return }
        let pos = linear ? min(1, max(0, value)) : AudioTaper.position(fromGain: value)
        let next = min(1, max(0, pos + delta))
        value = linear ? next : AudioTaper.gain(fromPosition: next)
        onChange(value)
        onCommit()
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

// MARK: - Device icon glyph

/// An ASCII icon value is an SF Symbol name; a non-ASCII value is an emoji grapheme; nil is the monogram chip.
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
    private enum Entry {
        case found(NSImage)
        case missing
    }

    private static var cache: [String: Entry] = [:]
    static var resolveIconForTests: ((String) -> NSImage?)?

    static func icon(for bundleID: String) -> NSImage? {
        if let hit = cache[bundleID] {
            switch hit {
            case .found(let image): return image
            case .missing: return nil
            }
        }
        let img: NSImage?
        if let resolveIconForTests {
            img = resolveIconForTests(bundleID)
        } else {
            img = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
                .map { NSWorkspace.shared.icon(forFile: $0.path) }
        }
        cache[bundleID] = img.map(Entry.found) ?? .missing
        return img
    }

    static func resetForTests() {
        cache.removeAll()
    }
}

/// The real app icon for a bundle id; falls back to a `Chip` monogram when unresolvable.
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
                        .fill(active ? (danger ? Theme.danger : t.accent) : t.surface2))
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .stroke(active ? .clear : t.line2, lineWidth: 0.5))
                .shadow(color: active ? (danger ? Theme.danger.opacity(0.4) : t.glow) : .clear,
                        radius: 6)
        }
        .buttonStyle(.plain)
    }
}

struct Pill<Content: View>: View {
    @Environment(\.theme) private var t
    var tone: Color? = nil
    let content: Content

    init(tone: Color? = nil, @ViewBuilder _ content: () -> Content) {
        self.tone = tone
        self.content = content()
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
