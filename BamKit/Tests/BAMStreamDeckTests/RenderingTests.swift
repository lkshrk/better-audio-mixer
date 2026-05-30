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

    @Test(arguments: [KeyStyleImage.KeyStyle.meter, .bars, .radial])
    func rendersPNGForEveryStyle(style: KeyStyleImage.KeyStyle) {
        let uri = KeyStyleImage.render(style: style, monogram: "GA", accent: .systemBlue,
                                       name: "Game", pct: 73, level: 0.6, muted: false)
        #expect(uri?.hasPrefix("data:image/png;base64,") == true)
    }

    @Test(arguments: [KeyStyleImage.KeyStyle.meter, .bars, .radial])
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
}
