import BamCore
import Foundation

/// Peak-hold indicator: holds the highest level for `holdSeconds`, then falls at `decayDBPerSecond`.
struct PeakHold: Equatable {
    static let holdSeconds: TimeInterval = 1.0
    static let decayDBPerSecond: Float = 12

    private(set) var peak: Float = RMSMeter.floorDB
    private var held: Float = RMSMeter.floorDB
    private var risenAt: TimeInterval = -.infinity

    mutating func update(_ level: Float, at now: TimeInterval) {
        let elapsed = Float(max(0, now - risenAt - Self.holdSeconds))
        let current = max(held - Self.decayDBPerSecond * elapsed, RMSMeter.floorDB)
        let level = max(level, RMSMeter.floorDB)
        if level >= current {
            held = level
            risenAt = now
            peak = level
        } else {
            peak = current
        }
    }
}

struct StereoPeak: Equatable {
    var left = PeakHold()
    var right = PeakHold()

    mutating func update(left l: Float, right r: Float, at now: TimeInterval) {
        left.update(l, at: now)
        right.update(r, at: now)
    }
}

enum Readout {
    /// `−12.4 dB` from linear gain; `−∞ dB` at zero.
    static func dbLabel(gain: Double) -> String {
        guard gain > 0 else { return "−∞ dB" }
        var s = String(format: "%.1f", 20 * log10(gain))
        if s == "-0.0" { s = "0.0" }
        return s.replacingOccurrences(of: "-", with: "−") + " dB"
    }
}
