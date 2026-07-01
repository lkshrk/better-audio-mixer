import XCTest
@testable import AudioEngine

final class DSPKernelTests: XCTestCase {
    private func randomBuffer(_ n: Int, seed: UInt64) -> [Float] {
        var s = seed
        return (0..<n).map { _ in
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int32(truncatingIfNeeded: s >> 32)) / Float(Int32.max)
        }
    }

    func testSumScaledMatches() {
        let frames = 512
        let src = randomBuffer(frames, seed: 1)
        let gain: Float = 0.37
        var a = [Float](repeating: 0.1, count: frames)
        var b = a
        src.withUnsafeBufferPointer { sp in
            a.withUnsafeMutableBufferPointer { ap in
                DSPKernels.sumScaledScalar(src: sp.baseAddress!, stride: 1, gain: gain,
                                           dst: ap.baseAddress!, dstStride: 1, frames: frames)
            }
            b.withUnsafeMutableBufferPointer { bp in
                DSPKernels.sumScaledVDSP(src: sp.baseAddress!, stride: 1, gain: gain,
                                         dst: bp.baseAddress!, dstStride: 1, frames: frames)
            }
        }
        for i in 0..<frames { XCTAssertLessThan(abs(a[i] - b[i]), 1e-6, "idx \(i)") }
    }

    func testSumOfSquaresMatches() {
        let src = randomBuffer(777, seed: 2)
        let (ss, vv): (Float, Float) = src.withUnsafeBufferPointer { sp in
            (DSPKernels.sumOfSquaresScalar(src: sp.baseAddress!, stride: 1, frames: sp.count),
             DSPKernels.sumOfSquaresVDSP(src: sp.baseAddress!, stride: 1, frames: sp.count))
        }
        XCTAssertLessThan(abs(ss - vv) / max(1, ss), 1e-6)
    }

    func testPeakMatches() {
        let src = randomBuffer(1024, seed: 3)
        let (ps, pv): (Float, Float) = src.withUnsafeBufferPointer { sp in
            (DSPKernels.peakMagnitudeScalar(sp.baseAddress!, count: sp.count),
             DSPKernels.peakMagnitudeVDSP(sp.baseAddress!, count: sp.count))
        }
        XCTAssertEqual(ps, pv, accuracy: 1e-6)
    }

    func testNoNaN() {
        let src = [Float](repeating: 0, count: 64)
        let ss = src.withUnsafeBufferPointer {
            DSPKernels.sumOfSquaresVDSP(src: $0.baseAddress!, stride: 1, frames: $0.count)
        }
        XCTAssertFalse(ss.isNaN)
    }
}
