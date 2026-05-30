import XCTest
@testable import bam
import BamCore

/// Cause-aware recovery: drives `ConsoleViewModel` through the `MockAudioEngine`
/// scripting hooks so the recovery logic is exercised without real CoreAudio.
@MainActor
final class RouterRecoveryTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "bam.recovery.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(true, forKey: ConsoleViewModel.driverKey)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func eventually(_ timeout: TimeInterval = 1.0, _ cond: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return cond()
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
}
