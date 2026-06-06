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
