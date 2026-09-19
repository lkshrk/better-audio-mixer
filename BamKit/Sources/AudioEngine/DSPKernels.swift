import Accelerate

enum DSPKernels {
    /// Writes `src * gain` into `dst`, adding when `accumulate`; per-sample only while a ramp is in flight.
    @inline(__always)
    static func mixRamped(src: UnsafePointer<Float>, stride: Int, ramp: inout GainRamp, scale: Float = 1,
                          dst: UnsafeMutablePointer<Float>, dstStride: Int, frames: Int, accumulate: Bool) {
        guard frames > 0 else { return }
        if !ramp.isRamping {
            if accumulate {
                sumScaledVDSP(src: src, stride: stride, gain: ramp.current * scale,
                              dst: dst, dstStride: dstStride, frames: frames)
            } else {
                scaledVDSP(src: src, stride: stride, gain: ramp.current * scale,
                           dst: dst, dstStride: dstStride, frames: frames)
            }
            return
        }
        var i = 0
        if accumulate {
            while i < frames {
                dst[i * dstStride] += src[i * stride] * ramp.next() * scale
                i += 1
            }
        } else {
            while i < frames {
                dst[i * dstStride] = src[i * stride] * ramp.next() * scale
                i += 1
            }
        }
    }

    @inline(__always)
    static func sumScaledVDSP(src: UnsafePointer<Float>, stride: Int, gain: Float,
                              dst: UnsafeMutablePointer<Float>, dstStride: Int, frames: Int) {
        var g = gain
        vDSP_vsma(src, vDSP_Stride(stride), &g, dst, vDSP_Stride(dstStride),
                  dst, vDSP_Stride(dstStride), vDSP_Length(frames))
    }

    @inline(__always)
    static func scaledVDSP(src: UnsafePointer<Float>, stride: Int, gain: Float,
                           dst: UnsafeMutablePointer<Float>, dstStride: Int, frames: Int) {
        var g = gain
        vDSP_vsmul(src, vDSP_Stride(stride), &g, dst, vDSP_Stride(dstStride), vDSP_Length(frames))
    }

    @inline(__always)
    static func clearVDSP(_ dst: UnsafeMutablePointer<Float>, stride: Int, frames: Int) {
        guard frames > 0 else { return }
        vDSP_vclr(dst, vDSP_Stride(stride), vDSP_Length(frames))
    }

    @inline(__always)
    static func sumOfSquaresVDSP(src: UnsafePointer<Float>, stride: Int, frames: Int) -> Float {
        var acc: Float = 0
        vDSP_svesq(src, vDSP_Stride(stride), &acc, vDSP_Length(frames))
        return acc
    }

    @inline(__always)
    static func peakMagnitudeVDSP(_ buf: UnsafePointer<Float>, count: Int) -> Float {
        var peak: Float = 0
        vDSP_maxmgv(buf, 1, &peak, vDSP_Length(count))
        return peak
    }
}
