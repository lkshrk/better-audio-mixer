import AppKit
import Testing
@testable import BAMStreamDeck

@MainActor
struct LevelMappingTests {

    @Test func levelPercentClampsAtFloorAndCeiling() {
        #expect(ActionRouter.levelPercent(-60) == 0)   // floor
        #expect(ActionRouter.levelPercent(-90) == 0)   // below floor
        #expect(ActionRouter.levelPercent(0) == 100)   // full scale
        #expect(ActionRouter.levelPercent(5) == 100)   // above full scale clamps
    }

    @Test func levelPercentMapsMidpoint() {
        #expect(ActionRouter.levelPercent(-30) == 50)  // halfway across the -60…0 range
    }

    @Test func levelFractionMatchesPercent() {
        #expect(ActionRouter.levelFraction(-60) == 0)
        #expect(ActionRouter.levelFraction(0) == 1)
        #expect(abs(ActionRouter.levelFraction(-30) - 0.5) < 0.0001)
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
struct AccentTests {

    @Test func accentIsDeterministic() {
        #expect(ActionRouter.accent(forID: "mix-default") == ActionRouter.accent(forID: "mix-default"))
    }

    @Test func accentIsAlwaysAPaletteColor() {
        for id in ["mix-default", "kasper", "game", "alpha", "zzz", ""] {
            #expect(ActionRouter.accentPalette.contains(ActionRouter.accent(forID: id)))
        }
    }
}

@MainActor
struct KeyStyleImageTests {

    @Test(arguments: [KeyStyleImage.KeyStyle.channel, .meter, .retro])
    func rendersPNGForEveryStyle(style: KeyStyleImage.KeyStyle) {
        let uri = KeyStyleImage.render(style: style, monogram: "GA", accent: .systemBlue,
                                       name: "Game", pct: 73, level: 0.6, muted: false)
        #expect(uri?.hasPrefix("data:image/png;base64,") == true)
    }

    @Test(arguments: [KeyStyleImage.KeyStyle.channel, .meter, .retro])
    func rendersMutedVariant(style: KeyStyleImage.KeyStyle) {
        let uri = KeyStyleImage.render(style: style, monogram: "M", accent: .systemPurple,
                                       name: "Master", pct: 40, level: 0, muted: true)
        #expect(uri?.hasPrefix("data:image/png;base64,") == true)
    }

    @Test func rendersAtRailValues() {
        for pct in [0, 100] {
            for level in [Float(0), 1] {
                let uri = KeyStyleImage.render(style: .meter, monogram: "DE", accent: .systemRed,
                                               name: "Default", pct: pct, level: level, muted: false)
                #expect(uri != nil)
            }
        }
    }

    @Test func rendersRetroLCDCanvas() {
        let uri = RetroMeterDrawing.renderLCD(name: "Game", monogram: "GA", accent: .systemBlue,
                                              pct: 73, level: 0.6, muted: false)
        #expect(uri?.hasPrefix("data:image/png;base64,") == true)
    }

    @Test func retroLCDCanvasContainsDialDetail() {
        let uri = RetroMeterDrawing.renderLCD(name: "Stream", monogram: "ST", accent: .systemOrange,
                                              pct: 100, level: 0.62, muted: false)
        guard let rep = bitmap(fromDataURI: uri) else {
            #expect(Bool(false), "Retro LCD render should decode as PNG")
            return
        }

        #expect(rep.pixelsWide == 200)
        #expect(rep.pixelsHigh == 100)

        var dialPixels = 0
        var redZonePixels = 0
        for x in 20..<180 {
            for y in 40..<96 {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let isBackground = color.redComponent < 0.08
                    && color.greenComponent < 0.08
                    && color.blueComponent < 0.08
                if !isBackground { dialPixels += 1 }
                if color.redComponent > 0.65
                    && color.greenComponent < 0.35
                    && color.blueComponent < 0.35 {
                    redZonePixels += 1
                }
            }
        }

        #expect(dialPixels > 900)
        #expect(redZonePixels > 3)
    }

    @Test func retroLCDSplitLayersRenderExpectedSizes() {
        let staticURI = RetroMeterDrawing.renderRetroLCDStatic(name: "Stream", monogram: "ST",
                                                               accent: .systemOrange,
                                                               pct: 82, muted: false)
        let needleStep = RetroMeterDrawing.retroLCDLevelNeedleStep(level: 0.62, muted: false)
        let needleURI = RetroMeterDrawing.renderRetroLCDLevelNeedleSVG(step: needleStep, muted: false)

        guard let staticRep = bitmap(fromDataURI: staticURI) else {
            #expect(Bool(false), "Retro LCD layers should decode as PNG")
            return
        }

        #expect(staticRep.pixelsWide == 200)
        #expect(staticRep.pixelsHigh == 100)
        #expect(needleURI.hasPrefix("data:image/svg+xml;base64,"))
        #expect(needleStep == 56)
    }

    @Test func retroLCDLevelNeedleQuantizesSmallMotion() {
        let a = RetroMeterDrawing.retroLCDLevelNeedleStep(level: 0.620, muted: false)
        let b = RetroMeterDrawing.retroLCDLevelNeedleStep(level: 0.624, muted: false)
        let c = RetroMeterDrawing.retroLCDLevelNeedleStep(level: 0.640, muted: false)

        #expect(a == b)
        #expect(c > a)
        #expect(RetroMeterDrawing.retroLCDLevelNeedleStep(level: 1.5, muted: false) == 90)
        #expect(RetroMeterDrawing.retroLCDLevelNeedleStep(level: 0.8, muted: true) == 0)
    }

    @Test func liveLCDBarLayersUseStaticCanvasAndSVGOverlay() {
        let staticURI = RetroMeterDrawing.renderLCDStatic(style: .channel, name: "Voice",
                                                          monogram: "VO", accent: .systemCyan,
                                                          pct: 75, muted: false)
        let step = RetroMeterDrawing.lcdLevelBarStep(level: 0.754, muted: false)
        let barURI = RetroMeterDrawing.renderLCDLevelBarSVG(width: 128, height: 17,
                                                            step: step, peakStep: 92, muted: false)
        let cachedBarURI = RetroMeterDrawing.renderLCDLevelBarSVG(width: 128, height: 17,
                                                                  step: step, peakStep: 92, muted: false)

        guard let staticRep = bitmap(fromDataURI: staticURI) else {
            #expect(Bool(false), "Channel static LCD layer should decode as PNG")
            return
        }

        #expect(staticRep.pixelsWide == 200)
        #expect(staticRep.pixelsHigh == 100)
        #expect(step == 75)
        #expect(cachedBarURI == barURI)
        #expect(barURI.hasPrefix("data:image/svg+xml;base64,"))
        let svg = svgText(fromDataURI: barURI)
        #expect(svg?.contains("linearGradient") == true)
        #expect(svg?.contains("#292929") == true)
        #expect(svg?.contains("#FF3636") == true)
        #expect(svg?.contains("#050505") == true)
        #expect(svg?.contains("clipPath") == false)
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

    @Test func keyLevelSignatureQuantizesOnlySegmentedKeyStyles() {
        #expect(ActionRouter.keyLevelSignature(style: .channel, level: 0.499, muted: false) ==
                ActionRouter.keyLevelSignature(style: .channel, level: 0.501, muted: false))
        #expect(ActionRouter.keyLevelSignature(style: .meter, level: 0.499, muted: false) ==
                ActionRouter.keyLevelSignature(style: .meter, level: 0.501, muted: false))
        #expect(ActionRouter.keyLevelSignature(style: .retro, level: 0, muted: false) == 0)
        #expect(ActionRouter.keyLevelSignature(style: .retro, level: 1, muted: false) == 100)

        #expect(ActionRouter.keyLevelSignature(style: .channel, level: 0.499, muted: false) !=
                ActionRouter.keyLevelSignature(style: .channel, level: 0.61, muted: false))
        #expect(ActionRouter.keyLevelSignature(style: .meter, level: 0.499, muted: false) !=
                ActionRouter.keyLevelSignature(style: .meter, level: 0.57, muted: false))
        #expect(ActionRouter.keyLevelSignature(style: .retro, level: 0.499, muted: false) !=
                ActionRouter.keyLevelSignature(style: .retro, level: 0.52, muted: false))
        #expect(ActionRouter.keyLevelSignature(style: .meter, level: 1, muted: true) == 0)
    }

    @Test func peakWindowTracksMaximumOnlyAcrossRecentSamples() {
        var window = ActionRouter.RollingPeakWindow(seconds: 5, floor: -60)

        #expect(window.append(left: -30, right: -28, at: 0) == ActionRouter.StereoPeak(left: -30, right: -28))
        #expect(window.append(left: -12, right: -40, at: 1) == ActionRouter.StereoPeak(left: -12, right: -28))
        #expect(window.append(left: -35, right: -10, at: 5.9) == ActionRouter.StereoPeak(left: -12, right: -10))
        #expect(window.append(left: -45, right: -42, at: 6.1) == ActionRouter.StereoPeak(left: -35, right: -10))
        #expect(window.append(left: -50, right: -45, at: 11.2) == ActionRouter.StereoPeak(left: -50, right: -45))
    }

    private func bitmap(fromDataURI uri: String?) -> NSBitmapImageRep? {
        guard let uri, let comma = uri.firstIndex(of: ",") else { return nil }
        let payload = String(uri[uri.index(after: comma)...])
        guard let data = Data(base64Encoded: payload) else { return nil }
        return NSBitmapImageRep(data: data)
    }

    private func svgText(fromDataURI uri: String?) -> String? {
        guard let uri, let comma = uri.firstIndex(of: ",") else { return nil }
        let payload = String(uri[uri.index(after: comma)...])
        guard let data = Data(base64Encoded: payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
