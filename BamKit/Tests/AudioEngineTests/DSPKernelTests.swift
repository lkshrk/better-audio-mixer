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

    // Verify scalar==vDSP when reading a non-unit source stride (interleaved layout) and
    // writing a non-unit dst stride — the IOProc uses exactly this access pattern.
    func testSumScaledNonUnitStride() {
        let frames = 256
        // Build interleaved stereo: [L0, R0, L1, R1, ...] using the same LCG helper.
        let interleaved = randomBuffer(frames * 2, seed: 7)
        let gain: Float = 0.72
        // dstA/dstB mirror an interleaved output; pre-fill a non-zero value to prove
        // accumulation (not overwrite) and that the untouched R lane is unchanged.
        var dstA = [Float](repeating: 0.25, count: frames * 2)
        var dstB = dstA

        interleaved.withUnsafeBufferPointer { sp in
            let srcBase = sp.baseAddress!
            dstA.withUnsafeMutableBufferPointer { ap in
                // read L lane (stride 2), write L lane (dstStride 2)
                DSPKernels.sumScaledScalar(src: srcBase, stride: 2, gain: gain,
                                           dst: ap.baseAddress!, dstStride: 2, frames: frames)
            }
            dstB.withUnsafeMutableBufferPointer { bp in
                DSPKernels.sumScaledVDSP(src: srcBase, stride: 2, gain: gain,
                                         dst: bp.baseAddress!, dstStride: 2, frames: frames)
            }
        }

        for i in 0..<frames {
            // L lane: scalar and vDSP must agree within float tolerance
            XCTAssertLessThan(abs(dstA[i * 2] - dstB[i * 2]), 1e-6, "L lane mismatch at frame \(i)")
            // R lane (odd indices): must be untouched — still 0.25
            XCTAssertEqual(dstA[i * 2 + 1], 0.25, "R lane modified by scalar at frame \(i)")
            XCTAssertEqual(dstB[i * 2 + 1], 0.25, "R lane modified by vDSP at frame \(i)")
        }
    }

    func testSumOfSquaresNonUnitStride() {
        let frames = 256
        let interleaved = randomBuffer(frames * 2, seed: 8)
        let (ss, vv): (Float, Float) = interleaved.withUnsafeBufferPointer { sp in
            (DSPKernels.sumOfSquaresScalar(src: sp.baseAddress!, stride: 2, frames: frames),
             DSPKernels.sumOfSquaresVDSP(src: sp.baseAddress!, stride: 2, frames: frames))
        }
        XCTAssertLessThan(abs(ss - vv) / max(1, ss), 1e-6)
    }
}
