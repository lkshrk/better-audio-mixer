import XCTest
@testable import bam
import BamCore

/// Exercises overlapping UI and device events without opening real audio devices.
@MainActor
final class RouterSafetyConcurrencyTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "bam.router-concurrency.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(true, forKey: ConsoleViewModel.driverKey)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func eventually(_ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    private func makeModel(_ mock: MockAudioEngine) async -> ConsoleViewModel {
        let model = ConsoleViewModel(engine: mock, defaults: defaults)
        await model.startMock(config: BamConfig())
        model.outputVolume = 0.42
        await mock.resetCalls()
        return model
    }

    func testUserMuteAndVolumeDuringFadeReplaceOriginalTarget() async {
        let mock = MockAudioEngine()
        let model = await makeModel(mock)
        model.setSystemOutput("OtherOutput")
        let fading = await eventually {
            await mock.calls.contains(.setOutputMuted(uid: "OtherOutput", muted: false))
        }
        XCTAssertTrue(fading, "intervene only after the protected fade has started")

        await mock.resetCalls()
        model.setOutputVolume(0.17)
        model.setMasterMuted(true)
        await model.enqueueRouterWork { _ in }.value

        let volume = await mock.outputVolume(uid: "OtherOutput")
        let muted = await mock.outputMuted(uid: "OtherOutput")
        let calls = await mock.calls
        XCTAssertEqual(volume ?? -1, 0.17, accuracy: 0.0001)
        XCTAssertEqual(model.outputVolume, 0.17, accuracy: 0.0001)
        XCTAssertTrue(muted)
        XCTAssertFalse(calls.contains(.setOutputMuted(uid: "OtherOutput", muted: false)),
                       "the fade must never undo a newer user mute")
        XCTAssertFalse(calls.contains(.setOutputVolume(uid: "OtherOutput", volume: 0.42)),
                       "the captured pre-fade target must not overwrite the user's new level")
        await model.stop()
    }

    func testSuccessfulSwitchReleasesConnectedFailedTargetBeforeHealthyEvent() async {
        let mock = MockAudioEngine()
        let model = await makeModel(mock)
        // MockOutput is enumerated by the mock throughout the A -> B -> C switches.
        model.setMasterMuted(true)
        model.setSystemOutput("OutputA")
        await model.enqueueRouterWork { _ in }.value
        await mock.scriptRouterStatuses([RouterStatus(cause: .buildFailed), .ok])
        model.setSystemOutput("MockOutput")
        await model.enqueueRouterWork { _ in }.value
        XCTAssertEqual(model.routerStatus.cause, .buildFailed)
        XCTAssertNotNil(model.guardedOutputs["MockOutput"])

        model.setSystemOutput("OutputC")
        await model.enqueueRouterWork { _ in }.value
        XCTAssertEqual(model.routerStatus.cause, .ok)
        XCTAssertTrue(model.guardedOutputs.isEmpty, "connected B must not retain a stale guard after C succeeds")
        let acknowledgements = await mock.acknowledgedOutputRestores
        XCTAssertTrue(acknowledgements.contains(["MockOutput"]))

        await mock.setCanKeepCurrentRouter(true)
        await mock.resetCalls()
        let checksBefore = await mock.canKeepCurrentRouterCalls
        await mock.emitRouterEvent()
        let checked = await eventually { await mock.canKeepCurrentRouterCalls > checksBefore }
        XCTAssertTrue(checked)
        await model.enqueueRouterWork { _ in }.value
        let calls = await mock.calls
        XCTAssertTrue(calls.isEmpty, "a healthy event after recovery must not mute or rebuild")
        await model.stop()
    }

    func testEventBurstBehindTopologyUsesLatestConfigAndBoundsReconciliation() async {
        let mock = MockAudioEngine()
        let model = await makeModel(mock)
        await mock.setCanKeepCurrentRouter(true)
        await mock.setStartRouterDelay(.milliseconds(400))
        let startsBefore = await mock.startRouterCalls
        let checksBefore = await mock.canKeepCurrentRouterCalls
        model.applyTopology { $0.master = 0.7 }
        let rebuilding = await eventually {
            await mock.calls.contains(.setOutputMuted(uid: "MockOutput", muted: true))
        }
        XCTAssertTrue(rebuilding)
        model.applyTopology { $0.master = 0.3 }
        for _ in 0..<100 { await mock.emitRouterEvent() }
        let checked = await eventually { await mock.canKeepCurrentRouterCalls > checksBefore }
        XCTAssertTrue(checked)
        // A consumer may still be taking its single buffered invalidation. Let it
        // enqueue, then drain work before checking the final state.
        for _ in 0..<20 { await Task.yield() }
        await model.enqueueRouterWork { _ in }.value

        let finalConfig = await mock.lastRouterConfig
        let starts = await mock.startRouterCalls
        let checks = await mock.canKeepCurrentRouterCalls - checksBefore
        XCTAssertEqual(finalConfig, model.config)
        XCTAssertEqual(finalConfig?.master, 0.3)
        XCTAssertEqual(starts, startsBefore + 2, "events must not rebuild either queued topology again")
        XCTAssertTrue((1...2).contains(checks), "a burst should retain at most the active and newest invalidation")
        await model.stop()
    }

    func testStopAndDriverDisableDuringFadeLeaveNoStaleWritesAfterTeardown() async {
        for disableDriver in [false, true] {
            let mock = MockAudioEngine()
            let model = await makeModel(mock)
            model.setSystemOutput("OtherOutput")
            let fading = await eventually {
                await mock.calls.contains(.setOutputMuted(uid: "OtherOutput", muted: false))
            }
            XCTAssertTrue(fading)
            await mock.resetCalls()

            if disableDriver {
                model.driverEnabled = false
                let stopped = await eventually {
                    await mock.lastRouterConfig == nil && model.guardedOutputs.isEmpty
                }
                XCTAssertTrue(stopped)
            } else {
                await model.stop()
            }
            let finalConfig = await mock.lastRouterConfig
            XCTAssertNil(finalConfig)
            let restoredVolume = await mock.outputVolume(uid: "OtherOutput")
            XCTAssertEqual(restoredVolume ?? -1, 0.42, accuracy: 0.0001,
                           "safe teardown must restore the intended target, not an intermediate fade step")
            await mock.resetCalls()
            // Cross more than one 50ms fade tick after confirmed teardown; an old
            // ramp must not resume and write to the now-unrouted hardware.
            try? await Task.sleep(for: .milliseconds(120))
            let lateCalls = await mock.calls
            XCTAssertTrue(lateCalls.isEmpty, "no stale ramp may write or unmute after stop completes")
            await model.stop()
        }
    }
}
