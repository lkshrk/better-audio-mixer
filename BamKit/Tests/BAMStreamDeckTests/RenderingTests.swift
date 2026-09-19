import AppKit
import Testing
@testable import BAMStreamDeck

@MainActor
struct LevelMappingTests {

    @Test func levelFractionClampsAtFloorAndCeiling() {
        #expect(ActionRouter.levelFraction(-60) == 0)
        #expect(ActionRouter.levelFraction(-90) == 0)
        #expect(ActionRouter.levelFraction(0) == 1)
        #expect(ActionRouter.levelFraction(5) == 1)
        #expect(abs(ActionRouter.levelFraction(-30) - 0.5) < 0.0001)
    }

    @Test func quantizeIsSharedByEveryScale() {
        #expect(MeterScale.quantize(0.62, steps: MeterScale.lcdNeedleSteps, muted: false) == 56)
        #expect(MeterScale.quantize(0.754, steps: MeterScale.lcdBarSteps, muted: false) == 75)
        #expect(MeterScale.quantize(1.5, steps: 90, muted: false) == 90)
        #expect(MeterScale.quantize(0.8, steps: 90, muted: true) == 0)
        #expect(MeterScale.segmentCount(for: .channel) == 12)
        #expect(MeterScale.segmentCount(for: .meter) == 18)
        #expect(MeterScale.segmentCount(for: .retro) == MeterScale.keyNeedleSteps)
    }
}

@MainActor
struct WrapPosTests {

    @Test func positiveStepAtCeilingWrapsToZero() {
        #expect(ActionRouter.wrapPos(pct: 100, step: 0.05) == 0)
    }

    @Test func negativeStepAtFloorWrapsToOne() {
        #expect(ActionRouter.wrapPos(pct: 0, step: -0.05) == 1)
    }

    @Test func midRangeDoesNotWrap() {
        #expect(ActionRouter.wrapPos(pct: 50, step: 0.05) == nil)
        #expect(ActionRouter.wrapPos(pct: 50, step: -0.05) == nil)
    }

    @Test func ceilingWithNegativeStepDoesNotWrap() {
        #expect(ActionRouter.wrapPos(pct: 100, step: -0.05) == nil)
        #expect(ActionRouter.wrapPos(pct: 0, step: 0.05) == nil)
    }
}

@MainActor
struct GlyphMappingTests {

    @Test func everyMappedEmojiResolvesToAnInstalledSymbol() {
        for (emoji, name) in GlyphDrawing.emojiSymbols {
            #expect(GlyphDrawing.symbolName(forEmoji: emoji) == name)
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(emoji) -> \(name)")
        }
    }

    @Test func lookupIgnoresVariationSelectorsAndSkinTones() {
        #expect(GlyphDrawing.symbolName(forEmoji: "☎\u{FE0F}") == "phone.fill")
        #expect(GlyphDrawing.symbolName(forEmoji: "🎙\u{FE0F}") == "mic.fill")
        #expect(GlyphDrawing.symbolName(forEmoji: "🗣\u{1F3FD}") == "person.wave.2.fill")
        #expect(GlyphDrawing.symbolName(forEmoji: "🍕") == nil)
    }

    @Test func monoHeaderDrawsMappedEmojiExactlyLikeTheSymbol() {
        let spec = KeyHeader.Spec.key
        let emoji = KeyHeader.render(KeyHeader.Input(glyph: .emoji("🌐"), monogram: "B", accent: Palette.accents[0], name: "Browser", spec: spec))
        let symbol = KeyHeader.render(KeyHeader.Input(glyph: .symbol("globe"), monogram: "B", accent: Palette.accents[0], name: "Browser", spec: spec))
        #expect(emoji != nil)
        #expect(emoji == symbol)
        #expect(KeyHeader.render(KeyHeader.Input(glyph: .emoji("🍕"), monogram: "P", accent: Palette.accents[0], name: "Pizza", spec: spec)) != nil)
    }
}

struct PaletteTests {

    @Test func accentIsDeterministic() {
        #expect(Palette.accent(forID: "mix-default") == Palette.accent(forID: "mix-default"))
    }

    @Test func accentIsAlwaysAPaletteColor() {
        for id in ["mix-default", "kasper", "game", "alpha", "zzz", ""] {
            #expect(Palette.accents.contains(Palette.accent(forID: id)))
        }
    }

    @Test func hexRoundsChannels() {
        #expect(Palette.mutedRed.hex == "#FF4D4D")
        #expect(RGB(0, 0, 0).hex == "#000000")
    }

