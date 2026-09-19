import XCTest
import CoreAudio
import BamCore
@testable import AudioEngine

/// Real-HAL router lifecycle and confirmed output writes. Opt-in via `BAM_LIVE=1`
/// (see `LiveTestGate`); every test restores the captured output state on teardown.
final class LiveRouterTests: XCTestCase {
    private let readyTimeout: Duration = .seconds(8)
    private let lowVolume: Float = 0.10

    override func setUp() async throws {
        try LiveTestGate.require()
    }

    private func defaultOutput(_ engine: CoreAudioEngine) async throws -> (uid: String, state: OutputDeviceState) {
        guard let uid = ProcessEnumerator.defaultOutputDeviceUID() else { throw XCTSkip("No default output device.") }
        return (uid, try await captureOutput(engine, uid: uid))
    }

    private func routedConfig(uid: String, bundleID: String) -> BamConfig {
        BamConfig(
            sources: [Source(id: "a", name: "A", bundleIDs: [bundleID])],
            mixes: [Mix(id: "live", name: "Live", dest: .hardware(uid: uid), sends: [Send(source: "a")])],
            pans: ["a": 0.5]
        )
    }

    private func firstPlayingProcess() throws -> AudioProcessInfo {
        guard let process = liveOutputProcesses().first else {
            throw XCTSkip("Play audio in any app before running the live router tests.")
        }
        return process
    }

    private func stopAndRestore(_ engine: CoreAudioEngine, _ captured: OutputDeviceState) {
        addTeardownBlock {
            guard await engine.stopRouterChecked() else { throw LiveProtectionError.unavailable }
            try await Self.restoreOutput(engine, [captured])
        }
    }

    func testRouterBecomesReadyAndReusesAggregateAcrossTopologyEdit() async throws {
        let engine = CoreAudioEngine()
        let (uid, captured) = try await defaultOutput(engine)
        let first = try firstPlayingProcess()
        let second = liveOutputProcesses().first { $0.bundleID != first.bundleID }?.bundleID
            ?? "me.harke.bam.live-test.absent"
        var config = routedConfig(uid: uid, bundleID: first.bundleID)
        stopAndRestore(engine, captured)

        let started = try await applyProtected(engine, config: config, uid: uid, intended: captured, timeout: readyTimeout)
        XCTAssertEqual(started.cause, .ok, "router did not become ready within 8 s: \(started)")
        let initialID = await engine.routerAggregateIDForTests()
        XCTAssertNotNil(initialID)
        XCTAssertNotEqual(initialID, AudioObjectID(kAudioObjectUnknown))
        let initialDiagnostics = await engine.audioDiagnostics()
        let initial = try XCTUnwrap(initialDiagnostics)

        config.mixes[0].sends[0].level = 0.5
        let gain = try await applyProtected(engine, config: config, uid: uid, intended: captured, timeout: readyTimeout)
        XCTAssertEqual(gain.cause, .ok)
        let gainID = await engine.routerAggregateIDForTests()
        XCTAssertEqual(gainID, initialID, "gain-only edit must refold gains on the live aggregate")
        let gainDiagnostics = await engine.audioDiagnostics()
        let afterGain = try XCTUnwrap(gainDiagnostics)
        XCTAssertEqual(afterGain.aggregateBuildAttempts, initial.aggregateBuildAttempts, "gain-only edit must not rebuild")

        config.sources.append(Source(id: "b", name: "B", bundleIDs: [second]))
        config.mixes[0].sends.append(Send(source: "b"))
        config.pans["b"] = 0.5
        let topology = try await applyProtected(engine, config: config, uid: uid, intended: captured, timeout: readyTimeout)
        XCTAssertEqual(topology.cause, .ok, "router did not become ready again within 8 s after adding \(second): \(topology)")
        let topologyID = await engine.routerAggregateIDForTests()
        let topologyDiagnostics = await engine.audioDiagnostics()
        let afterTopology = try XCTUnwrap(topologyDiagnostics)
        if topologyID == initialID {
            XCTAssertEqual(afterTopology.aggregateBuildAttempts, initial.aggregateBuildAttempts,
                           "topology edit reused aggregate \(initialID ?? 0) (tap cache hit), so no rebuild may be counted")
        } else {
            XCTAssertEqual(afterTopology.aggregateBuildAttempts, initial.aggregateBuildAttempts + 1,
                           "topology edit rebuilt aggregate \(initialID ?? 0) -> \(topologyID ?? 0): exactly one rebuild expected")
            XCTAssertEqual(afterTopology.aggregateBuildSuccesses, initial.aggregateBuildSuccesses + 1)
            XCTAssertEqual(afterTopology.aggregateBuildFailures, initial.aggregateBuildFailures)
        }
    }

