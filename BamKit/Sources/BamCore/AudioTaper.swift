import Foundation

/// Maps perceptual position 0…1 ↔ linear gain 0…1.
/// A cube taper (exp = 3.0) makes equal fader travel feel like equal loudness.
/// `gain` is what the engine multiplies; `position` is 0…1 fader travel.
public enum AudioTaper {
    public static let exp = 3.0
    public static func position(fromGain g: Double) -> Double { pow(min(1, max(0, g)), 1 / exp) }
    public static func gain(fromPosition p: Double) -> Double { pow(min(1, max(0, p)), exp) }
    public static func percent(fromGain g: Double) -> Int { Int((position(fromGain: g) * 100).rounded()) }
}
