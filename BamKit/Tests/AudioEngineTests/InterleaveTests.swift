import XCTest
@testable import AudioEngine

final class InterleaveTests: XCTestCase {
    /// Run `interleavePlanar` over `[[Float]]` planes and return the dst buffer
    /// (sized channels*frames, pre-zeroed).
    private func interleave(_ planes: [[Float]], frames: Int, channels: Int) -> [Float] {
        var dst = [Float](repeating: 0, count: channels * frames)
        // Hold each plane's pointer for the duration of the call.
        func go(_ ptrs: [UnsafePointer<Float>?]) {
            dst.withUnsafeMutableBufferPointer { out in
                interleavePlanar(ptrs, frames: frames, channels: channels, into: out.baseAddress!)
            }
        }
        var ptrs: [UnsafePointer<Float>?] = []
        func bind(_ remaining: ArraySlice<[Float]>) {
            guard let first = remaining.first else { go(ptrs); return }
            first.withUnsafeBufferPointer { buf in
                ptrs.append(buf.baseAddress)
                bind(remaining.dropFirst())
                ptrs.removeLast()
            }
        }
        bind(planes[...])
        return dst
    }

    func testStereoInterleavesFrameMajor() {
        let left: [Float] = [1, 2, 3]
        let right: [Float] = [10, 20, 30]
        let out = interleave([left, right], frames: 3, channels: 2)
        XCTAssertEqual(out, [1, 10, 2, 20, 3, 30])
    }

    func testMonoIsIdentity() {
        let out = interleave([[4, 5, 6, 7]], frames: 4, channels: 1)
        XCTAssertEqual(out, [4, 5, 6, 7])
    }

    func testExtraPlanesBeyondChannelsIgnored() {
        // 3 planes provided but only 2 channels → third dropped.
        let out = interleave([[1, 2], [3, 4], [99, 99]], frames: 2, channels: 2)
        XCTAssertEqual(out, [1, 3, 2, 4])
    }

    func testFewerPlanesThanChannelsLeavesGapsZeroed() {
        // 1 plane, 2 channels → channel 1 slots stay at the pre-zeroed value.
        let out = interleave([[1, 2, 3]], frames: 3, channels: 2)
        XCTAssertEqual(out, [1, 0, 2, 0, 3, 0])
    }

    func testNilPlaneSkippedLeavesSlotsUntouched() {
        var dst = [Float](repeating: -1, count: 4) // 2ch x 2fr, sentinel
        let ch1: [Float] = [7, 8]
        ch1.withUnsafeBufferPointer { buf in
            let planes: [UnsafePointer<Float>?] = [nil, buf.baseAddress]
            dst.withUnsafeMutableBufferPointer { out in
                interleavePlanar(planes, frames: 2, channels: 2, into: out.baseAddress!)
            }
        }
        // Channel 0 (nil) untouched → sentinel; channel 1 written.
        XCTAssertEqual(dst, [-1, 7, -1, 8])
    }

    func testZeroFramesWritesNothing() {
        let out = interleave([[1, 2], [3, 4]], frames: 0, channels: 2)
        XCTAssertEqual(out, [])
    }

    func testZeroChannelsIsNoop() {
        var dst = [Float](repeating: 5, count: 3)
        let plane: [Float] = [1, 2, 3]
        plane.withUnsafeBufferPointer { buf in
            let planes: [UnsafePointer<Float>?] = [buf.baseAddress]
            dst.withUnsafeMutableBufferPointer { out in
                interleavePlanar(planes, frames: 3, channels: 0, into: out.baseAddress!)
            }
        }
        XCTAssertEqual(dst, [5, 5, 5])
    }
}
