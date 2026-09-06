import XCTest
@testable import AudioEngine

final class NativePeakLimiterTests: XCTestCase {
    private func assertNoSafetyIntervention(_ limiter: NativePeakLimiter,
                                           file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(limiter.guardedSamples, 0,
                       "normal signals must be limited by the AU, not hidden by final clipping", file: file, line: line)
        XCTAssertEqual(limiter.renderFailures, 0,
                       "silencing a failed render must not pass the signal-quality tests", file: file, line: line)
    }

    private func render(_ left: [Float], _ right: [Float]? = nil, rate: Double = 48000,
                        blocks: [Int] = [128]) throws -> ([Float], [Float], NativePeakLimiter) {
        let limiter = try XCTUnwrap(NativePeakLimiter(sampleRate: rate, maximumFrames: blocks.max()!))
        var l = left, r = right ?? left
        let total = left.count
        l.withUnsafeMutableBufferPointer { lp in
            r.withUnsafeMutableBufferPointer { rp in
                var offset = 0, block = 0
                while offset < total {
                    let count = min(blocks[block % blocks.count], total - offset)
                    limiter.process(left: lp.baseAddress! + offset, right: rp.baseAddress! + offset, stride: 1, frames: count)
                    offset += count; block += 1
                }
            }
        }
        return (l, r, limiter)
    }

    func testTransparentDelayAndCeilingAcrossRates() throws {
        for rate in [44100.0, 48000.0, 96000.0] {
            var impulse = [Float](repeating: 0, count: 2048); impulse[100] = 0.25
            let (output, _, limiter) = try render(impulse, rate: rate)
            XCTAssertEqual(output.firstIndex(where: { $0 != 0 }), 100 + limiter.delayFrames)
            for i in limiter.delayFrames..<output.count { XCTAssertEqual(output[i], impulse[i - limiter.delayFrames], accuracy: 1e-6) }
            assertNoSafetyIntervention(limiter)
            for phase in 0..<128 {
                impulse = [Float](repeating: 0, count: 1024); impulse[128 + phase] = 2
                let (limited, _, limiter) = try render(impulse, rate: rate)
                XCTAssertTrue(limited.allSatisfy { $0.isFinite && abs($0) <= 1.00001 })
                assertNoSafetyIntervention(limiter)
            }
        }
    }

    func testStereoLinkPartitionsAndRecovery() throws {
        let signal = (0..<48000).map { Float($0 < 12000 ? 2 : 0.1) }
        let (left, right, limiter) = try render(signal, signal.map { $0 * 0.1 })
        var seed: UInt64 = 173
        let blocks = (0..<1024).map { _ -> Int in seed = seed &* 6364136223846793005 &+ 1; return Int((seed >> 32) % 1024) + 1 }
        let (partitioned, _, partitionedLimiter) = try render(signal, signal.map { $0 * 0.1 }, blocks: blocks)
        for i in left.indices {
            XCTAssertEqual(right[i], left[i] * 0.1, accuracy: 1e-6)
            XCTAssertEqual(left[i], partitioned[i], accuracy: 1e-6)
            XCTAssertLessThanOrEqual(abs(left[i]), 1.00001)
        }
        XCTAssertEqual(left.last!, 0.1, accuracy: 1e-5)
        assertNoSafetyIntervention(limiter)
        assertNoSafetyIntervention(partitionedLimiter)
    }

    func testInvalidAndHugeFiniteInputRecoversWithoutPoisoningQuietChannel() throws {
        var signal = [Float](repeating: 0.1, count: 48000)
        for (offset, value) in [Float.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude].enumerated() {
            signal[1024 + offset] = value
        }
        let (left, right, limiter) = try render(signal, [Float](repeating: 0.01, count: signal.count))
        XCTAssertTrue(left.allSatisfy { $0.isFinite && abs($0) <= 1 })
        XCTAssertTrue(right.allSatisfy { $0.isFinite && abs($0) <= 1 })
        XCTAssertEqual(left.last!, 0.1, accuracy: 1e-5)
        XCTAssertEqual(right.last!, 0.01, accuracy: 1e-5)
        XCTAssertGreaterThanOrEqual(limiter.guardedSamples, 5)
        XCTAssertEqual(limiter.renderFailures, 0)
    }

    func testInterleavedMonoOversizedAndReset() throws {
        let limiter = try XCTUnwrap(NativePeakLimiter(sampleRate: 48000, maximumFrames: 256))
        var interleaved = [Float](repeating: 0, count: 512)
        interleaved[0] = 0.25; interleaved[1] = 0.125
        interleaved.withUnsafeMutableBufferPointer {
            XCTAssertFalse(limiter.process(left: $0.baseAddress!, right: $0.baseAddress! + 1, stride: 2, frames: 256))
        }
        XCTAssertEqual(interleaved[limiter.delayFrames * 2], 0.25)
        XCTAssertEqual(interleaved[limiter.delayFrames * 2 + 1], 0.125)
        XCTAssertTrue(limiter.reset())
        var mono = [Float](repeating: 0, count: 256); mono[0] = 0.25
        mono.withUnsafeMutableBufferPointer { _ = limiter.process(left: $0.baseAddress!, right: nil, stride: 1, frames: 256) }
        XCTAssertEqual(mono[limiter.delayFrames], 0.25)
        assertNoSafetyIntervention(limiter)
        var oversized = [Float](repeating: 2, count: 257)
        oversized.withUnsafeMutableBufferPointer { XCTAssertTrue(limiter.process(left: $0.baseAddress!, right: nil, stride: 1, frames: 257)) }
        XCTAssertTrue(oversized.allSatisfy { $0 == 0 })
        XCTAssertEqual(limiter.renderFailures, 1)
        XCTAssertNil(NativePeakLimiter(sampleRate: .nan, maximumFrames: 256))
        XCTAssertNil(NativePeakLimiter(sampleRate: 48000, maximumFrames: 0))
    }
}
