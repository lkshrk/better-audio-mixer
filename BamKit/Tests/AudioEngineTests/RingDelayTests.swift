import XCTest
@testable import AudioEngine

final class RingDelayTests: XCTestCase {

    private func lcgBuffer(_ n: Int, seed: UInt64) -> [Float] {
        var s = seed
        return (0..<n).map { _ in
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int32(truncatingIfNeeded: s >> 32)) / Float(Int32.max)
        }
    }

    private func referenceDelay(_ input: [Float], depth: Int) -> [Float] {
        var out = [Float](repeating: 0, count: input.count)
        var i = 0
        while i < input.count {
            out[i] = i >= depth ? input[i - depth] : 0
            i += 1
        }
        return out
    }

    func testGoldenDelaySmall() {
        let depth = 3
        let frames = 5
        let input = lcgBuffer(frames * 2, seed: 42)
        let ref = referenceDelay(input, depth: depth)

        var ring = [Float](repeating: 0, count: depth)
        var writeIndex = 0
        var got = [Float](repeating: 0, count: frames * 2)

        for call in 0..<2 {
            let offset = call * frames
            var buf = Array(input[offset..<(offset + frames)])
            buf.withUnsafeMutableBufferPointer { bp in
                ring.withUnsafeMutableBufferPointer { rp in
                    DSPKernels.ringDelaySwap(io: bp.baseAddress!, ioStride: 1,
                                             ring: rp.baseAddress!, ringBase: 0,
                                             writeIndex: writeIndex, depth: depth, frames: frames)
                }
            }
            for i in 0..<frames { got[offset + i] = buf[i] }
            writeIndex = (writeIndex + frames) % depth
        }

        for i in 0..<(frames * 2) {
            XCTAssertEqual(got[i], ref[i], accuracy: 1e-6, "sample \(i)")
        }
    }

    func testGoldenDelayRealistic() {
        let depth = 72
        let frames = 512
        let input = lcgBuffer(frames * 2, seed: 99)
        let ref = referenceDelay(input, depth: depth)

        var ring = [Float](repeating: 0, count: depth)
        var writeIndex = 0
        var got = [Float](repeating: 0, count: frames * 2)

        for call in 0..<2 {
            let offset = call * frames
            var buf = Array(input[offset..<(offset + frames)])
            buf.withUnsafeMutableBufferPointer { bp in
                ring.withUnsafeMutableBufferPointer { rp in
                    DSPKernels.ringDelaySwap(io: bp.baseAddress!, ioStride: 1,
                                             ring: rp.baseAddress!, ringBase: 0,
                                             writeIndex: writeIndex, depth: depth, frames: frames)
                }
            }
            for i in 0..<frames { got[offset + i] = buf[i] }
            writeIndex = (writeIndex + frames) % depth
        }

        for i in 0..<(frames * 2) {
            XCTAssertEqual(got[i], ref[i], accuracy: 1e-6, "sample \(i)")
        }
    }

    func testRingBaseOffsetRChannel() {
        let depth = 4
        let ringCapacity = 8
        let ringBase = 4
        let frames = 6
        let input = lcgBuffer(frames * 2, seed: 7)
        let ref = referenceDelay(input, depth: depth)

        var ring = [Float](repeating: 0, count: ringCapacity)
        var writeIndex = 0
        var got = [Float](repeating: 0, count: frames * 2)

        for call in 0..<2 {
            let offset = call * frames
            var buf = Array(input[offset..<(offset + frames)])
            buf.withUnsafeMutableBufferPointer { bp in
                ring.withUnsafeMutableBufferPointer { rp in
                    DSPKernels.ringDelaySwap(io: bp.baseAddress!, ioStride: 1,
                                             ring: rp.baseAddress!, ringBase: ringBase,
                                             writeIndex: writeIndex, depth: depth, frames: frames)
                }
            }
            for i in 0..<frames { got[offset + i] = buf[i] }
            writeIndex = (writeIndex + frames) % depth
        }

        for i in 0..<(frames * 2) {
            XCTAssertEqual(got[i], ref[i], accuracy: 1e-6, "sample \(i)")
        }
        for i in 0..<ringBase {
            XCTAssertEqual(ring[i], 0, "L-slot \(i) should be untouched")
        }
    }
}
