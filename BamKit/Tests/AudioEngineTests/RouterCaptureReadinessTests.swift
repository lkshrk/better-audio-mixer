import CoreAudio
import XCTest
@testable import AudioEngine

final class RouterCaptureReadinessTests: XCTestCase {
    private func assertWait(_ readiness: RouterAggregate.CaptureReadiness, after token: UInt64, timeout: TimeInterval,
                            _ expected: Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) async {
        let result = await readiness.wait(after: token, timeout: timeout)
        XCTAssertEqual(result, expected, message, file: file, line: line)
    }
    func testTwoMonoStreamsAreStereoDespiteMonoFirstStreamFormat() throws {
        let buffers = AudioBufferList.allocate(maximumBuffers: 2)
        defer { buffers.unsafeMutablePointer.deallocate() }
        let mono = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        let layout = try XCTUnwrap(RouterAggregate.OutputLayout(bufferChannels: [1, 1], streamFormats: [mono, mono]))
        var silence = [Float](repeating: 0, count: 8)
        silence.withUnsafeMutableBytes { samples in
            buffers[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 16, mData: samples.baseAddress)
            buffers[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 16, mData: samples.baseAddress!.advanced(by: 16))
            XCTAssertEqual(RouterAggregate.validOutputFrames(buffers, layout: layout), 4)
        }
    }

    func testOnlyCompletedValidCallbackAfterTokenConfirmsReadiness() async {
        let readiness = RouterAggregate.CaptureReadiness()
        await assertWait(readiness, after: 0, timeout: 0, false)
        let old = readiness.beginCallback()
        let token = readiness.token
        readiness.completeCallback(old, valid: true)
        await assertWait(readiness, after: token, timeout: 0, false, "In-flight callback predates the edit")
        let failed = readiness.beginCallback()
        readiness.completeCallback(failed, valid: false)
        await assertWait(readiness, after: token, timeout: 0, false, "Invalid layout or limiter failure is not readiness")
        let valid = readiness.beginCallback()
        await assertWait(readiness, after: token, timeout: 0, false, "Starting a callback is insufficient")
        readiness.completeCallback(valid, valid: true)
        await assertWait(readiness, after: token, timeout: 0, true)
        readiness.completeCallback(readiness.beginCallback(), valid: false)
        await assertWait(readiness, after: token, timeout: 0, false, "A subsequent failure invalidates old success")
    }

    func testMonoAndInterleavedStereoOutputLayouts() throws {
        let buffers = AudioBufferList.allocate(maximumBuffers: 1)
        defer { buffers.unsafeMutablePointer.deallocate() }
        var silence = [Float](repeating: 0, count: 8)
        for channels in [UInt32(1), 2] {
            let format = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
                mBytesPerPacket: channels * 4, mFramesPerPacket: 1, mBytesPerFrame: channels * 4,
                mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
            let layout = try XCTUnwrap(RouterAggregate.OutputLayout(bufferChannels: [Int(channels)], streamFormats: [format]))
            silence.withUnsafeMutableBytes { samples in
                buffers[0] = AudioBuffer(mNumberChannels: channels, mDataByteSize: channels * 16, mData: samples.baseAddress)
                XCTAssertEqual(RouterAggregate.validOutputFrames(buffers, layout: layout), 4)
                buffers[0].mNumberChannels = channels == 1 ? 2 : 1
                XCTAssertNil(RouterAggregate.validOutputFrames(buffers, layout: layout))
            }
        }
    }

