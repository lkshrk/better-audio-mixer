import XCTest
@testable import AudioEngine

final class RingBufferTests: XCTestCase {
    private func writeRamp(_ ring: RingBuffer, from: Int, frames: Int) {
        var buf = [Float](repeating: 0, count: frames * ring.channels)
        for f in 0..<frames {
            for c in 0..<ring.channels {
                buf[f * ring.channels + c] = Float(from + f) + Float(c) * 0.001
            }
        }
        buf.withUnsafeBufferPointer { ring.write($0.baseAddress!, frames: frames) }
    }

    func testCapacityRoundsToPowerOfTwo() {
        XCTAssertEqual(RingBuffer(channels: 2, slackFrames: 4096).capacityFrames, 8192)
        XCTAssertEqual(RingBuffer(channels: 2, slackFrames: 100).capacityFrames, 256)
        XCTAssertEqual(RingBuffer(channels: 1, slackFrames: 1).capacityFrames, 2)
    }

    func testWriteThenReadReturnsExactSamples() {
        let ring = RingBuffer(channels: 2, slackFrames: 1024)
        writeRamp(ring, from: 0, frames: 64)
        let reader = RingReader(ring: ring, prefillFrames: 64)
        var out = [Float](repeating: -1, count: 64 * 2)
        let real = out.withUnsafeMutableBufferPointer { reader.read(into: $0.baseAddress!, frames: 64) }
        XCTAssertEqual(real, 64)
        for f in 0..<64 {
            XCTAssertEqual(out[f * 2 + 0], Float(f), accuracy: 0)
            XCTAssertEqual(out[f * 2 + 1], Float(f) + 0.001, accuracy: 1e-6)
        }
    }

    func testUnderrunFillsSilenceAndKeepsClock() {
        let ring = RingBuffer(channels: 2, slackFrames: 1024)
        writeRamp(ring, from: 0, frames: 32)
        let reader = RingReader(ring: ring, prefillFrames: 32)
        var out = [Float](repeating: -1, count: 64 * 2)
        // Ask for 64 but only 32 are written → 32 real + 32 silence.
        let real = out.withUnsafeMutableBufferPointer { reader.read(into: $0.baseAddress!, frames: 64) }
        XCTAssertEqual(real, 32)
        for f in 32..<64 {
            XCTAssertEqual(out[f * 2 + 0], 0)
            XCTAssertEqual(out[f * 2 + 1], 0)
        }
        // Writer catches up past the gap; clock stayed aligned so the silent
        // frames are skipped (not replayed).
        writeRamp(ring, from: 32, frames: 64)
        var out2 = [Float](repeating: -1, count: 32 * 2)
        let real2 = out2.withUnsafeMutableBufferPointer { reader.read(into: $0.baseAddress!, frames: 32) }
        XCTAssertEqual(real2, 32)
        // Cursor was at 64 (advanced past the underrun), so first sample = 64.
        XCTAssertEqual(out2[0], 64)
    }

    func testIndependentReadersDoNotInterfere() {
        let ring = RingBuffer(channels: 1, slackFrames: 1024)
        writeRamp(ring, from: 0, frames: 100)
        let a = RingReader(ring: ring, prefillFrames: 100)
        let b = RingReader(ring: ring, prefillFrames: 100)
        var oa = [Float](repeating: 0, count: 40)
        var ob = [Float](repeating: 0, count: 100)
        _ = oa.withUnsafeMutableBufferPointer { a.read(into: $0.baseAddress!, frames: 40) }
        _ = ob.withUnsafeMutableBufferPointer { b.read(into: $0.baseAddress!, frames: 100) }
        XCTAssertEqual(oa.first, 0)
        XCTAssertEqual(oa.last, 39)
        XCTAssertEqual(ob.first, 0)
        XCTAssertEqual(ob.last, 99)
    }

    func testLaggingReaderSnapsForwardOnOverrun() {
        let ring = RingBuffer(channels: 1, slackFrames: 8) // capacity 16
        let reader = RingReader(ring: ring, prefillFrames: 0)
        writeRamp(ring, from: 0, frames: 64) // laps the 16-frame ring 4×
        var out = [Float](repeating: -1, count: 8)
        let real = out.withUnsafeMutableBufferPointer { reader.read(into: $0.baseAddress!, frames: 8) }
        XCTAssertEqual(real, 8)
        // Oldest valid frame = writeFrame(64) - capacity(16) = 48.
        XCTAssertEqual(out.first, 48)
        XCTAssertEqual(out.last, 55)
    }

    func testConcurrentWriterReaderNoCrash() {
        let ring = RingBuffer(channels: 2, slackFrames: 4096)
        let reader = RingReader(ring: ring, prefillFrames: 0)
        let writes = DispatchQueue(label: "w")
        let exp = expectation(description: "done")
        var block = [Float](repeating: 0.5, count: 256 * 2)
        writes.async {
            for i in 0..<2000 {
                for k in 0..<block.count { block[k] = Float(i) }
                block.withUnsafeBufferPointer { ring.write($0.baseAddress!, frames: 256) }
            }
            exp.fulfill()
        }
        var out = [Float](repeating: 0, count: 256 * 2)
        for _ in 0..<4000 {
            _ = out.withUnsafeMutableBufferPointer { reader.read(into: $0.baseAddress!, frames: 256) }
        }
        wait(for: [exp], timeout: 10)
    }
}
