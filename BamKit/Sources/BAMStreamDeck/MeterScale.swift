import Foundation

/// The one place a level fraction becomes a discrete step, shared by signatures and renderers.
enum MeterScale {
    static let keyNeedleSteps = 24
    static let lcdNeedleSteps = 90
    static let lcdBarSteps = 100

    static func segmentCount(for style: KeyStyleImage.KeyStyle) -> Int {
        switch style {
        case .channel: return 12
        case .meter:   return 18
        case .retro:   return keyNeedleSteps
        }
    }

    static func quantize(_ level: Float, steps: Int, muted: Bool) -> Int {
        guard !muted else { return 0 }
        let clamped = max(0, min(1, level))
        return Int((clamped * Float(steps)).rounded())
    }

    static func fraction(step: Int, steps: Int) -> CGFloat {
        CGFloat(max(0, min(steps, step))) / CGFloat(steps)
    }
}