    @Test func gradientStopsFollowSegmentBands() {
        let stops = Palette.segmentGradientStops
        #expect(stops.map(\.offset) == [0, 0.6, 0.6, 0.85, 0.85, 1])
        #expect(stops.map(\.color) == [Palette.segmentGreen, Palette.segmentGreen, Palette.segmentAmber,
                                       Palette.segmentAmber, Palette.mutedRed, Palette.mutedRed])
        #expect(Palette.segment(0) == Palette.segmentGreen)
        #expect(Palette.segment(0.7) == Palette.segmentAmber)
        #expect(Palette.segment(0.95) == Palette.mutedRed)
    }
}

@MainActor
struct KeyStyleImageTests {
    private let blue = Palette.accents[0]

    private func input(_ style: KeyStyleImage.KeyStyle, glyph: KeyImage.Glyph? = .symbol("speaker.wave.2.fill"),
                       monogram: String = "GA", name: String = "Game", pct: Int = 73,
                       level: Float = 0.6, muted: Bool = false) -> KeyStyleImage.Input {
        KeyStyleImage.Input(style: style, glyph: glyph, monogram: monogram, accent: blue, name: name,
                            pct: pct, level: level, leftLevel: 0.4, rightLevel: 0.8, muted: muted)
    }

    @Test(arguments: [KeyStyleImage.KeyStyle.channel, .meter, .retro])
    func everyStyleRendersPercentEncodedSVGWithRasterHeader(style: KeyStyleImage.KeyStyle) {
        let uri = KeyStyleImage.render(input(style))
        #expect(uri?.hasPrefix("data:image/svg+xml;charset=utf8,") == true)
        #expect(uri?.contains("#") == false)
        let svg = svgText(fromDataURI: uri)
        #expect(svg?.contains("<svg width=\"144\" height=\"144\"") == true)
        #expect(svg?.contains("data:image/png;base64,") == true)
        #expect(svg?.contains(Palette.tile.hex) == true)
    }

    @Test func emojiHeaderIsRasterizedNotInlineText() {
        let svg = svgText(fromDataURI: KeyStyleImage.render(input(.channel, glyph: .emoji("🌐"), name: "Browser")))
        #expect(svg?.contains("data:image/png;base64,") == true)
        #expect(svg?.contains("🌐") == false)
        #expect(svg?.contains("Browser") == false)
    }

    @Test func channelValueIsCachedRasterAtItsRect() {
        let svg = svgText(fromDataURI: KeyStyleImage.render(input(.channel, pct: 75)))
        let r = KeyStyleImage.volumeValueRect
        let expected = "x=\"\(KeyStyleImage.f(r.minX))\" y=\"\(KeyStyleImage.f(r.minY))\" width=\"\(KeyStyleImage.f(r.width))\" height=\"\(KeyStyleImage.f(r.height))\""
        #expect(svg?.contains(expected) == true)
    }

