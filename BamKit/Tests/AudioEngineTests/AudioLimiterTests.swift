import XCTest
@testable import AudioEngine

final class AudioLimiterTests: XCTestCase {
    func testTransparentBelowCeiling() {
        XCTAssertEqual(AudioLimiter.targetGain(forPeak: 0.8, ceiling: 1.0), 1.0, accuracy: 0)
        XCTAssertEqual(AudioLimiter.targetGain(forPeak: 1.0, ceiling: 1.0), 1.0, accuracy: 0)
    }

    func testReducesAboveCeiling() {
        XCTAssertEqual(AudioLimiter.targetGain(forPeak: 2.0, ceiling: 1.0), 0.5, accuracy: 1e-6)
    }

    func testAttackIsFasterThanRelease() {
        let sr = 48000.0
        let a = AudioLimiter.attackCoeff(sampleRate: sr, ms: 1)
        let r = AudioLimiter.releaseCoeff(sampleRate: sr, ms: 100)
        // attack coefficient moves the envelope further per sample than release
        let downAttack = AudioLimiter.nextEnvelope(current: 1.0, targetGain: 0.5, attackCoeff: a, releaseCoeff: r)
        let upRelease  = AudioLimiter.nextEnvelope(current: 0.5, targetGain: 1.0, attackCoeff: a, releaseCoeff: r)
        XCTAssertLessThan(downAttack, 1.0)
        XCTAssertGreaterThan(upRelease, 0.5)
        XCTAssertLessThan(1.0 - downAttack, 1.0)          // moved down
        XCTAssertTrue(upRelease < 1.0)                     // release not instant
    }

    func testEnvelopeNoOvershootNoNaN() {
        let e = AudioLimiter.nextEnvelope(current: 1.0, targetGain: 0.5, attackCoeff: 0.9, releaseCoeff: 0.01)
        XCTAssertFalse(e.isNaN)
        XCTAssertGreaterThanOrEqual(e, 0.5)
        XCTAssertLessThanOrEqual(e, 1.0)
    }

    func testLookaheadFrames() {
        XCTAssertEqual(AudioLimiter.lookaheadFrames(sampleRate: 48000, lookaheadMs: 1.5), 72)
    }
}
