/// Interleave planar channel buffers into a frame-major destination.
///
/// `planes[c]` is channel c's contiguous run of `frames` samples; the result is
/// written as `dst[f * channels + c]`. Only the first `channels` planes are
/// consumed (extras ignored); a nil plane is skipped, leaving its interleaved
/// slots untouched — callers that need silence there must pre-zero `dst`.
///
/// Extracted from the realtime tap-capture path in `TapChain` so the index math
/// is unit-testable off the audio thread.
@inline(__always)
func interleavePlanar(
    _ planes: [UnsafePointer<Float>?],
    frames: Int,
    channels: Int,
    into dst: UnsafeMutablePointer<Float>
) {
    guard channels > 0, frames > 0 else { return }
    for c in 0..<min(channels, planes.count) {
        guard let src = planes[c] else { continue }
        for f in 0..<frames { dst[f * channels + c] = src[f] }
    }
}
