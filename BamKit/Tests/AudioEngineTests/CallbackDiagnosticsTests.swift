import XCTest
import BamCore
@testable import AudioEngine

final class CallbackDiagnosticsTests: XCTestCase {
    func testConcreteActorCallsUseDiagnosticsImplementations() async {
        let engine = CoreAudioEngine()
        let idle = await engine.audioDiagnostics()
        XCTAssertNotNil(idle, "concrete actor call must not select the protocol's nil fallback")
        XCTAssertEqual(idle?.callbackCount, 0)
        let mock = MockAudioEngine()
        var expected = AudioDiagnostics()
        expected.callbackCount = 42
        await mock.setAudioDiagnosticsForTests(expected)
        let actual = await mock.audioDiagnostics()
        XCTAssertEqual(actual, expected)
    }

    func testVariableFramesBudgetAndHostTimeEstimate() {
        let counters = CallbackDiagnostics(sampleRate: 48000, limiterDelayFrames: 72, millisecondsPerTick: 1)
        counters.record(start: 10, end: 11, frames: 48, outputHostTime: 11)
        counters.record(start: 20, end: 24, frames: 96, outputHostTime: 23)
        counters.record(start: 30, end: 30, frames: 24, outputHostTime: nil)
        let result = counters.snapshot()
        XCTAssertEqual(result.callbackCount, 3)
        XCTAssertEqual(result.minFrames, 24)
        XCTAssertEqual(result.maxFrames, 96)
        XCTAssertEqual(result.lastFrames, 24)
        XCTAssertEqual(result.meanCallbackMilliseconds, 5.0 / 3, accuracy: 1e-12)
        XCTAssertEqual(result.maxCallbackMilliseconds, 4)
        XCTAssertEqual(result.meanBudgetRatio, 1)
        XCTAssertEqual(result.maxBudgetRatio, 2)
        XCTAssertEqual(result.overBufferBudgetCount, 1)
        XCTAssertEqual(result.outputHostTimeEstimateSamples, 2)
        XCTAssertEqual(result.outputHostTimeEstimateMisses, 1)
        XCTAssertEqual(result.limiterDelayFrames, 72)
    }

    func testInvalidTimeAndFramesAndFreshGeneration() throws {
        let counters = CallbackDiagnostics(sampleRate: 48000, limiterDelayFrames: 72, millisecondsPerTick: 1)
        counters.record(start: .max, end: 1, frames: 48, outputHostTime: 1)
        counters.record(start: 10, end: 9, frames: 48, outputHostTime: 9)
        counters.record(start: 10, end: 11, frames: 0, outputHostTime: 11)
        XCTAssertEqual(counters.snapshot().callbackCount, 0)
        counters.record(start: 10, end: 11, frames: 48, outputHostTime: 0)
        XCTAssertEqual(counters.snapshot().outputHostTimeEstimateSamples, 0)
        XCTAssertEqual(CallbackDiagnostics.increment(.max), .max)
        XCTAssertEqual(CallbackDiagnostics.increment(.max - 1), .max)
        let fresh = CallbackDiagnostics(sampleRate: 96000, limiterDelayFrames: 144).snapshot()
        XCTAssertEqual(fresh.callbackCount, 0)
        XCTAssertEqual(fresh.minFrames, 0)
        XCTAssertEqual(fresh.sampleRate, 96000)
        let decoded = try JSONDecoder().decode(AudioDiagnostics.self, from: JSONEncoder().encode(fresh))
        XCTAssertEqual(decoded, fresh)
    }

    func testInputCounterIsSeparateFromInvalidSampleGuard() throws {
        let limiter = try XCTUnwrap(NativePeakLimiter(sampleRate: 48000, maximumFrames: 128))
        var samples = [Float](repeating: 0, count: 128)
        samples[0] = .nan
        samples.withUnsafeMutableBufferPointer { limiter.process(left: $0.baseAddress!, right: nil, stride: 1, frames: 128) }
        XCTAssertEqual(limiter.inputOverCeilingCallbacks, 0)
        XCTAssertGreaterThan(limiter.guardedSamples, 0)
        samples = [Float](repeating: 0, count: 128)
        samples[0] = 2
        samples.withUnsafeMutableBufferPointer { limiter.process(left: $0.baseAddress!, right: nil, stride: 1, frames: 128) }
        XCTAssertEqual(limiter.inputOverCeilingCallbacks, 1)
        XCTAssertEqual(limiter.renderFailures, 0)
    }
}
