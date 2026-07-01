import Foundation

struct LimiterConfig {
    var attackMs: Float = 1
    var releaseMs: Float = 100
    var lookaheadMs: Float = 1.5
    var ceiling: Float = 1.0
}

enum AudioLimiter {
    /// Returns a full-buffer scalar that prevents clipping while preserving the
    /// waveform shape. Values at or below full scale pass through unchanged.
    static func scale(forPeak peak: Float) -> Float {
        guard peak.isFinite, peak > 1 else { return 1 }
        return 1 / peak
    }

    /// Applies overload immediately, then releases back toward unity gradually.
    /// This avoids buffer-to-buffer gain wobble on sustained low-frequency peaks.
    static func nextScale(current: Float, target: Float, release: Float = 0.01) -> Float {
        let safeCurrent = current.isFinite ? min(max(current, 0), 1) : 1
        let safeTarget = target.isFinite ? min(max(target, 0), 1) : 1
        if safeTarget < safeCurrent { return safeTarget }
        return safeCurrent + (safeTarget - safeCurrent) * min(max(release, 0), 1)
    }
}

extension AudioLimiter {
    static func lookaheadFrames(sampleRate: Double, lookaheadMs: Float) -> Int {
        max(1, Int((Double(lookaheadMs) / 1000.0 * sampleRate).rounded()))
    }

    static func attackCoeff(sampleRate: Double, ms: Float) -> Float {
        coeff(sampleRate: sampleRate, ms: ms)
    }

    static func releaseCoeff(sampleRate: Double, ms: Float) -> Float {
        coeff(sampleRate: sampleRate, ms: ms)
    }

    private static func coeff(sampleRate: Double, ms: Float) -> Float {
        guard ms > 0, sampleRate > 0 else { return 1 }
        // one-pole time constant: e^(-1 / (tau * fs))
        let tau = Double(ms) / 1000.0
        return Float(exp(-1.0 / (tau * sampleRate)))
    }

    static func targetGain(forPeak peak: Float, ceiling: Float) -> Float {
        guard peak.isFinite, peak > ceiling, peak > 0 else { return 1 }
        return ceiling / peak
    }

    /// One-pole envelope toward `targetGain`. Attack (target below current) uses the
    /// attack coefficient; release (target above) uses the release coefficient.
    static func nextEnvelope(current: Float, targetGain: Float,
                             attackCoeff: Float, releaseCoeff: Float) -> Float {
        let c = current.isFinite ? min(max(current, 0), 1) : 1
        let t = targetGain.isFinite ? min(max(targetGain, 0), 1) : 1
        let k = t < c ? attackCoeff : releaseCoeff
        let next = t + (c - t) * k
        return min(max(next, 0), 1)
    }
}
