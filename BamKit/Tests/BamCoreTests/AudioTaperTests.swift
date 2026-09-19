import Testing
@testable import BamCore

@Suite struct AudioTaperTests {
    @Test func gainIsMonotonicOverFaderTravel() {
        var previous = -1.0
        for step in 0...1000 {
            let gain = AudioTaper.gain(fromPosition: Double(step) / 1000)
            #expect(gain >= previous)
            previous = gain
        }
        #expect(AudioTaper.gain(fromPosition: 0) == 0)
        #expect(AudioTaper.gain(fromPosition: 1) == 1)
    }

    @Test func positionRoundTripsThroughGain() {
        for step in 0...100 {
            let position = Double(step) / 100
            let back = AudioTaper.position(fromGain: AudioTaper.gain(fromPosition: position))
            #expect(abs(back - position) < 1e-9)
        }
    }

    @Test func inputsAreClampedToUnitRange() {
        #expect(AudioTaper.gain(fromPosition: 2) == 1)
        #expect(AudioTaper.gain(fromPosition: -1) == 0)
        #expect(AudioTaper.position(fromGain: 2) == 1)
        #expect(AudioTaper.position(fromGain: -1) == 0)
    }

    @Test func percentFollowsPosition() {
        #expect(AudioTaper.percent(fromGain: 0) == 0)
        #expect(AudioTaper.percent(fromGain: 1) == 100)
        #expect(AudioTaper.percent(fromGain: AudioTaper.gain(fromPosition: 0.5)) == 50)
    }
}
