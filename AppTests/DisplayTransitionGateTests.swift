import XCTest
@testable import bam

@MainActor
final class DisplayTransitionGateTests: XCTestCase {
    private final class Clock {
        var waiting = 0
        var released = false
        func fire() { released = true }
        var isEmpty: Bool { waiting == 0 }
    }

    private func gate(_ events: Recorder, _ clock: Clock) -> DisplayTransitionGate {
        DisplayTransitionGate(
            sleep: { _ in
                clock.waiting += 1
                defer { clock.waiting -= 1 }
                while !clock.released {
                    try Task.checkCancellation()
                    try await Task.sleep(for: .milliseconds(5))
                }
            },
            onBegin: { events.log.append("begin") },
            onEnd: { events.log.append("end") })
    }

    private final class Recorder { var log: [String] = [] }

    private func settle() async {
        try? await Task.sleep(for: .milliseconds(40))
    }

    func testOverlappingReasonsYieldOneBeginAndOneEndAfterTheLastCloses() async {
        let events = Recorder(), clock = Clock()
        let gate = gate(events, clock)
        gate.begin(.reconfiguring)
        gate.begin(.screensAsleep)
        gate.end(.reconfiguring)
        await settle()
        XCTAssertTrue(clock.isEmpty, "an open reason must not start the settle timer")
        gate.end(.screensAsleep)
        await settle()
        clock.fire()
        await settle()
        XCTAssertEqual(events.log, ["begin", "end"])
        XCTAssertFalse(gate.isActive)
    }

    func testBeginDuringSettleCancelsTheEnd() async {
        let events = Recorder(), clock = Clock()
        let gate = gate(events, clock)
        gate.begin(.reconfiguring)
        gate.end(.reconfiguring)
        await settle()
        gate.begin(.reconfiguring)
        clock.fire()
        await settle()
        XCTAssertEqual(events.log, ["begin"], "a burst of reconfigure callbacks stays one transition")
        XCTAssertTrue(gate.isActive)
    }

    func testEndWithoutBeginIsIgnored() async {
        let events = Recorder(), clock = Clock()
        let gate = gate(events, clock)
        gate.end(.locked)
        await settle()
        XCTAssertTrue(clock.isEmpty)
        XCTAssertEqual(events.log, [])
    }
}
