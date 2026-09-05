import XCTest
import BamCore
@testable import AudioEngine

final class RouterRecoveryGuardTests: XCTestCase {
    override func tearDown() async throws {
        await CoreAudioEngine.setDeviceOpsForTests(nil)
    }

    private func engine(_ calls: RecoveryRecorder, status: RouterStatus = .ok,
                        muteResult: OutputWriteResult = .applied,
                        volumeResult: OutputWriteResult = .applied,
                        uids: Set<String> = ["out"], initiallyMuted: Bool = false) async -> CoreAudioEngine {
        await CoreAudioEngine.setDeviceOpsForTests((
            volume: { _ in calls.volume }, muted: { _ in initiallyMuted },
            setVolume: { _, value in calls.record("volume:\(value)"); return volumeResult },
            setMuted: { _, muted in calls.record(muted ? "mute" : "unmute"); return muteResult }
        ))
        let engine = CoreAudioEngine()
        await engine.configureRecoveryForTests(config: BamConfig(sources: [], mixes: []), hooks: .init(
            outputUIDs: uids,
            willTearDown: { calls.record("teardown") },
            rebuild: { calls.record("rebuild"); return status }
        ))
        return engine
    }

    func testRecoveryProtectsBeforeTeardownAndRestoresVolumeBeforeUnmute() async {
        let calls = RecoveryRecorder()
        let engine = await engine(calls)
        await engine.recoverRouterForTests(reason: .tapFormatDrift)
        XCTAssertEqual(calls.events, ["mute", "teardown", "rebuild", "volume:0.4", "unmute"])
    }

    func testFailedMuteAndMissingOutputNeverTearDown() async {
        for result in [OutputWriteResult.failed, .unsupported] {
            let calls = RecoveryRecorder()
            let engine = await engine(calls, muteResult: result)
            await engine.recoverRouterForTests(reason: .aggregateStalled)
            XCTAssertEqual(calls.events, ["mute"])
        }
        let calls = RecoveryRecorder()
        let engine = await engine(calls, uids: [])
        await engine.recoverRouterForTests(reason: .aggregateStalled)
        XCTAssertEqual(calls.events, [])
    }

    func testFailedBuildAndFailedVolumeRestoreNeverUnmute() async {
        for cause in [RouterFailureCause.buildFailed, .permissionPending, .noOutput] {
            let calls = RecoveryRecorder()
            let engine = await engine(calls, status: RouterStatus(cause: cause))
            await engine.recoverRouterForTests(reason: .aggregateStalled)
            XCTAssertEqual(calls.events, ["mute", "teardown", "rebuild"])
        }
        let calls = RecoveryRecorder()
        let engine = await engine(calls, volumeResult: .failed)
        await engine.recoverRouterForTests(reason: .aggregateStalled)
        XCTAssertEqual(calls.events, ["mute", "teardown", "rebuild", "volume:0.4"])
    }

    func testPausedRecoveryKeepsProtectionAndRearmUsesOriginalIntent() async {
        let calls = RecoveryRecorder()
        let engine = await engine(calls, status: RouterStatus(cause: .buildFailed))
        for _ in 0..<3 { await engine.recoverRouterForTests(reason: .aggregateStalled) }
        calls.reset()
        await engine.recoverRouterForTests(reason: .aggregateStalled)
        XCTAssertEqual(calls.events, ["mute", "teardown"])
        // HAL may reset the scalar while protected. Retain the original target.
        calls.volume = 1
        await engine.configureRecoveryForTests(config: BamConfig(sources: [], mixes: []), hooks: .init(
            outputUIDs: ["out"], willTearDown: {}, rebuild: { calls.record("rebuild"); return .ok }
        ))
        calls.reset()
        await engine.resetRouterRecovery() // Represents the cooldown budget becoming available again.
        await engine.retryAfterRearmForTests(reason: .aggregateStalled)
        XCTAssertEqual(calls.events, ["mute", "rebuild", "volume:0.4", "unmute"])
        await engine.resetRouterRecovery()
    }

    func testTransientRebuildFailureRetriesWithoutAnyExternalEvent() async throws {
        let calls = RecoveryRecorder()
        let engine = await engine(calls)
        await engine.configureRecoveryForTests(config: BamConfig(sources: [], mixes: []), hooks: .init(
            outputUIDs: ["out"], willTearDown: { calls.record("teardown") }, rebuild: {
                calls.record("rebuild")
                return calls.events.filter { $0 == "rebuild" }.count == 1 ? RouterStatus(cause: .buildFailed) : .ok
            }
        ))
        await engine.recoverRouterForTests(reason: .aggregateStalled)
        for _ in 0..<200 {
            if calls.events.contains("unmute") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(calls.events, ["mute", "teardown", "rebuild", "mute", "teardown", "rebuild", "volume:0.4", "unmute"])
        await engine.resetRouterRecovery()
    }

    func testExplicitRestoreAcknowledgementClearsIntentEvenWhileMuted() async {
        let calls = RecoveryRecorder()
        let engine = await engine(calls, status: RouterStatus(cause: .buildFailed))
        await engine.recoverRouterForTests(reason: .aggregateStalled)
        calls.volume = 0.6
        let retained = await engine.outputVolume(uid: "out")
        XCTAssertEqual(retained, 0.4)
        _ = await engine.setOutputMutedChecked(uid: "out", true)
        await engine.acknowledgeOutputRestore(uids: ["out"])
        let current = await engine.outputVolume(uid: "out")
        XCTAssertEqual(current, 0.6)
        await engine.resetRouterRecovery()
    }

    func testScheduledRecoveryWaitsForExternalGuardAndResumesWithoutLosingWork() async {
        let calls = RecoveryRecorder()
        let engine = await engine(calls, status: RouterStatus(cause: .buildFailed))
        await engine.recoverRouterForTests(reason: .aggregateStalled)
        await engine.setRouterRecoverySuspended(true)
        await engine.configureRecoveryForTests(config: BamConfig(sources: [], mixes: []), hooks: .init(
            outputUIDs: ["out"], willTearDown: { calls.record("teardown") }, rebuild: { calls.record("rebuild"); return .ok }
        ))
        calls.reset()
        await engine.retryAfterRearmForTests(reason: .aggregateStalled)
        XCTAssertTrue(calls.events.isEmpty)
        await engine.setRouterRecoverySuspended(false)
        XCTAssertEqual(calls.events, ["mute", "teardown", "rebuild", "volume:0.4", "unmute"])
        await engine.resetRouterRecovery()
    }

    func testPreviouslyMutedOutputStaysMuted() async {
        let calls = RecoveryRecorder()
        let engine = await engine(calls, initiallyMuted: true)
        await engine.recoverRouterForTests(reason: .aggregateStalled)
        XCTAssertEqual(calls.events, ["mute", "teardown", "rebuild", "volume:0.4"])
    }
}

private final class RecoveryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    private var storedVolume: Float = 0.4
    var volume: Float {
        get { lock.lock(); defer { lock.unlock() }; return storedVolume }
        set { lock.lock(); defer { lock.unlock() }; storedVolume = newValue }
    }
    var events: [String] { lock.lock(); defer { lock.unlock() }; return entries }
    func record(_ event: String) { lock.lock(); defer { lock.unlock() }; entries.append(event) }
    func reset() { lock.lock(); defer { lock.unlock() }; entries = [] }
}
