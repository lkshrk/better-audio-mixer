import AppKit
import Foundation
import Testing
@testable import BAMStreamDeck

/// Renders the key / dial / mute-key matrix to PNG contact sheets under `BAM_SNAPSHOT_DIR`.
@MainActor
struct ContactSheetTests {

    private static let pluginDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("StreamDeck/me.harke.better-audio-mixer.sdPlugin")

    private static var snapshotDir: URL? {
        ProcessInfo.processInfo.environment["BAM_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
    }

    private struct Layout: Decodable {
        struct Item: Decodable { let key: String; let rect: [CGFloat] }
        let id: String
        let items: [Item]
        func rect(_ key: String) -> NSRect? {
            items.first { $0.key == key }.map { NSRect(x: $0.rect[0], y: $0.rect[1], width: $0.rect[2], height: $0.rect[3]) }
        }
    }

    private static func layout(_ file: String) throws -> Layout {
        try JSONDecoder().decode(Layout.self, from: Data(contentsOf: pluginDir.appendingPathComponent("layouts/\(file)")))
    }

    private static func topDown(_ r: NSRect) -> NSRect {
        NSRect(x: r.minX, y: RetroMeterDrawing.lcdSize.height - r.maxY, width: r.width, height: r.height)
    }

    @Test func layoutRectsMatchTheDrawingConstants() throws {
        let channel = try Self.layout("channel.json")
        let meter = try Self.layout("meter-focus.json")
        let retro = try Self.layout("retro.json")
        for layout in [channel, meter, retro] {
            #expect(layout.rect("canvas") == NSRect(x: 0, y: 0, width: 200, height: 100))
            #expect(layout.rect("icon") == nil)
        }
        #expect(channel.rect("liveMeter") == Self.topDown(RetroMeterDrawing.lcdChannelBar))
        #expect(meter.rect("leftMeter") == Self.topDown(RetroMeterDrawing.lcdLeftBar))
        #expect(meter.rect("rightMeter") == Self.topDown(RetroMeterDrawing.lcdRightBar))
        #expect(retro.rect("levelNeedle") == Self.topDown(RetroMeterDrawing.lcdNeedleLayer))
    }

    // MARK: - Sheets

    private static let game = KeyImage.Glyph.emoji("🎮")
    private static let levels: [(label: String, level: Float, muted: Bool)] = [
        ("muted", 0, true), ("level 0.00", 0, false), ("level 0.45", 0.45, false),
        ("level 0.85", 0.85, false), ("level 1.00 clip", 1, false),
    ]

    private func key(_ style: KeyStyleImage.KeyStyle, glyph: KeyImage.Glyph? = game, monogram: String = "GA",
                     accent: RGB = Palette.accents[4], name: String = "Game", pct: Int = 62,
                     level: Float, muted: Bool = false) -> NSImage? {
        image(KeyStyleImage.render(KeyStyleImage.Input(
            style: style, glyph: glyph, monogram: monogram, accent: accent, name: name, pct: pct,
            level: level, leftLevel: level, rightLevel: max(0, level - 0.2), muted: muted)))
    }

    @Test func keysContactSheet() throws {
        guard let dir = Self.snapshotDir else { return }
        let sheet = Sheet(title: "keys.png — KeyStyleImage.render, 144px native shown 2x (nearest)", cell: NSSize(width: 144, height: 144))
        for style in [KeyStyleImage.KeyStyle.channel, .meter, .retro] {
            sheet.row("key style: \(style.rawValue)  (emoji glyph, pct 62, L=level R=level-0.2)",
                      Self.levels.map { (key(style, level: $0.level, muted: $0.muted), "\(style.rawValue) 🎮 Game 62%\n\($0.label)") })
        }
        sheet.row("name / glyph variants (level 0.45)", [
            (key(.channel, glyph: nil, monogram: "DV", accent: Palette.accents[1], name: "Discord Voice Chat", pct: 100, level: 0.45), "channel monogram DV\nlong name, pct 100"),
            (key(.meter, glyph: nil, monogram: "DV", accent: Palette.accents[1], name: "Discord Voice Chat", pct: 5, level: 0.45), "meter monogram DV\nlong name, pct 5"),
            (key(.retro, glyph: nil, monogram: "DV", accent: Palette.accents[1], name: "Discord Voice Chat", pct: 100, level: 0.45), "retro monogram DV\nlong name, pct 100"),
            (key(.channel, glyph: .symbol("speaker.wave.2.fill"), monogram: "SP", accent: Palette.accents[1], name: "Spotify", pct: 40, level: 0.45), "channel symbol fallback\nspeaker.wave.2.fill"),
            (key(.channel, glyph: .emoji(""), monogram: "?", accent: Palette.accents[3], name: "", pct: 0, level: 0.45), "channel empty emoji\nempty name, pct 0"),
        ])
        sheet.row("emoji headers rendered as mono SF Symbols (level 0.45)", [
            (key(.channel, glyph: .emoji("🎧"), monogram: "MU", accent: Palette.accents[0], name: "Music", pct: 62, level: 0.45), "channel 🎧\nheadphones"),
            (key(.channel, glyph: .emoji("🌐"), monogram: "BR", accent: Palette.accents[1], name: "Browser", pct: 62, level: 0.45), "channel 🌐\nglobe"),
            (key(.meter, glyph: .emoji("🎶"), monogram: "SP", accent: Palette.accents[2], name: "Spotify", pct: 62, level: 0.45), "meter 🎶\nmusic.note.list"),
            (key(.retro, glyph: .emoji("🎮"), monogram: "GA", accent: Palette.accents[4], name: "Game", pct: 62, level: 0.45), "retro 🎮\ngamecontroller.fill"),
            (key(.channel, glyph: .emoji("🤖"), monogram: "AI", accent: Palette.accents[3], name: "Assistant", pct: 62, level: 0.45), "channel 🤖\ncpu.fill"),
        ])
        sheet.row("master (output SF Symbol glyph, purple accent)", [
            (key(.channel, glyph: .symbol("hifispeaker.fill"), monogram: "M", accent: Palette.masterAccent, name: "Master", pct: 75, level: 0.4), "channel master\nhifispeaker.fill 75%"),
            (key(.meter, glyph: .symbol("headphones"), monogram: "M", accent: Palette.masterAccent, name: "Master", pct: 75, level: 0.5), "meter master\nheadphones 75%"),
            (key(.retro, glyph: .symbol("hifispeaker.fill"), monogram: "M", accent: Palette.masterAccent, name: "Master", pct: 75, level: 0.55), "retro master\nhifispeaker.fill 75%"),
            (key(.retro, glyph: .symbol("headphones"), monogram: "M", accent: Palette.masterAccent, name: "Master", pct: 75, level: 0, muted: true), "retro master muted\nheadphones"),
            (key(.meter, glyph: .symbol("hifispeaker.fill"), monogram: "M", accent: Palette.masterAccent, name: "Master", pct: 75, level: 1), "meter master clip\nhifispeaker.fill"),
        ])
        try sheet.write(to: dir.appendingPathComponent("keys.png"))
    }

    private func dial(_ layoutFile: String, style: KeyStyleImage.KeyStyle, glyph: KeyImage.Glyph? = game,
                      monogram: String = "GA", accent: RGB = Palette.accents[4], name: String = "Game",
                      pct: Int = 62, level: Float, peakBoost: Float = 0.12, muted: Bool = false) throws -> NSImage? {
        let layout = try Self.layout(layoutFile)
        let canvas = RetroMeterDrawing.renderLCDStatic(RetroMeterDrawing.LCDInput(
            style: style, glyph: glyph, monogram: monogram, accent: accent, name: name,
            pct: pct, muted: muted))
        var layers: [(String, String)] = [("canvas", canvas ?? "")]
        let left = level, right = max(0, level - 0.2)
        let peak = { (l: Float) in min(1, l + peakBoost) }
        switch style {
        case .channel:
            let r = RetroMeterDrawing.lcdChannelBar
            layers.append(("liveMeter", RetroMeterDrawing.renderLCDLevelBarSVG(
                width: Int(r.width), height: Int(r.height),
                step: MeterScale.quantize(max(left, right), steps: MeterScale.lcdBarSteps, muted: muted),
                peakStep: MeterScale.quantize(peak(max(left, right)), steps: MeterScale.lcdBarSteps, muted: muted), muted: muted)))
        case .meter:
            let r = RetroMeterDrawing.lcdLeftBar
            for (key, l) in [("leftMeter", left), ("rightMeter", right)] {
                layers.append((key, RetroMeterDrawing.renderLCDLevelBarSVG(
                    width: Int(r.width), height: Int(r.height),
                    step: MeterScale.quantize(l, steps: MeterScale.lcdBarSteps, muted: muted),
                    peakStep: MeterScale.quantize(peak(l), steps: MeterScale.lcdBarSteps, muted: muted), muted: muted)))
            }
        case .retro:
            layers.append(("levelNeedle", RetroMeterDrawing.renderRetroLCDNeedleSVG(
                step: MeterScale.quantize(level, steps: MeterScale.lcdNeedleSteps, muted: muted),
                peakStep: MeterScale.quantize(peak(level), steps: MeterScale.lcdNeedleSteps, muted: muted), muted: muted)))
        }
        let size = RetroMeterDrawing.lcdSize
        return rasterize(size: size) {
            for (key, uri) in layers {
                guard let rect = layout.rect(key), let img = image(uri) else {
                    Issue.record("layout \(layoutFile) lacks \(key) or the layer failed to decode")
                    continue
                }
                img.draw(in: NSRect(x: rect.minX, y: size.height - rect.maxY, width: rect.width, height: rect.height))
            }
        }
    }

    @Test func dialsContactSheet() throws {
        guard let dir = Self.snapshotDir else { return }
        let sheet = Sheet(title: "dials.png — Stream Deck+ touch strip 200x100 composed per layout json, shown 2x (nearest)", cell: NSSize(width: 200, height: 100))
        for (file, style) in [("channel.json", KeyStyleImage.KeyStyle.channel), ("meter-focus.json", .meter), ("retro.json", .retro)] {
            sheet.row("dial layout \(file)  (style \(style.rawValue))", try Self.levels.map {
                (try dial(file, style: style, level: $0.level, muted: $0.muted), "\(file) 🎮 Game 62%\n\($0.label) peak +0.12")
            })
        }
        sheet.row("master / name variants", [
            (try dial("channel.json", style: .channel, glyph: .symbol("hifispeaker.fill"), monogram: "M", accent: Palette.masterAccent, name: "Master", pct: 75, level: 0.5), "channel master\nhifispeaker.fill 75%"),
            (try dial("meter-focus.json", style: .meter, glyph: .symbol("headphones"), monogram: "M", accent: Palette.masterAccent, name: "Master", pct: 75, level: 0.5), "meter master\nheadphones 75%"),
            (try dial("retro.json", style: .retro, glyph: .symbol("hifispeaker.fill"), monogram: "M", accent: Palette.masterAccent, name: "Master", pct: 75, level: 0.45), "retro master\nhifispeaker.fill 75%"),
            (try dial("retro.json", style: .retro, glyph: nil, monogram: "DV", accent: Palette.accents[1], name: "Discord Voice Chat", pct: 100, level: 0.3), "retro monogram\nlong name pct 100"),
            (try dial("channel.json", style: .channel, glyph: .symbol("speaker.wave.2.fill"), monogram: "DV", accent: Palette.accents[1], name: "Discord Voice Chat", pct: 5, level: 0, muted: true), "channel symbol muted\nlong name pct 5"),
        ])
        sheet.row("emoji headers rendered as mono SF Symbols (level 0.45)", [
            (try dial("channel.json", style: .channel, glyph: .emoji("🎧"), monogram: "MU", accent: Palette.accents[0], name: "Music", level: 0.45), "channel 🎧\nheadphones"),
            (try dial("channel.json", style: .channel, glyph: .emoji("🌐"), monogram: "BR", accent: Palette.accents[1], name: "Browser", level: 0.45), "channel 🌐\nglobe"),
            (try dial("meter-focus.json", style: .meter, glyph: .emoji("🎶"), monogram: "SP", accent: Palette.accents[2], name: "Spotify", level: 0.45), "meter 🎶\nmusic.note.list"),
            (try dial("retro.json", style: .retro, glyph: .emoji("🎮"), monogram: "GA", accent: Palette.accents[4], name: "Game", level: 0.45), "retro 🎮\ngamecontroller.fill"),
            (try dial("channel.json", style: .channel, glyph: .emoji("🤖"), monogram: "AI", accent: Palette.accents[3], name: "Assistant", level: 0.45), "channel 🤖\ncpu.fill"),
        ])
        try sheet.write(to: dir.appendingPathComponent("dials.png"))
    }

    @Test func muteKeysContactSheet() throws {
        guard let dir = Self.snapshotDir else { return }
        let glyphs: [(KeyImage.Glyph, String)] = [
            (.emoji("🎮"), "emoji 🎮"), (.emoji("🎧"), "emoji 🎧"), (.symbol("hifispeaker.fill"), "hifispeaker.fill"),
            (.symbol("headphones"), "headphones"), (.symbol("speaker.wave.2.fill"), "speaker.wave.2.fill"), (.symbol("display"), "display"),
        ]
        let sheet = Sheet(title: "mute-keys.png — KeyImage.render 144px, shown 2x (nearest), over black", cell: NSSize(width: 144, height: 144))
        sheet.row("KeyImage unmuted (output key glyph)", glyphs.map { (image(KeyImage.render($0.0, muted: false)), "\($0.1)\nunmuted") })
        sheet.row("KeyImage muted (red slash, no chip)", glyphs.map { (image(KeyImage.render($0.0, muted: true)), "\($0.1)\nmuted") })
        try sheet.write(to: dir.appendingPathComponent("mute-keys.png"))
    }

    // MARK: - Compositing

    private func image(_ uri: String?) -> NSImage? {
        guard let uri, let comma = uri.firstIndex(of: ",") else { return nil }
        let payload = String(uri[uri.index(after: comma)...])
        let data: Data?
        if uri.hasPrefix("data:image/svg+xml;charset=utf8,") {
            data = payload.removingPercentEncoding.map { Data($0.utf8) }
        } else {
            data = Data(base64Encoded: payload)
        }
        return data.flatMap(NSImage.init(data:))
    }

    private func rasterize(size: NSSize, _ body: () -> Void) -> NSImage? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        body()
        ctx.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    @MainActor
    private final class Sheet {
        private struct Row { let title: String; let cells: [(NSImage?, String)] }
        private let title: String
        private let cell: NSSize
        private var rows: [Row] = []
        private let scale: CGFloat = 2
        private let pad: CGFloat = 12
        private let labelHeight: CGFloat = 34
        private let rowTitleHeight: CGFloat = 26

        init(title: String, cell: NSSize) {
            self.title = title
            self.cell = cell
        }

        func row(_ title: String, _ cells: [(NSImage?, String)]) {
            rows.append(Row(title: title, cells: cells))
        }

        func write(to url: URL) throws {
            let columns = rows.map(\.cells.count).max() ?? 1
            let cellW = cell.width * scale, cellH = cell.height * scale
            let width = pad + CGFloat(columns) * (cellW + pad)
            let rowH = rowTitleHeight + cellH + labelHeight + pad
            let height = 40 + CGFloat(rows.count) * rowH
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(height),
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let ctx = NSGraphicsContext(bitmapImageRep: rep) else { throw CocoaError(.fileWriteUnknown) }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ctx
            ctx.imageInterpolation = .none
            NSColor(calibratedWhite: 0.17, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: width, height: height).fill()
            var y = height - 30
            text(title, at: NSPoint(x: pad, y: y), bold: true, color: .white)
            for row in rows {
                y -= rowTitleHeight
                text(row.title, at: NSPoint(x: pad, y: y), bold: true, color: NSColor(calibratedRed: 0.5, green: 0.7, blue: 1, alpha: 1))
                let top = y - 6
                for (i, (image, label)) in row.cells.enumerated() {
                    let x = pad + CGFloat(i) * (cellW + pad)
                    let frame = NSRect(x: x, y: top - cellH, width: cellW, height: cellH)
                    NSColor.black.setFill()
                    frame.fill()
                    NSColor(calibratedWhite: 0.3, alpha: 1).setStroke()
                    NSBezierPath(rect: frame.insetBy(dx: 0.5, dy: 0.5)).stroke()
                    if let image { image.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1) }
                    text(label, at: NSPoint(x: x, y: top - cellH - 4), bold: false, color: NSColor(calibratedWhite: 0.85, alpha: 1))
                }
                y = top - cellH - labelHeight - pad
            }
            ctx.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()
            guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: url)
            #expect(png.count > 1000, "\(url.lastPathComponent) should not be empty")
        }

        private func text(_ s: String, at origin: NSPoint, bold: Bool, color: NSColor) {
            let font = NSFont.monospacedSystemFont(ofSize: 11, weight: bold ? .bold : .regular)
            let attributed = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
            let h = attributed.size().height
            attributed.draw(at: NSPoint(x: origin.x, y: origin.y - h))
        }
    }
}
