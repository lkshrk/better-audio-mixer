import XCTest
@testable import bam
import BamCore

final class PeakHoldTests: XCTestCase {
    func testRiseTracksNewMaximumImmediately() {
        var hold = PeakHold()
        hold.update(-30, at: 0)
        XCTAssertEqual(hold.peak, -30)
        hold.update(-12, at: 0.1)
        XCTAssertEqual(hold.peak, -12)
        hold.update(-40, at: 0.2)
        XCTAssertEqual(hold.peak, -12, "a lower level must not pull the held peak down")
    }

    func testHoldsForOneSecondAfterLastRise() {
        var hold = PeakHold()
        hold.update(-12, at: 10)
        hold.update(-60, at: 10.99)
        XCTAssertEqual(hold.peak, -12)
        hold.update(-60, at: 11.0)
        XCTAssertEqual(hold.peak, -12, accuracy: 0.001)
    }

    func testDecaysAtTwelveDBPerSecondAfterHold() {
        var hold = PeakHold()
        hold.update(-12, at: 0)
        hold.update(-60, at: 1.5)
        XCTAssertEqual(hold.peak, -18, accuracy: 0.001)
        hold.update(-60, at: 2.0)
        XCTAssertEqual(hold.peak, -24, accuracy: 0.001)
    }

    func testDecayNeverFallsBelowCurrentLevelOrFloor() {
        var hold = PeakHold()
        hold.update(-12, at: 0)
        hold.update(-20, at: 2.0)
        XCTAssertEqual(hold.peak, -20, accuracy: 0.001, "a level above the decayed peak becomes the new peak")
        hold.update(-200, at: 100)
        XCTAssertEqual(hold.peak, RMSMeter.floorDB)
    }

    func testFreshHoldSitsAtFloor() {
        XCTAssertEqual(PeakHold().peak, RMSMeter.floorDB)
    }
}

final class ReadoutTests: XCTestCase {
    func testDBLabelFormatsGain() {
        XCTAssertEqual(Readout.dbLabel(gain: 1), "0.0 dB")
        XCTAssertEqual(Readout.dbLabel(gain: 0.5), "−6.0 dB")
        XCTAssertEqual(Readout.dbLabel(gain: 0.24), "−12.4 dB")
        XCTAssertEqual(Readout.dbLabel(gain: 0), "−∞ dB")
        XCTAssertEqual(Readout.dbLabel(gain: 0.999), "0.0 dB")
    }
}
