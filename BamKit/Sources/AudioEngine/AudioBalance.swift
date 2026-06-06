/// Stereo balance law for already-stereo program material.
///
/// Center is unity for both channels; moving away from center attenuates the
/// opposite side. This is intentionally not an equal-power mono pan law: applying
/// equal-power pan to stereo app audio makes centered playback about 3 dB quieter.
enum AudioBalance {
    static func gains(pan: Float) -> (left: Float, right: Float) {
        let p = min(max(pan, 0), 1)
        if p < 0.5 {
            return (1, p * 2)
        }
        return ((1 - p) * 2, 1)
    }
}
