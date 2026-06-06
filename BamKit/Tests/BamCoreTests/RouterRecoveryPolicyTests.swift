import XCTest
@testable import BamCore

final class RouterRecoveryPolicyTests: XCTestCase {
    func testAllowsAttemptsUntilWindowLimitThenPauses() {
        var policy = RouterRecoveryPolicy(maxAttempts: 3, window: 120, cooldown: 300)
        let start = Date(timeIntervalSince1970: 1_000)

        XCTAssertEqual(policy.recordAttempt(reason: "source tap stalled", now: start), .attempting(
            reason: "source tap stalled",
            attempt: 1
        ))
        XCTAssertEqual(policy.recordAttempt(reason: "source tap stalled", now: start.addingTimeInterval(20)), .attempting(
            reason: "source tap stalled",
            attempt: 2
        ))
        XCTAssertEqual(policy.recordAttempt(reason: "source tap stalled", now: start.addingTimeInterval(40)), .attempting(
            reason: "source tap stalled",
            attempt: 3
        ))
        XCTAssertEqual(policy.recordAttempt(reason: "source tap stalled", now: start.addingTimeInterval(60)), .paused(
            reason: "source tap stalled",
            attempts: 3,
            window: 120,
            cooldown: 300
        ))
    }

    func testManualResetLeavesPauseAndStartsNewWindow() {
        var policy = RouterRecoveryPolicy(maxAttempts: 1, window: 120, cooldown: 300)
        let start = Date(timeIntervalSince1970: 1_000)

        _ = policy.recordAttempt(reason: "silent render", now: start)
        XCTAssertEqual(policy.recordAttempt(reason: "silent render", now: start.addingTimeInterval(10)), .paused(
            reason: "silent render",
            attempts: 1,
            window: 120,
            cooldown: 300
        ))

        policy.reset()

        XCTAssertEqual(policy.recordAttempt(reason: "silent render", now: start.addingTimeInterval(20)), .attempting(
            reason: "silent render",
            attempt: 1
        ))
    }
}
