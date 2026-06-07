import XCTest
@testable import bam
import BamCore

/// Cause-aware recovery: drives `ConsoleViewModel` through the `MockAudioEngine`
/// scripting hooks so the recovery logic is exercised without real CoreAudio.
@MainActor
final class RouterRecoveryTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "bam.recovery.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(true, forKey: ConsoleViewModel.driverKey)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func eventually(_ timeout: TimeInterval = 1.0, _ cond: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return cond()
    }

    private func eventuallyAsync(_ timeout: TimeInterval = 1.0, _ cond: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await cond() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await cond()
    }

    private func config(mix: String = "m0") -> BamConfig {
        BamConfig(
            sources: [Source(id: "s0", name: "App", kind: .app, bundleIDs: ["com.x"])],
            mixes: [Mix(id: mix, name: "Mix", dest: .virtualSlot(0), sends: [Send(source: "s0")])],
            pans: ["s0": 0.5]
        )
    }

    /// `noSourcesRunning` is idle, not broken: no mix should show offline.
    func testNoSourcesRunningIsNotOffline() async {
        let mock = MockAudioEngine()
        await mock.scriptRouterStatuses([RouterStatus(cause: .noSourcesRunning)])
        let model = ConsoleViewModel(engine: mock, defaults: defaults)
        await model.startMock(config: config())

        XCTAssertTrue(model.failedMixIDs.isEmpty, "idle router must not flag mixes offline")
        XCTAssertEqual(model.routerStatus.cause, .noSourcesRunning)
        XCTAssertFalse(model.routerStatus.isFailure)
        XCTAssertNil(model.routerStatusMessage)
        await model.stop()
    }

    /// `noOutput` is offline with a message, and a router event (device appeared)
    /// drives a retry that clears it — no polling involved.
    func testNoOutputRecoversOnDeviceEvent() async {
        let mock = MockAudioEngine()
        await mock.scriptRouterStatuses([
            RouterStatus(failedMixIDs: ["m0"], cause: .noOutput),
            .ok,
        ])
        let model = ConsoleViewModel(engine: mock, defaults: defaults)
        await model.startMock(config: config())

        XCTAssertEqual(model.failedMixIDs, ["m0"], "noOutput must mark the mix offline")
        XCTAssertEqual(model.routerStatus.cause, .noOutput)
        XCTAssertNotNil(model.routerStatusMessage)

        await mock.emitRouterEvent()   // a device appeared → recovery retries

        let healed = await eventually { model.failedMixIDs.isEmpty }
        XCTAssertTrue(healed, "device-list event should retry the router and clear offline")
        XCTAssertEqual(model.routerStatus.cause, .ok)
        await model.stop()
    }

    func testDiagnosticsSnapshotSummarizesRouterState() async {
        let mock = MockAudioEngine()
        await mock.scriptRouterStatuses([
            RouterStatus(failedMixIDs: ["m0"], cause: .noOutput),
        ])
        let model = ConsoleViewModel(engine: mock, defaults: defaults)
        await model.startMock(config: config())

        let diagnostics = await model.diagnosticsSnapshot()

        XCTAssertTrue(diagnostics.driverEnabled)
        XCTAssertEqual(diagnostics.routerCause, .noOutput)
        XCTAssertEqual(diagnostics.failedMixIDs, ["m0"])
        XCTAssertEqual(diagnostics.mixCount, 2)
        XCTAssertEqual(diagnostics.sourceCount, 2)
        XCTAssertEqual(diagnostics.audioRecoveryState, model.audioRecoveryDisplayState)
        XCTAssertEqual(diagnostics.boundOutputUID, "MockOutput")
        XCTAssertNil(diagnostics.controlServer)

        let report = await model.diagnosticsReport()
        XCTAssertTrue(report.contains("routerCause: noOutput"))
        XCTAssertTrue(report.contains("failedMixIDs: m0"))
        XCTAssertTrue(report.contains("boundOutputUID: MockOutput"))
        await model.stop()
    }

    func testDriverToggleOffCancelsRouterSubscriptions() async {
        let mock = MockAudioEngine()
        await mock.scriptRouterStatuses([
            RouterStatus(failedMixIDs: ["m0"], cause: .noOutput),
            .ok,
        ])
        let model = ConsoleViewModel(engine: mock, defaults: defaults)
        await model.startMock(config: config())

        XCTAssertEqual(model.routerStatus.cause, .noOutput)
        let callsBeforeDisable = await mock.startRouterCalls
        XCTAssertEqual(callsBeforeDisable, 1)

        model.driverEnabled = false
        let disabled = await eventually { model.routerStatus.cause == .ok && model.snapshot == .silent }
        XCTAssertTrue(disabled)

        await mock.emitRouterEvent()
        try? await Task.sleep(for: .milliseconds(100))

        let callsAfterStaleEvent = await mock.startRouterCalls
        XCTAssertEqual(callsAfterStaleEvent, 1, "disabled router must ignore stale event subscriptions")
        await model.stop()
    }

    /// `permissionPending` surfaces a permission message and the bounded backoff
    /// heartbeat retries until the grant lands (scripted as the next `.ok`).
    func testPermissionPendingRecoversViaHeartbeat() async {
        let mock = MockAudioEngine()
        await mock.scriptRouterStatuses([
            RouterStatus(failedMixIDs: ["m0"], cause: .permissionPending),
            .ok,
        ])
        let model = ConsoleViewModel(engine: mock, defaults: defaults)
        await model.startMock(config: config())

        XCTAssertEqual(model.failedMixIDs, ["m0"])
        XCTAssertEqual(model.routerStatus.cause, .permissionPending)
        XCTAssertEqual(model.routerStatusMessage,
                       "Waiting for audio-capture permission. Accept the system prompt to come online.")

        // First heartbeat fires at 2s; allow margin.
        let healed = await eventually(4.0) { model.failedMixIDs.isEmpty }
        XCTAssertTrue(healed, "permissionPending heartbeat should retry and recover")
        XCTAssertEqual(model.routerStatus.cause, .ok)
        await model.stop()
    }

    func testBuildFailedRecoversViaHeartbeat() async {
        let mock = MockAudioEngine()
        await mock.scriptRouterStatuses([
            RouterStatus(failedMixIDs: ["m0"], cause: .buildFailed),
            .ok,
        ])
        let model = ConsoleViewModel(engine: mock, defaults: defaults)
        await model.startMock(config: config())

        XCTAssertEqual(model.failedMixIDs, ["m0"])
        XCTAssertEqual(model.routerStatus.cause, .buildFailed)
        XCTAssertEqual(model.routerStatusMessage, "Audio engine couldn't start — retrying automatically.")

        let healed = await eventually(4.0) { model.failedMixIDs.isEmpty }
        XCTAssertTrue(healed, "buildFailed heartbeat should retry and recover")
        XCTAssertEqual(model.routerStatus.cause, .ok)
        await model.stop()
    }

    func testPermissionHeartbeatUsesCentralStatusFoldWhenRecovered() async {
        let mock = MockAudioEngine()
        await mock.scriptRouterStatuses([
            RouterStatus(failedMixIDs: ["m0"], cause: .permissionPending),
            .ok,
        ])
        let model = ConsoleViewModel(engine: mock, defaults: defaults)
        await model.startMock(config: config())

        await mock.emitRouterRecoveryEvent(.paused(
            reason: "source tap stalled",
            attempts: 3,
            window: 120,
            cooldown: 300
        ))
        let paused = await eventually { model.audioRecoveryDisplayState.isActionable }
        XCTAssertTrue(paused)

        let healed = await eventually(4.0) { model.routerStatus.cause == .ok }
        XCTAssertTrue(healed, "permissionPending heartbeat should retry and recover")
        XCTAssertEqual(model.audioRecoveryDisplayState, .ok)
        await model.stop()
    }

    func testRecoveryPauseEventShowsActionableStatus() async {
        let mock = MockAudioEngine()
        let model = ConsoleViewModel(engine: mock, defaults: defaults)
        await model.startMock(config: config())

        await mock.emitRouterRecoveryEvent(.paused(
            reason: "source tap stalled",
            attempts: 3,
            window: 120,
            cooldown: 300
        ))

        let shown = await eventually {
            model.audioRecoveryDisplayState == .paused(
                reason: "source tap stalled",
                attempts: 3,
                window: "2 min",
                cooldown: "5 min"
            )
        }
        XCTAssertTrue(shown)
        XCTAssertTrue(model.audioRecoveryDisplayState.isActionable)
        await model.stop()
    }

    func testRecoveryAttemptIsVisibleButNotActionable() async {
        let mock = MockAudioEngine()
        let model = ConsoleViewModel(engine: mock, defaults: defaults)
        await model.startMock(config: config())

        await mock.emitRouterRecoveryEvent(.attempting(reason: "source tap stalled", attempt: 2))

        let shown = await eventually {
            model.audioRecoveryDisplayState == .recovering(reason: "source tap stalled", attempt: 2)
        }
        XCTAssertTrue(shown)
        XCTAssertFalse(model.audioRecoveryDisplayState.isActionable)
        await model.stop()
    }

    func testRestartAudioClearsPausedRecoveryAndRebuilds() async {
        let mock = MockAudioEngine()
        let model = ConsoleViewModel(engine: mock, defaults: defaults)
        await model.startMock(config: config())
        let callsBeforeRestart = await mock.startRouterCalls

        await mock.emitRouterRecoveryEvent(.paused(
            reason: "source tap stalled",
            attempts: 3,
            window: 120,
            cooldown: 300
        ))
        let paused = await eventually { model.audioRecoveryDisplayState.isActionable }
        XCTAssertTrue(paused)

        await model.restartAudio()

        XCTAssertEqual(model.audioRecoveryDisplayState, .ok)
        let resetCalls = await mock.resetRouterRecoveryCalls
        let callsAfterRestart = await mock.startRouterCalls
        XCTAssertEqual(resetCalls, 1)
        XCTAssertEqual(callsAfterRestart, callsBeforeRestart + 1)
        await model.stop()
    }

    func testRestartAudioGuardsHardwareVolumeDuringRebuild() async {
        let mock = MockAudioEngine()
        let model = ConsoleViewModel(engine: mock, defaults: defaults)
        await model.startMock(config: config())
        await mock.setOutputVolume(uid: "MockOutput", 0.42)
        model.outputVolume = 0.42
        await mock.resetCalls()

        await model.restartAudio()

        let calls = await mock.calls
        XCTAssertEqual(calls, [
            .setOutputMuted(uid: "MockOutput", muted: true),
            .startRouter,
            .setOutputMuted(uid: "MockOutput", muted: true),
            .setOutputVolume(uid: "MockOutput", volume: 0.42),
            .setOutputMuted(uid: "MockOutput", muted: false),
        ])
        await model.stop()
    }

    func testOutputSwitchSerializesWithTopologyRebuilds() async {
        let mock = MockAudioEngine()
        await mock.setStartRouterDelay(.milliseconds(120))
        let model = ConsoleViewModel(engine: mock, defaults: defaults)
        await model.startMock(config: config())
        model.config.masterMuted = true
        model.outputVolume = 0.42
        await mock.resetCalls()

        model.setSystemOutput("OtherOutput")
        model.applyTopology { $0.master = 0.9 }

        let transitionComplete = await eventuallyAsync(1.0) {
            await mock.calls.count >= 9
        }
        XCTAssertTrue(transitionComplete)

        let calls = await mock.calls
        XCTAssertEqual(calls, [
            .startRouter,
            .setOutputVolume(uid: "OtherOutput", volume: 0),
            .setOutputVolume(uid: "MockOutput", volume: 0.42),
            .setOutputMuted(uid: "MockOutput", muted: false),
            .setOutputVolume(uid: "OtherOutput", volume: 0.42),
            .setOutputMuted(uid: "OtherOutput", muted: true),
            .startRouter,
            .setOutputMuted(uid: "OtherOutput", muted: true),
            .setOutputVolume(uid: "OtherOutput", volume: 0.42),
        ])
        await model.stop()
    }
}
