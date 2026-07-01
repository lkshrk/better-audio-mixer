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
        XCTAssertGreaterThan(1.0 - downAttack, upRelease - 0.5)
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

    // Validates attack-fast / release-slow dynamics over a full block of samples,
    // not just a single step — confirms the time constants produce real convergence.
    func testEnvelopeConvergenceMultiStep() {
        let sr = 48000.0
        let a = AudioLimiter.attackCoeff(sampleRate: sr, ms: 1)
        let r = AudioLimiter.releaseCoeff(sampleRate: sr, ms: 100)
        // 400 samples covers ~8 attack time-constants (tau=48 samples @48k/1ms) — enough for tight convergence.
        let n = 400

        // Phase 1 — attack: env starts at 1.0, target is 0.5
        var env: Float = 1.0
        var prev = env
        for step in 0..<n {
            env = AudioLimiter.nextEnvelope(current: env, targetGain: 0.5, attackCoeff: a, releaseCoeff: r)
            XCTAssertFalse(env.isNaN, "NaN at attack step \(step)")
            XCTAssertLessThanOrEqual(env, prev, "not monotonically decreasing at step \(step)")
            XCTAssertGreaterThanOrEqual(env, 0.5, "undershot target at step \(step)")
            prev = env
        }
        // 8 time-constants in: must be within 2e-4 of 0.5
        XCTAssertLessThan(abs(env - 0.5), 2e-4, "attack did not converge: env=\(env)")
        let settledEnv = env

        // Phase 2 — release: from settled ~0.5, target is 1.0 (100ms >> 1ms, must be much slower)
        env = settledEnv
        prev = env
        for step in 0..<n {
            env = AudioLimiter.nextEnvelope(current: env, targetGain: 1.0, attackCoeff: a, releaseCoeff: r)
            XCTAssertFalse(env.isNaN, "NaN at release step \(step)")
            XCTAssertGreaterThanOrEqual(env, prev, "not monotonically increasing at step \(step)")
            XCTAssertLessThanOrEqual(env, 1.0, "overshot ceiling at step \(step)")
            prev = env
        }
        // After the same 400 steps that settled the attack, release must NOT yet reach 0.99 —
        // 100ms time-constant means only ~0.8% elapsed, so env should still be well below 0.60.
        XCTAssertLessThan(env, 0.60, "release too fast: env=\(env) after \(n) steps")
    }
}
