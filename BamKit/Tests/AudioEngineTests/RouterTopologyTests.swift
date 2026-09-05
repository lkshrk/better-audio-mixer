import XCTest
import BamCore
import CoreAudio
@testable import AudioEngine

final class RouterTopologyTests: XCTestCase {
    private let config = BamConfig(sources: [
        Source(id: "app", name: "App", kind: .app, bundleIDs: ["example.app"]),
        Source(id: "rest", name: "Other", kind: .rest)
    ], mixes: [])

    private func process(_ id: AudioObjectID, _ bundle: String) -> AudioProcessInfo {
        AudioProcessInfo(objectID: id, pid: pid_t(id), bundleID: bundle, isRunningOutput: true, deviceIDs: [])
    }

    func testUnrelatedProcessDoesNotChangeActualDesiredSpecs() {
        let processes = [process(1, "example.app")]
        let before = CoreAudioEngine.desiredTapSpecs(config: config, processes: processes, captureUID: "out", selfObjectID: 9)
        let after = CoreAudioEngine.desiredTapSpecs(config: config, processes: processes + [process(2, "unrelated")], captureUID: "out", selfObjectID: 9)
        XCTAssertEqual(before, after)
        XCTAssertEqual(before.last?.processIDs, [1, 9])
    }

    func testHelperChurnCaptureChangeAndSelfChangeInvalidateSpecs() {
        let processes = [process(1, "example.app")]
        let before = CoreAudioEngine.desiredTapSpecs(config: config, processes: processes, captureUID: "out", selfObjectID: 9)
        let helper = CoreAudioEngine.desiredTapSpecs(config: config, processes: processes + [process(2, "example.app.helper")], captureUID: "out", selfObjectID: 9)
        XCTAssertNotEqual(before.first?.sig, helper.first?.sig)
        XCTAssertNotEqual(before.last?.sig, helper.last?.sig)
        XCTAssertNotEqual(before, CoreAudioEngine.desiredTapSpecs(config: config, processes: processes, captureUID: "new", selfObjectID: 9))
        XCTAssertNotEqual(before, CoreAudioEngine.desiredTapSpecs(config: config, processes: processes, captureUID: "out", selfObjectID: 10))
    }

    func testUnknownRouterCannotBypassGuard() async {
        let result = await CoreAudioEngine().canKeepCurrentRouter(config: config)
        XCTAssertFalse(result)
    }

    func testProductionEligibilityRejectsOldGenerationStaleHealthAndIncompleteTopology() {
        let now = ContinuousClock.now
        let formats = ["app": CoreAudioEngine.SourceFormat(sampleRate: 48_000, channels: 2)]
        func eligible(generation: Int? = 2, observed: ContinuousClock.Instant? = now,
                      devices: [String: AudioObjectID] = ["out": 1],
                      sources: [String: CoreAudioEngine.SourceFormat]? = nil,
                      taps: [String: String] = ["app": "sig"]) -> Bool {
            CoreAudioEngine.canKeepRouterTopology(
                desired: taps, live: ["app": "sig"], currentDevices: devices, appliedDevices: ["out": 1],
                currentFormats: sources ?? formats, appliedFormats: formats,
                generation: 2, healthyGeneration: generation, observedAt: observed, now: now)
        }
        XCTAssertTrue(eligible())
        XCTAssertFalse(eligible(generation: 1))
        XCTAssertFalse(eligible(generation: nil))
        XCTAssertFalse(eligible(observed: nil))
        XCTAssertFalse(eligible(observed: now.advanced(by: .seconds(-4))))
        XCTAssertFalse(eligible(devices: ["out": 2]), "same UID/new HAL object requires tap and aggregate rebuild")
        XCTAssertFalse(eligible(devices: [:]))
        XCTAssertFalse(eligible(sources: [:]))
        XCTAssertFalse(eligible(sources: ["app": .init(sampleRate: 44_100, channels: 2)]))
        XCTAssertFalse(eligible(sources: ["app": .init(sampleRate: 48_000, channels: 1)]))
        XCTAssertFalse(eligible(taps: ["app": "new-process"]))
    }

    func testPreviouslyStaleSourceBecomingIdleDoesNotPoisonFutureHealth() {
        var health = CoreAudioEngine.RouterHealthState()
        health.sourceStaleSamples = ["idle": 2, "playing": 0]
        health.lastSourceFrames = ["idle": 10, "playing": 20]
        health.retainExpectedSources(["playing"])
        XCTAssertEqual(health.sourceStaleSamples, ["playing": 0])
        XCTAssertEqual(health.lastSourceFrames, ["playing": 20])
        XCTAssertTrue(health.sourceStaleSamples.values.allSatisfy { $0 == 0 })
    }
}
