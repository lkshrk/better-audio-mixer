import Accelerate

enum DSPKernels {
    @inline(__always)
    static func sumScaledScalar(src: UnsafePointer<Float>, stride: Int, gain: Float,
                                dst: UnsafeMutablePointer<Float>, dstStride: Int, frames: Int) {
        var i = 0
        while i < frames {
            dst[i * dstStride] += src[i * stride] * gain
            i += 1
        }
    }

    @inline(__always)
    static func sumScaledVDSP(src: UnsafePointer<Float>, stride: Int, gain: Float,
                              dst: UnsafeMutablePointer<Float>, dstStride: Int, frames: Int) {
        var g = gain
        // dst = src*g + dst  (multiply-add into destination)
        vDSP_vsma(src, vDSP_Stride(stride), &g, dst, vDSP_Stride(dstStride),
                  dst, vDSP_Stride(dstStride), vDSP_Length(frames))
    }

    @inline(__always)
    static func sumOfSquaresScalar(src: UnsafePointer<Float>, stride: Int, frames: Int) -> Float {
        var acc: Float = 0
        var i = 0
        while i < frames { let s = src[i * stride]; acc += s * s; i += 1 }
        return acc
    }

    @inline(__always)
    static func sumOfSquaresVDSP(src: UnsafePointer<Float>, stride: Int, frames: Int) -> Float {
        var acc: Float = 0
        vDSP_svesq(src, vDSP_Stride(stride), &acc, vDSP_Length(frames))
        return acc
    }

    @inline(__always)
    static func peakMagnitudeScalar(_ buf: UnsafePointer<Float>, count: Int) -> Float {
        var peak: Float = 0
        var i = 0
        while i < count { let a = abs(buf[i]); if a > peak { peak = a }; i += 1 }
        return peak
    }

    @inline(__always)
    static func peakMagnitudeVDSP(_ buf: UnsafePointer<Float>, count: Int) -> Float {
        var peak: Float = 0
        vDSP_maxmgv(buf, 1, &peak, vDSP_Length(count))
        return peak
    }
}