    @Test func rendersAreStableAcrossCalls() {
        #expect(KeyStyleImage.render(input(.channel, glyph: .symbol("bolt.fill"))) ==
                KeyStyleImage.render(input(.channel, glyph: .symbol("bolt.fill"))))
    }

    @Test func invalidSymbolFallsBackToAccentMonogramInHeader() {
        let header = KeyHeader.render(KeyHeader.Input(glyph: .symbol("not.a.real.symbol"), monogram: "NA",
                                                      accent: blue, name: "Bad", spec: .key))
        guard let rep = bitmap(fromDataURI: header) else {
            Issue.record("header should decode as PNG")
            return
        }
        #expect(countPixels(rep, near: blue) > 20)
    }

    @Test func retroEmbedsCachedGaugeBandWithLiveNeedle() {
        let low = svgText(fromDataURI: KeyStyleImage.render(input(.retro, level: 0.2)))
        let high = svgText(fromDataURI: KeyStyleImage.render(input(.retro, level: 0.9)))
        #expect(low?.contains("<line") == true)
        #expect(low?.contains("<circle") == true)
        #expect(low != high)
        let band = KeyStyleImage.cachedGaugeBand(pct: 73, accent: blue, muted: false)
        #expect(band != nil)
        #expect(low?.contains(band ?? "-") == true)
        #expect(high?.contains(band ?? "-") == true)
        let r = KeyStyleImage.retroGaugeBand
        #expect(low?.contains("y=\"\(KeyStyleImage.f(r.minY))\" width=\"\(KeyStyleImage.f(r.width))\"") == true)
    }

    @Test func gaugeBandIsRasterizedAtBandSize() {
        guard let rep = bitmap(fromDataURI: KeyStyleImage.cachedGaugeBand(pct: 50, accent: blue, muted: false)) else {
            Issue.record("gauge band should decode as PNG")
            return
        }
        #expect(rep.pixelsWide == Int(KeyStyleImage.retroGaugeBand.width))
        #expect(rep.pixelsHigh == Int(KeyStyleImage.retroGaugeBand.height))
        #expect(countPixels(rep, near: blue) > 4)
        #expect(countPixels(rep, near: Palette.mutedRed) > 4)
    }

    @Test(arguments: [KeyStyleImage.KeyStyle.channel, .meter, .retro])
    func mutedKeysGetRedBorderAndNoStrike(style: KeyStyleImage.KeyStyle) {
        let svg = svgText(fromDataURI: KeyStyleImage.render(input(style, muted: true)))
        #expect(svg?.contains("stroke=\"\(Palette.mutedRed.hex)\" stroke-width=\"\(KeyStyleImage.f(Palette.mutedBorderWidth))\"") == true)
        #expect(svg?.contains("<line x1=\"18") == false)
        if style != .meter {
            #expect(svg?.contains("opacity=\"\(KeyStyleImage.f(Palette.mutedValueOpacity))\"") == true)
        }
    }

    @Test func rendersAtRailValues() {
        for pct in [0, 100] {
            for level in [Float(0), 1] {
                #expect(KeyStyleImage.render(input(.meter, pct: pct, level: level)) != nil)
            }
        }
    }

    @Test func retroLCDCanvasContainsGaugeAndRedZone() {
        let uri = RetroMeterDrawing.renderLCDStatic(RetroMeterDrawing.LCDInput(
            style: .retro, glyph: .symbol("speaker.wave.2.fill"), monogram: "ST",
            accent: Palette.accents[2], name: "Stream", pct: 100, muted: false))
        guard let rep = bitmap(fromDataURI: uri) else {
            Issue.record("Retro LCD render should decode as PNG")
            return
        }
        #expect(rep.pixelsWide == 200)
        #expect(rep.pixelsHigh == 100)

        var gaugePixels = 0
        for x in 20..<180 {
            for y in 40..<96 {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.redComponent > 0.1 || color.greenComponent > 0.1 || color.blueComponent > 0.1 { gaugePixels += 1 }
            }
        }
        #expect(gaugePixels > 250)
        #expect(countPixels(rep, near: Palette.mutedRed) > 3)
    }

    @Test func retroLCDNeedleLayerOmitsPeakAtZero() {
        let withPeak = svgText(fromDataURI: RetroMeterDrawing.renderRetroLCDNeedleSVG(step: 56, peakStep: 70, muted: false))
        let noPeak = svgText(fromDataURI: RetroMeterDrawing.renderRetroLCDNeedleSVG(step: 56, peakStep: 0, muted: false))
        #expect(withPeak?.components(separatedBy: "<line").count == 3)
        #expect(noPeak?.components(separatedBy: "<line").count == 2)
        #expect(noPeak?.contains("stroke=\"\(Palette.needle.hex)\"") == true)
        let layer = RetroMeterDrawing.lcdNeedleLayer
        #expect(noPeak?.contains("<svg width=\"\(Int(layer.width))\" height=\"\(Int(layer.height))\"") == true)
    }

    @Test func liveLCDBarLayersUsePaletteAndCache() {
        let uri = RetroMeterDrawing.renderLCDLevelBarSVG(width: 184, height: 16, step: 75, peakStep: 92, muted: false)
        #expect(RetroMeterDrawing.renderLCDLevelBarSVG(width: 184, height: 16, step: 75, peakStep: 92, muted: false) == uri)
        #expect(uri.hasPrefix("data:image/svg+xml;charset=utf8,"))
        let svg = svgText(fromDataURI: uri)
        #expect(svg?.contains("linearGradient") == true)
        #expect(svg?.contains(Palette.rail.hex) == true)
        #expect(svg?.contains(Palette.text.hex) == true)
        #expect(svg?.contains(Palette.segmentGreen.hex) == true)
        #expect(svg?.contains("clipPath") == false)
        let silent = svgText(fromDataURI: RetroMeterDrawing.renderLCDLevelBarSVG(width: 184, height: 16, step: 0, peakStep: 0, muted: false))
        #expect(silent?.contains(Palette.text.hex) == false)
    }

    @Test func keyImageRendersGlyphWithOptionalSlash() {
        let plain = KeyImage.render(.symbol("hifispeaker.fill"), muted: false)
        let muted = KeyImage.render(.symbol("hifispeaker.fill"), muted: true)
        #expect(plain?.hasPrefix("data:image/png;base64,") == true)
        #expect(muted != plain)
        #expect(KeyImage.render(.emoji("  "), muted: false) == nil)
        #expect(KeyImage.render(.symbol("not.a.real.symbol"), muted: false) == nil)
        if let rep = bitmap(fromDataURI: muted) { #expect(countPixels(rep, near: Palette.mutedRed) > 100) }
    }

    @Test func visualStyleNormalizerKeepsCurrentAndLegacyValuesWorking() {
        #expect(ActionRouter.normalizedVisualStyle("channel") == .channel)
        #expect(ActionRouter.normalizedVisualStyle("meter") == .meter)
        #expect(ActionRouter.normalizedVisualStyle("retro") == .retro)
        #expect(ActionRouter.normalizedVisualStyle("bars") == .meter)
        #expect(ActionRouter.normalizedVisualStyle("radial") == .retro)
        #expect(ActionRouter.normalizedVisualStyle("unknown") == .channel)
        #expect(ActionRouter.normalizedVisualStyle(nil) == .channel)
    }

    @Test func keyLevelSignatureQuantizesEveryKeyStyle() {
        #expect(ActionRouter.keyLevelSignature(style: .channel, level: 0.499, muted: false) ==
                ActionRouter.keyLevelSignature(style: .channel, level: 0.501, muted: false))
        #expect(ActionRouter.keyLevelSignature(style: .meter, level: 0.499, muted: false) ==
                ActionRouter.keyLevelSignature(style: .meter, level: 0.501, muted: false))
        #expect(ActionRouter.keyLevelSignature(style: .retro, level: 0.499, muted: false) ==
                ActionRouter.keyLevelSignature(style: .retro, level: 0.51, muted: false))
        #expect(ActionRouter.keyLevelSignature(style: .retro, level: 0, muted: false) == 0)
        #expect(ActionRouter.keyLevelSignature(style: .retro, level: 1, muted: false) == 24)

        #expect(ActionRouter.keyLevelSignature(style: .channel, level: 0.499, muted: false) !=
                ActionRouter.keyLevelSignature(style: .channel, level: 0.61, muted: false))
        #expect(ActionRouter.keyLevelSignature(style: .meter, level: 0.499, muted: false) !=
                ActionRouter.keyLevelSignature(style: .meter, level: 0.57, muted: false))
        #expect(ActionRouter.keyLevelSignature(style: .retro, level: 0.499, muted: false) !=
                ActionRouter.keyLevelSignature(style: .retro, level: 0.56, muted: false))
        #expect(ActionRouter.keyLevelSignature(style: .meter, level: 1, muted: true) == 0)
    }

    @Test func peakWindowTracksMaximumOnlyAcrossRecentSamples() {
        var window = ActionRouter.RollingPeakWindow(seconds: 5, floor: -60)

        #expect(window.peak == ActionRouter.StereoPeak(left: -60, right: -60))
        #expect(window.append(left: -30, right: -28, at: 0) == ActionRouter.StereoPeak(left: -30, right: -28))
        #expect(window.append(left: -12, right: -40, at: 1) == ActionRouter.StereoPeak(left: -12, right: -28))
        #expect(window.append(left: -35, right: -10, at: 5.9) == ActionRouter.StereoPeak(left: -12, right: -10))
        #expect(window.append(left: -45, right: -42, at: 6.1) == ActionRouter.StereoPeak(left: -35, right: -10))
        #expect(window.append(left: -50, right: -45, at: 11.2) == ActionRouter.StereoPeak(left: -50, right: -45))
        #expect(window.peak == ActionRouter.StereoPeak(left: -50, right: -45))
    }

    private func countPixels(_ rep: NSBitmapImageRep, near color: RGB, tolerance: CGFloat = 0.12) -> Int {
        guard let target = color.nsColor.usingColorSpace(.deviceRGB) else { return 0 }
        let color = RGB(target.redComponent, target.greenComponent, target.blueComponent)
        var count = 0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), c.alphaComponent > 0.5 else { continue }
                if abs(c.redComponent - color.red) < tolerance,
                   abs(c.greenComponent - color.green) < tolerance,
                   abs(c.blueComponent - color.blue) < tolerance { count += 1 }
            }
        }
        return count
    }

    private func bitmap(fromDataURI uri: String?) -> NSBitmapImageRep? {
        guard let uri, let comma = uri.firstIndex(of: ",") else { return nil }
        let payload = String(uri[uri.index(after: comma)...])
        guard let data = Data(base64Encoded: payload) else { return nil }
        return NSBitmapImageRep(data: data)
    }

    private func svgText(fromDataURI uri: String?) -> String? {
        guard let uri, let comma = uri.firstIndex(of: ",") else { return nil }
        return String(uri[uri.index(after: comma)...]).removingPercentEncoding
    }
}
