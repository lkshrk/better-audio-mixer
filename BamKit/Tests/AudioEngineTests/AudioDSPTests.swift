import XCTest
@testable import AudioEngine
import BamCore

final class AudioDSPTests: XCTestCase {
    private func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sumSquares: Float = 0
        for sample in samples { sumSquares += sample * sample }
        return (sumSquares / Float(samples.count)).squareRoot()
    }

    func testBalanceKeepsCenterAtUnityAndAttenuatesOppositeSide() {
        XCTAssertEqual(AudioBalance.gains(pan: 0.5).left, 1, accuracy: 1e-4)
        XCTAssertEqual(AudioBalance.gains(pan: 0.5).right, 1, accuracy: 1e-4)
        XCTAssertEqual(AudioBalance.gains(pan: 0).left, 1, accuracy: 1e-4)
        XCTAssertEqual(AudioBalance.gains(pan: 0).right, 0, accuracy: 1e-4)
        XCTAssertEqual(AudioBalance.gains(pan: 1).left, 0, accuracy: 1e-4)
        XCTAssertEqual(AudioBalance.gains(pan: 1).right, 1, accuracy: 1e-4)
    }

    func testCenteredLowFrequencySinePreservesRMS() {
        let frames = 480
        let freq: Float = 80
        let sr: Float = 48_000
        let gains = AudioBalance.gains(pan: 0.5)
        var input = [Float](repeating: 0, count: frames)
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)

        for f in 0..<frames {
            let v = sin(2 * Float.pi * freq * Float(f) / sr) * 0.5
            input[f] = v
            left[f] = v * gains.left
            right[f] = v * gains.right
        }

        XCTAssertEqual(rms(left), rms(input), accuracy: 1e-5)
        XCTAssertEqual(rms(right), rms(input), accuracy: 1e-5)
    }

    func testLimiterLeavesBelowFullScaleAloneAndScalesOverflow() {
        XCTAssertEqual(AudioLimiter.scale(forPeak: 0.8), 1, accuracy: 1e-6)
        XCTAssertEqual(AudioLimiter.scale(forPeak: 1.0), 1, accuracy: 1e-6)
        XCTAssertEqual(AudioLimiter.scale(forPeak: 2.0), 0.5, accuracy: 1e-6)
    }

    func testLimiterAttacksImmediatelyAndReleasesSmoothly() {
        XCTAssertEqual(AudioLimiter.nextScale(current: 1, target: 0.5), 0.5, accuracy: 1e-6)
        XCTAssertEqual(AudioLimiter.nextScale(current: 0.5, target: 1), 0.505, accuracy: 1e-6)
        XCTAssertEqual(AudioLimiter.nextScale(current: 0.5, target: 1, release: 1), 1, accuracy: 1e-6)
    }

    func testTapCaptureFollowsMacOSDefaultNotBamRenderTarget() {
        XCTAssertEqual(
            CoreAudioEngine.tapCaptureOutputUID(targetOutputUID: "Speakers", defaultOutputUID: "Razer"),
            "Razer"
        )
        XCTAssertEqual(
            CoreAudioEngine.tapCaptureOutputUID(targetOutputUID: "Speakers", defaultOutputUID: nil),
            "Speakers"
        )
    }

    func testMixIDsReferencingFailedTapSourcesOnlyMarksAffectedMixes() {
        let config = BamConfig(
            sources: [
                Source(id: "browser", name: "Browser", kind: .app, bundleIDs: ["com.browser"]),
                Source(id: "music", name: "Music", kind: .app, bundleIDs: ["com.music"]),
            ],
            mixes: [
                Mix(id: "chat", name: "Chat", dest: .virtualSlot(0), sends: [Send(source: "browser")]),
                Mix(id: "stream", name: "Stream", dest: .virtualSlot(1), sends: [Send(source: "browser"), Send(source: "music")]),
                Mix(id: "music-only", name: "Music", dest: .virtualSlot(2), sends: [Send(source: "music")]),
            ]
        )

        XCTAssertEqual(
            CoreAudioEngine.mixIDs(referencing: ["browser"], in: config),
            ["chat", "stream"]
        )
    }
}