    func testConfirmedVolumeWriteLandsWithinQuantizationTolerance() async throws {
        let engine = CoreAudioEngine()
        let (uid, captured) = try await defaultOutput(engine)
        addTeardownBlock { try await Self.restoreOutput(engine, [captured]) }

        let first = await engine.setOutputVolumeChecked(uid: uid, lowVolume)
        XCTAssertEqual(first, .applied)
        let firstRead = await engine.outputVolume(uid: uid)
        XCTAssertTrue(CA.volumeLanded(firstRead, target: lowVolume),
                      "readback \(String(describing: firstRead)) is outside ±\(CA.volumeLandingTolerance) of \(lowVolume)")

        let started = ContinuousClock.now
        let second = await engine.setOutputVolumeChecked(uid: uid, 0.06)
        let elapsed = ContinuousClock.now - started
        XCTAssertLessThan(elapsed, .seconds(2), "second write must be issued inside the settle window to test the latch")
        XCTAssertEqual(second, .applied, "a confirmed write must not latch the device against the next write")
        let secondRead = await engine.outputVolume(uid: uid)
        XCTAssertTrue(CA.volumeLanded(secondRead, target: 0.06),
                      "readback \(String(describing: secondRead)) is outside ±\(CA.volumeLandingTolerance) of 0.06")
    }

    func testMuteUnmuteRoundTripLeavesDeviceUnmuted() async throws {
        let engine = CoreAudioEngine()
        let (uid, captured) = try await defaultOutput(engine)
        addTeardownBlock { try await Self.restoreOutput(engine, [captured]) }

        let lowered = await engine.setOutputVolumeChecked(uid: uid, lowVolume)
        XCTAssertEqual(lowered, .applied)
        let muted = await engine.setOutputMutedChecked(uid: uid, true)
        XCTAssertEqual(muted, .applied)
        let mutedState = await engine.outputMuteState(uid: uid)
        XCTAssertEqual(mutedState, true)
        let unmuted = await engine.setOutputMutedChecked(uid: uid, false)
        XCTAssertEqual(unmuted, .applied)
        let unmutedState = await engine.outputMuteState(uid: uid)
        XCTAssertEqual(unmutedState, false)
        let volume = await engine.outputVolume(uid: uid)
        XCTAssertTrue(CA.volumeLanded(volume, target: lowVolume), "volume drifted to \(String(describing: volume)) across the round trip")
    }

    func testStopLeavesHardwareInCapturedState() async throws {
        let engine = CoreAudioEngine()
        let (uid, captured) = try await defaultOutput(engine)
        let first = try firstPlayingProcess()
        let config = routedConfig(uid: uid, bundleID: first.bundleID)
        stopAndRestore(engine, captured)

        let started = try await applyProtected(engine, config: config, uid: uid, intended: captured, timeout: readyTimeout)
        XCTAssertEqual(started.cause, .ok, "router did not become ready within 8 s: \(started)")

        await engine.stop()
        let mutedDuringStop = await engine.outputMuteState(uid: uid)
        XCTAssertEqual(mutedDuringStop, true, "stop() protects the output before destroying the aggregate")
        let hasRouter = await engine.hasRouterForTests()
        XCTAssertFalse(hasRouter)

        try await Self.restoreOutput(engine, [captured])
        let finalState = await engine.outputDeviceState(uid: uid)
        let final = try XCTUnwrap(finalState)
        XCTAssertEqual(final.muted, captured.muted)
        XCTAssertEqual(final.mutes, captured.mutes)
        for (element, volume) in captured.volumes {
            XCTAssertEqual(final.volumes[element] ?? -1, volume, accuracy: CA.volumeLandingTolerance,
                           "element \(element) did not return to its captured level")
        }
    }
}
