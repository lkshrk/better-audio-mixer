import CoreAudio
import XCTest
@testable import AudioEngine

/// Mixer at unity plus limiter must pass sub-ceiling program through untouched (up to the limiter delay).
final class DSPTransparencyTests: XCTestCase {
    private let sampleRate = 48_000.0
    private let block = 512

    private func signal(frames: Int, seed: UInt64, low: Float, high: Float) -> ([Float], [Float]) {
        var state = seed
        func noise() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: state >> 11) % 1_000_000) / 1_000_000
        }
        var l = [Float](repeating: 0, count: frames)
        var r = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            let t = Float(i) / Float(sampleRate)
            let bass = 0.45 * sin(2 * .pi * 40 * t)
            let mid = 0.15 * sin(2 * .pi * 1_000 * t)
            l[i] = bass + mid + 0.05 * noise()
            r[i] = bass - mid + 0.05 * noise()
            l[i] = min(high, max(low, l[i])); r[i] = min(high, max(low, r[i]))
        }
        return (l, r)
    }

    private func runChain(inputL: [Float], inputR: [Float], interleaved: Bool) throws -> ([Float], [Float], Int) {
        let cells = RouterAtomicCells(count: 1)
        cells.storeGain(0, left: 1, right: 1)
        let mixer = try XCTUnwrap(RouterInputMixer(channels: [2], cells: cells, sampleRate: sampleRate))
        let limiter = try XCTUnwrap(NativePeakLimiter(sampleRate: sampleRate, maximumFrames: block))
        let frames = inputL.count
        var outL = [Float](repeating: 0, count: frames)
        var outR = [Float](repeating: 0, count: frames)
        let list = AudioBufferList.allocate(maximumBuffers: 1)
        defer { list.unsafeMutablePointer.deallocate() }
        let input = UnsafeMutablePointer<Float>.allocate(capacity: block * 2)
        defer { input.deallocate() }
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: block * 2)
        defer { scratch.deallocate() }
        var offset = 0
        while offset < frames {
            let n = min(block, frames - offset)
            for i in 0..<n { input[i * 2] = inputL[offset + i]; input[i * 2 + 1] = inputR[offset + i] }
            list[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(n * 8), mData: input)
            if interleaved {
                mixer.mix(UnsafePointer(list.unsafeMutablePointer), left: scratch, right: scratch + 1,
                          outputStride: 2, outputFrames: n)
                limiter.process(left: scratch, right: scratch + 1, stride: 2, frames: n)
                for i in 0..<n { outL[offset + i] = scratch[i * 2]; outR[offset + i] = scratch[i * 2 + 1] }
            } else {
                mixer.mix(UnsafePointer(list.unsafeMutablePointer), left: scratch, right: scratch + block,
                          outputStride: 1, outputFrames: n)
                limiter.process(left: scratch, right: scratch + block, stride: 1, frames: n)
                for i in 0..<n { outL[offset + i] = scratch[i]; outR[offset + i] = scratch[block + i] }
            }
            offset += n
        }
        return (outL, outR, limiter.delayFrames)
    }

    private func assertTransparent(interleaved: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
        let frames = block * 40
        let (inL, inR) = signal(frames: frames, seed: 7, low: -0.9, high: 0.9)
        let (outL, outR, delay) = try runChain(inputL: inL, inputR: inR, interleaved: interleaved)
        let settle = block * 4
        var maxErrL: Float = 0, maxErrR: Float = 0
        var inEnergy: Double = 0, outEnergy: Double = 0
        for i in settle..<(frames - delay) {
            maxErrL = max(maxErrL, abs(outL[i + delay] - inL[i]))
            maxErrR = max(maxErrR, abs(outR[i + delay] - inR[i]))
            inEnergy += Double(inL[i] * inL[i]); outEnergy += Double(outL[i + delay] * outL[i + delay])
        }
        XCTAssertLessThan(maxErrL, 1e-4, "left deviates from input (delay \(delay))", file: file, line: line)
        XCTAssertLessThan(maxErrR, 1e-4, "right deviates from input (delay \(delay))", file: file, line: line)
        XCTAssertEqual(outEnergy / inEnergy, 1, accuracy: 1e-3, "energy not preserved", file: file, line: line)
        XCTAssertNotEqual(outL[settle + delay + 100], outR[settle + delay + 100], "channels collapsed", file: file, line: line)
    }

    func testInterleavedStereoChainIsTransparentBelowCeiling() throws {
        try assertTransparent(interleaved: true)
    }

    func testPlanarStereoChainIsTransparentBelowCeiling() throws {
        try assertTransparent(interleaved: false)
    }

    func testHalfGainScalesExactly() throws {
        let cells = RouterAtomicCells(count: 1)
        cells.storeGain(0, left: 0.5, right: 0.25)
        let mixer = try XCTUnwrap(RouterInputMixer(channels: [2], cells: cells, sampleRate: sampleRate))
        let input = UnsafeMutablePointer<Float>.allocate(capacity: block * 2)
        defer { input.deallocate() }
        for i in 0..<block { input[i * 2] = 0.8; input[i * 2 + 1] = -0.4 }
        let list = AudioBufferList.allocate(maximumBuffers: 1)
        defer { list.unsafeMutablePointer.deallocate() }
        list[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(block * 8), mData: input)
        let out = UnsafeMutablePointer<Float>.allocate(capacity: block * 2)
        defer { out.deallocate() }
        for _ in 0..<4 {
            mixer.mix(UnsafePointer(list.unsafeMutablePointer), left: out, right: out + 1, outputStride: 2, outputFrames: block)
        }
        XCTAssertEqual(out[(block - 1) * 2], 0.4, accuracy: 1e-6)
        XCTAssertEqual(out[(block - 1) * 2 + 1], -0.1, accuracy: 1e-6)
    }

    func testOverCeilingSineIsLimitedNotHardClipped() throws {
        let frames = block * 40
        var l = [Float](repeating: 0, count: frames)
        for i in 0..<frames { l[i] = 2 * sin(2 * .pi * 1_000 * Float(i) / Float(sampleRate)) }
        let (outL, _, _) = try runChain(inputL: l, inputR: l, interleaved: true)
        let tail = outL[(block * 8)...]
        let nearCeiling = Double(tail.filter { abs($0) > 0.99 }.count) / Double(tail.count)
        let unitSineShare = 0.0903
        XCTAssertLessThan(nearCeiling, unitSineShare * 1.6, "flat-topped output: hard clipping instead of limiting")
        XCTAssertGreaterThan(tail.map { abs($0) }.max() ?? 0, 0.8)
    }
}
