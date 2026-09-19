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
        AudioProcessInfo(objectID: id, pid: pid_t(id), bundleID: bundle, isRunningOutput: true)
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

    func testConfiguredSourceSlotSurvivesExitAndFirstLaunch() {
        let idle = CoreAudioEngine.desiredTapSpecs(config: config, processes: [], captureUID: "out", selfObjectID: 9)
        let active = CoreAudioEngine.desiredTapSpecs(config: config, processes: [process(1, "example.app")], captureUID: "out", selfObjectID: 9)
        XCTAssertEqual(idle.map(\.sourceID), ["app", "rest"])
        XCTAssertEqual(idle.first?.processIDs, [])
        XCTAssertEqual(idle.last?.processIDs, [9])
        XCTAssertEqual(idle.map(\.structuralSignature), active.map(\.structuralSignature))
        XCTAssertNotEqual(idle.map(\.sig), active.map(\.sig), "membership changes still require protection")
    }

    func testMembershipUpdatePlanKeepsSourceSlotsAndRejectsStructuralChanges() {
        let before = CoreAudioEngine.desiredTapSpecs(config: config, processes: [process(1, "example.app")], captureUID: "out", selfObjectID: 9)
        let after = CoreAudioEngine.desiredTapSpecs(config: config, processes: [process(2, "example.app.helper")], captureUID: "out", selfObjectID: 9)
        let live = Dictionary(uniqueKeysWithValues: before.map { ($0.sourceID, $0) })
        XCTAssertEqual(CoreAudioEngine.membershipUpdates(desired: before, live: live), [])
        XCTAssertEqual(CoreAudioEngine.membershipUpdates(desired: after, live: live)?.map(\.sourceID), ["app", "rest"])
        XCTAssertNil(CoreAudioEngine.membershipUpdates(desired: Array(after.dropFirst()), live: live))
        let switched = CoreAudioEngine.desiredTapSpecs(config: config, processes: [], captureUID: "other", selfObjectID: 9)
        XCTAssertNil(CoreAudioEngine.membershipUpdates(desired: switched, live: live))
    }

    func testTapUpdatePreservesCaptureAndMuteContract() {
        let before = CATapDescription(processes: [1], deviceUID: "output", stream: 0)
        before.isPrivate = true
        before.muteBehavior = .mutedWhenTapped
        let after = CATapDescription(processes: [], deviceUID: "output", stream: 0)
        after.uuid = before.uuid
        after.isPrivate = true
        after.muteBehavior = .mutedWhenTapped
        XCTAssertTrue(ProcessTap.sameConfiguration(before, after))
        after.muteBehavior = .unmuted
        XCTAssertFalse(ProcessTap.sameConfiguration(before, after))
        after.muteBehavior = before.muteBehavior
        after.isExclusive = true
        XCTAssertFalse(ProcessTap.sameConfiguration(before, after))
        after.isExclusive = false
        after.deviceUID = "different-output"
        XCTAssertFalse(ProcessTap.sameConfiguration(before, after))
        after.deviceUID = before.deviceUID
        after.uuid = UUID()
        XCTAssertFalse(ProcessTap.sameConfiguration(before, after))
    }

    func testProductionEligibilityDefersUnknownHealthButRejectsChangedTopology() {
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
        XCTAssertTrue(eligible(generation: nil))
        XCTAssertTrue(eligible(observed: nil))
        XCTAssertTrue(eligible(observed: now.advanced(by: .seconds(-4))))
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

    func testNativeLimiterFailuresRequireTwoConsecutiveGrowingSamples() {
        var snapshot = RouterAggregate.HealthSnapshot(fires: 100, inputBuffers: 1, inputChannels: 2,
            inputFrames: 48_000, outputBuffers: 1, outputChannels: 2, outputFrames: 48_000,
            outputPeak: 0, limiterHits: 0)
        var state = CoreAudioEngine.RouterHealthState()
        XCTAssertTrue(snapshot.hasAdvancedIO)
        XCTAssertTrue(snapshot.hasExpectedInput)
        func observe(_ failures: Int) -> Bool {
            snapshot.limiterFailures = failures
            state.recordLimiterFailures(failures)
            return CoreAudioEngine.aggregateRecoveryRequired(snapshot: snapshot, state: state)
        }
        XCTAssertFalse(observe(0))
        XCTAssertFalse(observe(1), "a single transient failure never forces a protected teardown")
        XCTAssertFalse(observe(1), "a cumulative total that stops growing is not a live failure")
        XCTAssertFalse(observe(2))
        XCTAssertTrue(observe(3), "two consecutive growing samples require recovery")
        var fresh = CoreAudioEngine.RouterHealthState()
        fresh.recordLimiterFailures(5)
        XCTAssertEqual(fresh.limiterFailureSamples, 0, "the first sample only establishes the baseline")
    }

    func testFoldedGainsDriveAudibilityAndMatchTheRouterFold() {
        let config = BamConfig(master: 0.5, sources: [
            Source(id: "app", name: "App", kind: .app, bundleIDs: ["example.app"]),
            Source(id: "rest", name: "Other", kind: .rest),
        ], mixes: [
            Mix(id: "m", name: "Mix", dest: .virtualSlot(0), sends: [Send(source: "app", level: 0.8), Send(source: "rest", muted: true)]),
        ], pans: ["app": 0.25])
        let gains = CoreAudioEngine.foldedGains(config)
        XCTAssertEqual(gains["app"]?.left ?? 0, 0.4, accuracy: 1e-6)
        XCTAssertEqual(gains["app"]?.right ?? 0, 0.2, accuracy: 1e-6)
        XCTAssertEqual(gains["rest"]?.left, 0)
        let processes = [process(1, "example.app"), process(2, "other.app")]
        XCTAssertEqual(CoreAudioEngine.expectedAudibleSourceIDs(config: config, processes: processes, selfBundle: nil), ["app"])
        var soloed = config
        soloed.solo = "rest"
        XCTAssertEqual(CoreAudioEngine.expectedAudibleSourceIDs(config: soloed, processes: processes, selfBundle: nil), [])
    }

    func testMuteStateIsNilWhenAnyElementIsUnreadable() {
        XCTAssertEqual(CoreAudioEngine.muteState(main: 1, hasMain: true, channels: []), true)
        XCTAssertEqual(CoreAudioEngine.muteState(main: 0, hasMain: true, channels: []), false)
        XCTAssertNil(CoreAudioEngine.muteState(main: nil, hasMain: true, channels: []))
        XCTAssertNil(CoreAudioEngine.muteState(main: nil, hasMain: false, channels: []))
        XCTAssertEqual(CoreAudioEngine.muteState(main: nil, hasMain: false, channels: [1, 1]), true)
        XCTAssertEqual(CoreAudioEngine.muteState(main: nil, hasMain: false, channels: [1, 0]), false)
        XCTAssertNil(CoreAudioEngine.muteState(main: nil, hasMain: false, channels: [1, nil]))
    }
}
