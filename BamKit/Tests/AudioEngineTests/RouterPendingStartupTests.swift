import CoreAudio
import Foundation
import XCTest
import BamCore
@testable import AudioEngine

final class RouterPendingStartupTests: XCTestCase {
    override func tearDown() async throws {
        await CoreAudioEngine.setDeviceOpsForTests(nil)
    }

    func testUserUnmuteCannotReleaseEngineOwnedPendingRecovery() async {
        let writes = StartupCloseRecorder()
        await CoreAudioEngine.setDeviceOpsForTests((
            volume: { _ in 0.12 }, muted: { _ in true },
            setVolume: { _, _ in .applied },
            setMuted: { _, muted in writes.append("mute:\(muted)"); return .applied }
        ))
        let engine = await pendingEngine(StartupCloseRecorder())
        await engine.configureRecoveryForTests(config: BamConfig(), hooks: .init(
            outputUIDs: ["render"], willTearDown: {}, rebuild: { .ok }))
        await engine.trackStartedRouter(signature: "render|tap", outputUID: "render", deviceIDs: ["render": 11])
        await engine.performGuardedOutputRebuildForTests(uids: ["render"], unmute: true) { false }
        let desired = OutputDeviceState(uid: "render", deviceID: 0, volumes: [0: 0.12], mutes: [0: false])
        let restored = await engine.restoreOutputDeviceState(desired, restoreVolume: false, restoreMute: true)
        XCTAssertEqual(restored, .failed)
        let unmuted = await engine.setOutputMutedChecked(uid: "render", false)
        XCTAssertEqual(unmuted, .failed)
        await engine.setOutputMuted(uid: "render", false)
        XCTAssertTrue(writes.events.allSatisfy { $0 == "mute:true" })
        let intent = await engine.outputDeviceState(uid: "render")
        XCTAssertEqual(intent?.muted, false, "User intent is deferred, not lost")

        let ready = await engine.completeRouterStartup(formatsBefore: true, ready: true, formatsAfter: true)
        XCTAssertTrue(ready)
        await engine.performGuardedOutputRebuildForTests(uids: ["render"], unmute: true) { true }
        XCTAssertEqual(writes.events.last, "mute:false", "Recovery releases only after confirmed readiness")
    }

    private func pendingEngine(_ recorder: StartupCloseRecorder, destroyStatus: OSStatus = noErr) async -> CoreAudioEngine {
        let resources = RouterAggregate.IOResources(operations: .init(
            stop: { _, _ in recorder.append("stop"); return noErr },
            destroyIOProc: { _, _ in recorder.append("callback"); return noErr },
            destroyAggregate: { _ in recorder.append("aggregate"); return destroyStatus },
            isGone: { _ in false }))
        resources.aggregateID = 42
        resources.ioProcID = { _, _, _, _, _, _, _ in noErr }
        let engine = CoreAudioEngine()
        await engine.installRouterForTests(resources: resources)
        await engine.trackStartedRouter(signature: "render|tap", outputUID: "render",
                                        deviceIDs: ["capture": 10, "render": 11])
        return engine
    }

    func testReadinessTimeoutRetainsOwnershipAndLaterCallbackPromotesSameRouter() async {
        let closes = StartupCloseRecorder()
        let engine = await pendingEngine(closes)
        for _ in 0..<3 {
            let ready = await engine.completeRouterStartup(formatsBefore: true, ready: false, formatsAfter: true)
            XCTAssertFalse(ready)
            let diagnostics = await engine.audioDiagnostics()
            XCTAssertEqual(diagnostics?.isRunning, false)
            let hasRouter = await engine.hasRouterForTests()
            XCTAssertTrue(hasRouter)
            let state = await engine.routerStartupStateForTests()
            XCTAssertEqual(state.pending, "render|tap")
            XCTAssertEqual(state.deviceIDs, ["capture": 10, "render": 11])
            XCTAssertFalse(state.monitoring)
            let bound = await engine.boundOutputUID()
            XCTAssertEqual(bound, "render", "Pending actual output must participate in protection")
            XCTAssertTrue(closes.events.isEmpty, "Timeout must not stop, destroy, or rebuild the started aggregate")
        }

        let ready = await engine.completeRouterStartup(formatsBefore: true, ready: true, formatsAfter: true)
        XCTAssertTrue(ready)
        let diagnostics = await engine.audioDiagnostics()
        XCTAssertEqual(diagnostics?.isRunning, true)
        let state = await engine.routerStartupStateForTests()
        XCTAssertNil(state.pending)
        XCTAssertTrue(state.monitoring, "Health monitoring begins only after startup readiness")
        XCTAssertTrue(closes.events.isEmpty)
        let promotedAgain = await engine.completeRouterStartup(formatsBefore: true, ready: true, formatsAfter: true)
        XCTAssertFalse(promotedAgain, "A completed startup must not be promoted or rearm its monitor again")
    }

    func testIncompatibleFormatStillClosesPendingAggregateEvenWithoutCallback() async {
        for (before, ready, after) in [(false, false, false), (true, false, false), (true, true, false)] {
            let closes = StartupCloseRecorder()
            let engine = await pendingEngine(closes)
            let accepted = await engine.completeRouterStartup(formatsBefore: before, ready: ready, formatsAfter: after)
            XCTAssertFalse(accepted)
            XCTAssertEqual(closes.events, ["stop", "callback", "aggregate"])
            let hasRouter = await engine.hasRouterForTests()
            XCTAssertFalse(hasRouter)
            let state = await engine.routerStartupStateForTests()
            XCTAssertNil(state.pending)
            XCTAssertFalse(state.monitoring)
            let diagnostics = await engine.audioDiagnostics()
            XCTAssertEqual(diagnostics?.isRunning, false)
        }
    }

    func testFailedTeardownRetainsHandlesButCannotPromotePartiallyClosedRouter() async {
        let closes = StartupCloseRecorder()
        let engine = await pendingEngine(closes, destroyStatus: -1)
        let rejected = await engine.completeRouterStartup(formatsBefore: true, ready: false, formatsAfter: false)
        XCTAssertFalse(rejected)
        let hasRouter = await engine.hasRouterForTests()
        XCTAssertTrue(hasRouter, "Failed destruction must retain ownership")
        let state = await engine.routerStartupStateForTests()
        XCTAssertNil(state.pending, "A close attempt invalidates reuse even if HAL retains handles")
        let accepted = await engine.completeRouterStartup(formatsBefore: true, ready: true, formatsAfter: true)
        XCTAssertFalse(accepted)
        let diagnostics = await engine.audioDiagnostics()
        XCTAssertEqual(diagnostics?.isRunning, false)
    }
}

private final class StartupCloseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var events: [String] { lock.withLock { recorded } }
    func append(_ event: String) { lock.withLock { recorded.append(event) } }
}