    func testOutputLayoutRejectsUnsupportedOrInconsistentStreamFormats() {
        let mono = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        XCTAssertNil(RouterAggregate.OutputLayout(bufferChannels: [], streamFormats: []))
        XCTAssertNil(RouterAggregate.OutputLayout(bufferChannels: [1], streamFormats: []))
        XCTAssertNil(RouterAggregate.OutputLayout(bufferChannels: [0], streamFormats: [mono]))
        XCTAssertNil(RouterAggregate.OutputLayout(bufferChannels: [1, 1], streamFormats: [mono]))
        XCTAssertNil(RouterAggregate.OutputLayout(bufferChannels: [2], streamFormats: [mono, mono]))
        XCTAssertNil(RouterAggregate.OutputLayout(bufferChannels: [1, 1, 1], streamFormats: [mono, mono, mono]))
        var unsupported = mono
        unsupported.mChannelsPerFrame = 3
        unsupported.mBytesPerFrame = 12
        unsupported.mBytesPerPacket = 12
        XCTAssertNil(RouterAggregate.OutputLayout(bufferChannels: [3], streamFormats: [unsupported]))
        let mutations: [(inout AudioStreamBasicDescription) -> Void] = [
            { $0.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked },
            { $0.mFormatFlags |= kAudioFormatFlagIsBigEndian },
            { $0.mBytesPerFrame = 8 },
            { $0.mBytesPerPacket = 8 },
            { $0.mBitsPerChannel = 16 },
            { $0.mChannelsPerFrame = .max },
            { $0.mSampleRate = 44_100 },
            { $0.mSampleRate = .nan },
        ]
        for mutation in mutations {
            var invalid = mono
            mutation(&invalid)
            XCTAssertNil(RouterAggregate.OutputLayout(bufferChannels: [1, 1], streamFormats: [mono, invalid]),
                         "Every stream must have a supported format at the same sample rate")
        }
    }

    func testNoCallbackTimesOutAndInvalidTimeoutIsRejected() async {
        let readiness = RouterAggregate.CaptureReadiness()
        let start = ContinuousClock.now
        await assertWait(readiness, after: 0, timeout: 0.002, false)
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        await assertWait(readiness, after: 0, timeout: .infinity, false)
        await assertWait(readiness, after: 0, timeout: -.infinity, false)
        await assertWait(readiness, after: 0, timeout: .nan, false)
    }

    func testSilentAndInactiveSourcesRetainExpectedInputLayout() {
        let buffers = AudioBufferList.allocate(maximumBuffers: 2)
        defer { buffers.unsafeMutablePointer.deallocate() }
        var silence = [Float](repeating: 0, count: 8)
        silence.withUnsafeMutableBytes { samples in
            buffers[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: 32, mData: samples.baseAddress)
            buffers[1] = AudioBuffer(mNumberChannels: 2, mDataByteSize: 0, mData: nil)
            XCTAssertTrue(RouterAggregate.hasValidInputLayout(buffers, channels: 4))
            buffers[0].mData = nil
            XCTAssertTrue(RouterAggregate.hasValidInputLayout(buffers, channels: 4), "Idle slots preserve routing indices")
            XCTAssertFalse(RouterAggregate.hasValidInputLayout(buffers, channels: 2))
            buffers[1].mNumberChannels = 0
            XCTAssertFalse(RouterAggregate.hasValidInputLayout(buffers, channels: 2))
            buffers[1].mNumberChannels = 2
            buffers[0].mDataByteSize = 7
            XCTAssertFalse(RouterAggregate.hasValidInputLayout(buffers, channels: 4))
        }
    }

    func testOutputRequiresCompleteFrozenLayoutAndNonemptyFrames() throws {
        let buffers = AudioBufferList.allocate(maximumBuffers: 2)
        defer { buffers.unsafeMutablePointer.deallocate() }
        let format = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        let layout = try XCTUnwrap(RouterAggregate.OutputLayout(bufferChannels: [1, 1], streamFormats: [format]))
        var silence = [Float](repeating: 0, count: 8)
        silence.withUnsafeMutableBytes { samples in
            buffers[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 16, mData: samples.baseAddress)
            buffers[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 16, mData: samples.baseAddress!.advanced(by: 16))
            XCTAssertEqual(RouterAggregate.validOutputFrames(buffers, layout: layout), 4)
            buffers[1].mDataByteSize = 12
            XCTAssertNil(RouterAggregate.validOutputFrames(buffers, layout: layout))
            buffers[1].mDataByteSize = 15
            XCTAssertNil(RouterAggregate.validOutputFrames(buffers, layout: layout))
            buffers[1].mDataByteSize = 16
            buffers[1].mData = nil
            XCTAssertNil(RouterAggregate.validOutputFrames(buffers, layout: layout))
            buffers[0].mDataByteSize = 0
            XCTAssertNil(RouterAggregate.validOutputFrames(buffers, layout: layout))
            buffers.unsafeMutablePointer.pointee.mNumberBuffers = 1
            XCTAssertNil(RouterAggregate.validOutputFrames(buffers, layout: layout), "Missing right stream")
        }
    }
}
