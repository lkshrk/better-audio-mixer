import Testing
import Foundation
@testable import BamCore

@Suite struct RMSMeterTests {
    @Test func silenceFloors() {
        #expect(RMSMeter.dbFS(samples: [Float](repeating: 0, count: 512)) == RMSMeter.floorDB)
        #expect(RMSMeter.dbFS(samples: []) == RMSMeter.floorDB)
    }

    @Test func fullScaleSineIsAboutMinus3dB() {
        let n = 4096
        var buf = [Float](repeating: 0, count: n)
        for i in 0..<n {
            buf[i] = sin(2 * .pi * Float(i) / Float(n))
        }
        let db = RMSMeter.dbFS(samples: buf)
        #expect(abs(db - (-3.01)) < 0.1)
    }

    @Test func dcFullScaleIsZeroDB() {
        let buf = [Float](repeating: 1.0, count: 256)
        #expect(abs(RMSMeter.dbFS(samples: buf) - 0) < 0.001)
    }

    @Test func combineEmptyFloors() {
        #expect(RMSMeter.combine([]) == RMSMeter.floorDB)
    }

    @Test func combineTwoEqualSourcesAddsPower() {
        let one = RMSMeter.combine([-6.0])
        let two = RMSMeter.combine([-6.0, -6.0])
        #expect(abs((two - one) - 3.01) < 0.1)
    }

    @Test func fractionClampsBelowFloor() {
        #expect(RMSMeter.fraction(dbFS: -120, minDB: -60) == 0)
        #expect(abs(RMSMeter.fraction(dbFS: 0, minDB: -60) - 1) < 0.001)
        #expect(abs(RMSMeter.fraction(dbFS: -30, minDB: -60) - 0.5) < 0.001)
    }
}
