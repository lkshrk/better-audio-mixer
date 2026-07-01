import XCTest
@testable import BamCore

final class RouterRecoveryPolicyTests: XCTestCase {
    func testAllowsAttemptsUntilWindowLimitThenPauses() {
        var policy = RouterRecoveryPolicy(maxAttempts: 3, window: 120, cooldown: 300)
        let start = Date(timeIntervalSince1970: 1_000)

        XCTAssertEqual(policy.recordAttempt(reason: .sourceTapStalled, now: start), .attempting(
            reason: "sourceTapStalled",
            attempt: 1
        ))
        XCTAssertEqual(policy.recordAttempt(reason: .sourceTapStalled, now: start.addingTimeInterval(20)), .attempting(
            reason: "sourceTapStalled",
            attempt: 2
        ))
        XCTAssertEqual(policy.recordAttempt(reason: .sourceTapStalled, now: start.addingTimeInterval(40)), .attempting(
            reason: "sourceTapStalled",
            attempt: 3
        ))
        XCTAssertEqual(policy.recordAttempt(reason: .sourceTapStalled, now: start.addingTimeInterval(60)), .paused(
            reason: "sourceTapStalled",
            attempts: 3,
            window: 120,
            cooldown: 300
        ))
    }

    func testManualResetLeavesPauseAndStartsNewWindow() {
        var policy = RouterRecoveryPolicy(maxAttempts: 1, window: 120, cooldown: 300)
        let start = Date(timeIntervalSince1970: 1_000)

        _ = policy.recordAttempt(reason: .sourceTapStalled, now: start)
        XCTAssertEqual(policy.recordAttempt(reason: .sourceTapStalled, now: start.addingTimeInterval(10)), .paused(
            reason: "sourceTapStalled",
            attempts: 1,
            window: 120,
            cooldown: 300
        ))

        policy.reset()

        XCTAssertEqual(policy.recordAttempt(reason: .sourceTapStalled, now: start.addingTimeInterval(20)), .attempting(
            reason: "sourceTapStalled",
            attempt: 1
        ))
    }

    func testPerReasonBudgetsAreIndependent() {
        var p = RouterRecoveryPolicy(maxAttempts: 2, window: 100, cooldown: 300)
        let t0 = Date(timeIntervalSince1970: 0)

        _ = p.recordAttempt(reason: .outputFormatDrift, now: t0)
        _ = p.recordAttempt(reason: .outputFormatDrift, now: t0)
        let driftPaused = p.recordAttempt(reason: .outputFormatDrift, now: t0)
        guard case .paused = driftPaused else { XCTFail("expected paused"); return }

        let other = p.recordAttempt(reason: .aggregateStalled, now: t0)
        guard case .attempting(_, let attempt) = other else { XCTFail("expected attempting"); return }
        XCTAssertEqual(attempt, 1)
    }

    func testPausedUntilReportedPerReason() {
        var p = RouterRecoveryPolicy(maxAttempts: 1, window: 100, cooldown: 300)
        let t0 = Date(timeIntervalSince1970: 0)
        _ = p.recordAttempt(reason: .aggregateStalled, now: t0)
        let paused = p.recordAttempt(reason: .aggregateStalled, now: t0)
        guard case .paused = paused else { XCTFail("expected paused"); return }
        XCTAssertEqual(p.pausedUntil(for: .aggregateStalled), t0.addingTimeInterval(300))
        XCTAssertNil(p.pausedUntil(for: .outputFormatDrift))
    }

    func testResetClearsAllReasons() {
        var p = RouterRecoveryPolicy(maxAttempts: 1, window: 100, cooldown: 300)
        let t0 = Date(timeIntervalSince1970: 0)
        _ = p.recordAttempt(reason: .aggregateStalled, now: t0)
        _ = p.recordAttempt(reason: .aggregateStalled, now: t0)
        p.reset()
        let after = p.recordAttempt(reason: .aggregateStalled, now: t0)
        guard case .attempting = after else { XCTFail("expected attempting after reset"); return }
        XCTAssertNil(p.pausedUntil(for: .aggregateStalled))
    }
}
