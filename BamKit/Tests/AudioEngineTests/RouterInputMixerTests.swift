import CoreAudio
import XCTest
@testable import AudioEngine

final class RouterInputMixerTests: XCTestCase {
    private func render(_ mixer: RouterInputMixer, _ inputs: [(Int, [Float]?)], frames: Int,
                        mono: Bool = false, interleaved: Bool = false) -> ([Float], [Float]) {
        let list = AudioBufferList.allocate(maximumBuffers: inputs.count)
        var storage: [UnsafeMutablePointer<Float>] = []
        defer { storage.forEach { $0.deallocate() }; list.unsafeMutablePointer.deallocate() }
        for (i, input) in inputs.enumerated() {
            var pointer: UnsafeMutablePointer<Float>?
            if let values = input.1 {
                let p = UnsafeMutablePointer<Float>.allocate(capacity: max(1, values.count))
                p.initialize(from: values, count: values.count)
                storage.append(p); pointer = p
            }
            list[i] = AudioBuffer(mNumberChannels: UInt32(input.0),
                mDataByteSize: UInt32((input.1?.count ?? frames * input.0) * 4), mData: pointer)
        }
        var left = [Float](repeating: 0, count: frames * (interleaved ? 2 : 1))
        var right = [Float](repeating: 0, count: frames)
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                _ = mixer.mix(UnsafePointer(list.unsafeMutablePointer), left: l.baseAddress!,
                              right: mono ? nil : (interleaved ? l.baseAddress! + 1 : r.baseAddress!),
                              outputStride: interleaved ? 2 : 1, outputFrames: frames)
            }
        }
        if interleaved {
            return ((0..<frames).map { left[$0 * 2] }, (0..<frames).map { left[$0 * 2 + 1] })
        }
        return (left, right)
    }

    func testFiniteRampRetargetsAndIsIndependentOfBlockPartition() {
        func run(_ blocks: [Int]) -> [Float] {
            var ramp = GainRamp(length: 10)
            ramp.setTarget(1)
            var samples: [Float] = []
            for block in blocks { for _ in 0..<block { samples.append(ramp.next()) } }
            return samples
        }
        XCTAssertEqual(run([20]), run([1, 3, 7, 2, 7]))
        let values = run([20])
        XCTAssertEqual(values[0], 0.1, accuracy: 0.000001)
        XCTAssertEqual(values[9], 1)
        var ramp = GainRamp(length: 4)
        ramp.setTarget(1); _ = ramp.next(); _ = ramp.next()
        ramp.setTarget(0)
        XCTAssertEqual(ramp.next(), 0.375)
        _ = ramp.next(); _ = ramp.next()
        XCTAssertEqual(ramp.next(), 0)
        ramp.setTarget(.nan)
        XCTAssertEqual(ramp.next(), 0)
    }

    func testSilentBufferRetainsItsChannelsAndLaterSourceGain() throws {
        let cells = RouterAtomicCells(count: 2)
        cells.storeGain(0, left: 1, right: 1); cells.storeGain(1, left: 0.25, right: 0.5)
        let mixer = try XCTUnwrap(RouterInputMixer(channels: [2, 2], cells: cells, sampleRate: 48000))
        _ = render(mixer, [(2, nil), (2, nil)], frames: 240)
        let output = render(mixer, [(2, nil), (2, [1, 1, 1, 1])], frames: 2)
        XCTAssertEqual(output.0, [0.25, 0.25])
        XCTAssertEqual(output.1, [0.5, 0.5])
        XCTAssertEqual(mixer.frames[0], 0)
        XCTAssertEqual(mixer.frames[1], 4)
    }

    func testMonoFeedsBothSidesAndStereoDownmixDoesNotDouble() throws {
        let cells = RouterAtomicCells(count: 1); cells.storeGain(0, left: 0.5, right: 0.25)
        let mono = try XCTUnwrap(RouterInputMixer(channels: [1], cells: cells, sampleRate: 48000))
        _ = render(mono, [(1, nil)], frames: 240)
        let output = render(mono, [(1, [1, 1])], frames: 2)
        XCTAssertEqual(output.0, [0.5, 0.5]); XCTAssertEqual(output.1, [0.25, 0.25])
        XCTAssertEqual(mono.framesL[0], 2); XCTAssertEqual(mono.framesR[0], 2)
        cells.storeGain(0, left: 1, right: 1)
        let stereo = try XCTUnwrap(RouterInputMixer(channels: [2], cells: cells, sampleRate: 48000))
        _ = render(stereo, [(2, nil)], frames: 240)
        let downmix = render(stereo, [(2, [1, 1, -1, -1])], frames: 2, mono: true)
        XCTAssertEqual(downmix.0, [1, -1])
    }

    func testFirstContributorOverwritesStaleOutputAndShortInputClearsTail() throws {
        let cells = RouterAtomicCells(count: 1); cells.storeGain(0, left: 1, right: 1)
        let mixer = try XCTUnwrap(RouterInputMixer(channels: [2], cells: cells, sampleRate: 48000))
        _ = render(mixer, [(2, nil)], frames: 240)
        let list = AudioBufferList.allocate(maximumBuffers: 1)
        defer { list.unsafeMutablePointer.deallocate() }
        var input: [Float] = [0.5, -0.5, 0.25, -0.25]
        var left = [Float](repeating: 9, count: 4)
        var right = [Float](repeating: 9, count: 4)
        input.withUnsafeMutableBytes { bytes in
            list[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: 16, mData: bytes.baseAddress)
            left.withUnsafeMutableBufferPointer { l in
                right.withUnsafeMutableBufferPointer { r in
                    _ = mixer.mix(UnsafePointer(list.unsafeMutablePointer), left: l.baseAddress!, right: r.baseAddress!,
                              outputStride: 1, outputFrames: 4)
                }
            }
        }
        XCTAssertEqual(left, [0.5, 0.25, 0, 0], "stale output is overwritten; missing input frames read as silence")
        XCTAssertEqual(right, [-0.5, -0.25, 0, 0])
        XCTAssertTrue(mixer.frameCountDiverged)
        let silent = render(mixer, [(2, nil)], frames: 4)
        XCTAssertEqual(silent.0, [0, 0, 0, 0])
        XCTAssertFalse(mixer.frameCountDiverged, "a null slot carries no frame count to compare")
    }

    func testMixerRampsGainWithoutAddingSampleDelay() throws {
        let cells = RouterAtomicCells(count: 1); cells.storeGain(0, left: 1, right: 1)
        let mixer = try XCTUnwrap(RouterInputMixer(channels: [1], cells: cells, sampleRate: 48000))
        let output = render(mixer, [(1, [Float](repeating: 1, count: 241))], frames: 241)
        XCTAssertGreaterThan(output.0[0], 0)
        XCTAssertLessThan(output.0[0], 0.005)
        XCTAssertEqual(output.0[239], 1)
        XCTAssertEqual(output.0, output.1)
        for i in 1..<240 { XCTAssertLessThanOrEqual(abs(output.0[i] - output.0[i - 1]), 0.004168) }
    }

    func testRejectsUnsupportedSampleFormatsAndChannelLayouts() {
        var format = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked, mBytesPerPacket: 8, mFramesPerPacket: 1,
            mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        XCTAssertTrue(RouterAggregate.supportsFormat(format))
        format.mFormatFlags = kAudioFormatFlagIsSignedInteger
        XCTAssertFalse(RouterAggregate.supportsFormat(format))
        format.mFormatFlags = kAudioFormatFlagsNativeFloatPacked
        format.mChannelsPerFrame = 6
        XCTAssertFalse(RouterAggregate.supportsFormat(format))
        XCTAssertNil(RouterInputMixer(channels: [6], cells: RouterAtomicCells(count: 1), sampleRate: 48000))
        XCTAssertNil(RouterInputMixer(channels: [2], cells: RouterAtomicCells(count: 2), sampleRate: 48000))
    }

    func testInterleavedOutputMatchesPlanarThroughRampsAndSilentInput() throws {
        let cells = RouterAtomicCells(count: 2)
        cells.storeGain(0, left: 0.8, right: 0.4); cells.storeGain(1, left: 0.25, right: 0.75)
        let planar = try XCTUnwrap(RouterInputMixer(channels: [2, 1], cells: cells, sampleRate: 48000))
        let interleaved = try XCTUnwrap(RouterInputMixer(channels: [2, 1], cells: cells, sampleRate: 48000))
        for block in 0..<8 {
            if block == 3 { cells.storeGain(1, left: 0.9, right: 0.1) }
            let stereo: [Float]? = block == 4 ? nil : (0..<128).map { $0 % 2 == 0 ? 0.2 : -0.3 }
            let mono = (0..<64).map { Float($0) / 128 }
            let inputs: [(Int, [Float]?)] = [(2, stereo), (1, mono)]
            let expected = render(planar, inputs, frames: 64)
            let actual = render(interleaved, inputs, frames: 64, interleaved: true)
            XCTAssertEqual(actual.0, expected.0)
            XCTAssertEqual(actual.1, expected.1)
        }
    }
}
