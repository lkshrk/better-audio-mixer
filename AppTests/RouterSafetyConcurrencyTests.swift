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

    func testFailedStartupPreservesSelectedOutputDespiteOldBoundOutput() async {
        let mock = MockAudioEngine()
        await mock.setCheckedWriteResults(mute: .failed)
        let model = ConsoleViewModel(engine: mock, defaults: defaults)
        let config = BamConfig(mixes: [Mix(id: ConsoleViewModel.defaultMixID,
                                          name: "Default", dest: .hardware(uid: "ChosenOutput"))])
        await model.startMock(config: config)

        XCTAssertEqual(model.routerStatus.cause, .buildFailed)
        let bound = await mock.boundOutputUID()
        XCTAssertEqual(bound, "MockOutput", "failed protection leaves an older binding")
        XCTAssertEqual(model.systemOutputUID, "ChosenOutput")
        await model.stop()
    }

    func testFailedSwitchAndReconciliationPreserveNewSelection() async {
        let mock = MockAudioEngine()
        let model = await makeModel(mock)
        await mock.setCheckedWriteResults(mute: .failed)
        model.setSystemOutput("ChosenOutput")
        await model.enqueueRouterWork { _ in }.value
        await model.restartAudio()

        XCTAssertEqual(model.routerStatus.cause, .buildFailed)
        let bound = await mock.boundOutputUID()
        XCTAssertEqual(bound, "MockOutput")
        XCTAssertEqual(model.systemOutputUID, "ChosenOutput")
        await model.stop()
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

    func testGainBurstCoalescesWithoutCrossingQueuedTopology() async {
        let mock = MockAudioEngine()
        let model = await makeModel(mock)
        for i in 1...100 { model.applyGains { $0.master = Double(i) / 100 } }
        model.applyTopology { $0.mixes[0].name = "New topology" }
        for i in 1...100 { model.applyGains { $0.master = Double(i) / 200 } }
        await model.enqueueRouterWork { _ in }.value
        let calls = await mock.calls
        XCTAssertEqual(calls.filter { $0 == .updateRouterGains }.count, 2)
        let finalConfig = await mock.lastRouterConfig
        XCTAssertEqual(finalConfig, model.config, "an older gain snapshot must never undo newer topology")
        await model.stop()
    }

    func testOutputVolumeBurstOnlyWritesLatestTarget() async {
        let mock = MockAudioEngine()
        let model = await makeModel(mock)
        for i in 1...100 { model.setOutputVolume(Double(i) / 200) }
        await model.enqueueRouterWork { _ in }.value
        let calls = await mock.calls
        XCTAssertEqual(calls, [.setOutputVolume(uid: "MockOutput", volume: 0.5)])
        await model.stop()
    }

    func testExplicitMasterUnmuteClearsWholeDeviceMuteCapturedAfterFailure() async {
        let mock = MockAudioEngine()
        let model = await makeModel(mock)
        let muted = OutputDeviceState(uid: "MockOutput", deviceID: 1,
                                      volumes: [0: 0.12], mutes: [0: true])
        await mock.setOutputDeviceStateForTests(muted)
        model.outputCalibrations["MockOutput"] = muted
        model.setMasterMuted(false)
        await model.enqueueRouterWork { _ in }.value
        let physicalMute = await mock.outputMuted(uid: "MockOutput")
        XCTAssertFalse(physicalMute)
        XCTAssertEqual(model.outputCalibrations["MockOutput"]?.mutes, [0: true], "stock calibration remains available for exact exit restoration")
        await model.stop()
    }

    func testGuardedMasterUnmutePreservesPartialMuteButReleasesGlobalMute() {
        for mutes in [[UInt32(1): true, 2: true], [UInt32(1): false, 2: true]] {
            let original = OutputDeviceState(uid: "device", deviceID: 1, volumes: [0: 0.12], mutes: mutes)
            var guarded = ConsoleViewModel.GuardedOutput(state: original, calibration: original)
            guarded.muted = false
            XCTAssertEqual(guarded.state.mutes, original.muted ? mutes.mapValues { _ in false } : mutes)
            XCTAssertEqual(guarded.calibration.mutes, mutes)
        }
    }

    func testFailedLiveVolumeChangeMutesAndSurfacesFailure() async {
        let mock = MockAudioEngine()
        let model = await makeModel(mock)
        await mock.setCheckedWriteResults(volume: .failed)
        model.setOutputVolume(1)
        await model.enqueueRouterWork { _ in }.value
        let muted = await mock.outputMuted(uid: "MockOutput")
        XCTAssertTrue(muted)
        XCTAssertNotNil(model.error)
        XCTAssertEqual(model.routerStatus.cause, .buildFailed)
        XCTAssertNotNil(model.guardedOutputs["MockOutput"])

        await mock.resetCalls()
        model.setOutputVolume(0)
        await model.enqueueRouterWork { _ in }.value
        let calls = await mock.calls
        XCTAssertFalse(calls.contains(.setOutputMuted(uid: "MockOutput", muted: false)))
        XCTAssertFalse(calls.contains(.setOutputVolume(uid: "MockOutput", volume: 0)))
        XCTAssertEqual(model.guardedOutputs["MockOutput"]?.volume, 0)
        await model.stop()
    }

    func testAlternatingGainAndHardwareTargetsStayBounded() async {
        let mock = MockAudioEngine()
        let model = await makeModel(mock)
        for i in 1...100 {
            model.applyGains { $0.master = Double(i) / 200 }
            model.setOutputVolume(Double(i) / 200)
        }
        await model.enqueueRouterWork { _ in }.value
        let calls = await mock.calls
        XCTAssertEqual(calls, [.updateRouterGains, .setOutputVolume(uid: "MockOutput", volume: 0.5)])
        await model.stop()
    }

    func testDriverOffOutputTargetsStillReachHardware() async {
        defaults.set(false, forKey: ConsoleViewModel.driverKey)
        let mock = MockAudioEngine()
        let model = await makeModel(mock)
        for i in 1...100 { model.setOutputVolume(Double(i) / 200) }
        await model.enqueueRouterWork { _ in }.value
        let calls = await mock.calls
        XCTAssertEqual(calls, [.setOutputVolume(uid: "MockOutput", volume: 0.5)])
        await model.stop()
    }

    func testRebuildAndStopPreservePerChannelVolumeAndPartialMute() async {
        let mock = MockAudioEngine()
        let model = await makeModel(mock)
        let state = OutputDeviceState(uid: "MockOutput", deviceID: 1,
                                      volumes: [1: 0.2, 2: 0.7, 3: 0.4, 4: 0.1],
                                      mutes: [1: false, 2: true, 3: false, 4: true])
        await mock.setOutputDeviceStateForTests(state)
        await model.restartAudio()
        let rebuilt = await mock.outputDeviceState(uid: "MockOutput")
        XCTAssertEqual(rebuilt, state)
        await model.stop()
        let stopped = await mock.outputDeviceState(uid: "MockOutput")
        XCTAssertEqual(stopped, state)
    }

    func testSwitchFadePreservesPerChannelCalibration() async {
        let mock = MockAudioEngine()
        let model = await makeModel(mock)
        let state = OutputDeviceState(uid: "OtherOutput", deviceID: 1,
                                      volumes: [1: 0.2, 2: 0.6], mutes: [1: false, 2: true])
        await mock.setOutputDeviceStateForTests(state)
        model.outputVolume = Double(state.volume)
        model.outputRampSleep = { _ in await Task.yield() }
        model.setSystemOutput("OtherOutput")
        await model.enqueueRouterWork { _ in }.value
        let restored = await mock.outputDeviceState(uid: "OtherOutput")
        XCTAssertEqual(restored, state)
        await model.stop()
    }

    func testFailedGuardRetainsLatestVolumeWithoutWritingOrUnmuting() async {
        let mock = MockAudioEngine()
        let model = await makeModel(mock)
        await mock.scriptRouterStatuses([RouterStatus(cause: .buildFailed), .ok])
        await model.restartAudio()
        await mock.resetCalls()
        model.setOutputVolume(0.17)
        model.setMasterMuted(false)
        await model.enqueueRouterWork { _ in }.value
        let calls = await mock.calls
        XCTAssertFalse(calls.contains(.setOutputVolume(uid: "MockOutput", volume: 0.17)))
        XCTAssertFalse(calls.contains(.setOutputMuted(uid: "MockOutput", muted: false)))
        await model.restartAudio()
        let restored = await mock.outputVolume(uid: "MockOutput")
        XCTAssertEqual(restored ?? -1, 0.17, accuracy: 0.0001)
        await model.stop()
    }

    func testNewMuteSupersedesQueuedUnmute() async {
        let mock = MockAudioEngine()
        let model = await makeModel(mock)
        model.setMasterMuted(false)
        model.setMasterMuted(true)
        await model.enqueueRouterWork { _ in }.value
        let calls = await mock.calls
        XCTAssertFalse(calls.contains(.setOutputMuted(uid: "MockOutput", muted: false)))
        let muted = await mock.outputMuted(uid: "MockOutput")
        XCTAssertTrue(muted)
        await model.stop()
    }

    func testFailedExplicitUnmuteReportsOutputProtectionFailure() async {
        let mock = MockAudioEngine()
        let model = await makeModel(mock)
        model.setMasterMuted(true)
        let muted = await eventually { await mock.outputMuted(uid: "MockOutput") }
        XCTAssertTrue(muted)
        await model.enqueueRouterWork { _ in }.value
        await mock.setCheckedWriteResults(mute: .failed)

        model.setMasterMuted(false)
        await model.enqueueRouterWork { _ in }.value

        XCTAssertEqual(model.routerStatus.cause, .buildFailed)
        XCTAssertNotNil(model.error)
        let hardwareMuted = await mock.outputMuted(uid: "MockOutput")
        XCTAssertTrue(hardwareMuted)
        await mock.setCheckedWriteResults()
        await model.stop()
    }

    func testStartupAppliesNewerTargetBeforeUnmuteWithoutHardwareRamp() async {
        defaults.set(0.42, forKey: ConsoleViewModel.savedVolumeKey)
        let mock = MockAudioEngine(silentRouter: true)
        let model = ConsoleViewModel(engine: mock, defaults: defaults)
        await mock.setOutputVolumeRestoreHookForTests { @MainActor in
            model.setOutputVolume(0.17)
        }
        await model.startMock(config: BamConfig())
        await model.enqueueRouterWork { _ in }.value
        let calls = await mock.calls
        let newVolumeIndex = calls.firstIndex(of: .setOutputVolume(uid: "MockOutput", volume: 0.17))!
        let unmuteIndex = calls.firstIndex(of: .setOutputMuted(uid: "MockOutput", muted: false))!
        XCTAssertLessThan(newVolumeIndex, unmuteIndex)
        XCTAssertFalse(calls.contains(.setOutputVolume(uid: "MockOutput", volume: 0)))
        XCTAssertFalse(calls.contains(.setOutputVolume(uid: "MockOutput", volume: 1)))
        let volume = await mock.outputVolume(uid: "MockOutput")
        XCTAssertEqual(volume ?? -1, 0.17, accuracy: 0.0001)
        XCTAssertEqual(model.outputVolume, 0.17, accuracy: 0.0001)
        await model.stop()
    }

    func testAsymmetricFadeUserEditsPreserveCalibrationThroughZero() async {
        let mock = MockAudioEngine()
        let model = await makeModel(mock)
        let original = OutputDeviceState(uid: "OtherOutput", deviceID: 1,
                                         volumes: [1: 0.2, 2: 0.6], mutes: [1: false, 2: true])
        await mock.setOutputDeviceStateForTests(original)
        var ticks = 0
        model.outputRampSleep = { [weak model] _ in
            ticks += 1
            if ticks == 1 { model?.setOutputVolume(0) }
            if ticks == 2 { model?.setOutputVolume(0.2) }
            await Task.yield()
        }
        model.setSystemOutput("OtherOutput")
        await model.enqueueRouterWork { _ in }.value
        let restored = await mock.outputDeviceState(uid: "OtherOutput")
        XCTAssertEqual(restored?.volumes[1] ?? -1, 0.1, accuracy: 0.0001)
        XCTAssertEqual(restored?.volumes[2] ?? -1, 0.3, accuracy: 0.0001)
        XCTAssertEqual(restored?.mutes, original.mutes)
        await model.stop()
    }

    func testOrdinaryVolumeEditsPreserveCalibrationThroughZeroAndHeadroomCap() async {
        let mock = MockAudioEngine()
        let original = OutputDeviceState(uid: "MockOutput", deviceID: 1,
                                         volumes: [1: 0.2, 2: 0.6], mutes: [1: false, 2: true])
        await mock.setOutputDeviceStateForTests(original)
        let model = await makeModel(mock)
        model.setOutputVolume(0)
        await model.enqueueRouterWork { _ in }.value
        model.setOutputVolume(0.2)
        await model.enqueueRouterWork { _ in }.value
        let raised = await mock.outputDeviceState(uid: "MockOutput")
        XCTAssertEqual(raised?.volumes[1] ?? -1, 0.1, accuracy: 0.0001)
        XCTAssertEqual(raised?.volumes[2] ?? -1, 0.3, accuracy: 0.0001)
        model.setOutputVolume(1)
        await model.enqueueRouterWork { _ in }.value
        let capped = await mock.outputDeviceState(uid: "MockOutput")
        XCTAssertEqual(capped?.volumes[1] ?? -1, 1 / 3, accuracy: 0.0001)
        XCTAssertEqual(capped?.volumes[2] ?? -1, 1, accuracy: 0.0001)
        XCTAssertEqual(capped?.mutes, original.mutes)
        await model.stop()
    }

    func testCompletedVolumeWriteDoesNotReplaceNewerFaderTarget() async {
        let mock = MockAudioEngine()
        let model = await makeModel(mock)
        await mock.setOutputVolumeRestoreHookForTests { @MainActor in
            model.setOutputVolume(0.7)
        }
        model.setOutputVolume(0.2)
        // This barrier runs after the old write, before the hook's newer write.
        var displayedAfterOldWrite = 0.0
        await model.enqueueRouterWork { model in
            displayedAfterOldWrite = model.outputVolume
        }.value
        XCTAssertEqual(displayedAfterOldWrite, 0.7, accuracy: 0.0001)
        await model.enqueueRouterWork { _ in }.value
        let hardware = await mock.outputVolume(uid: "MockOutput")
        XCTAssertEqual(hardware ?? -1, 0.7, accuracy: 0.0001)
        await model.stop()
    }

    func testVolumeReadbackDiscardsStateInvalidatedWhileReading() async {
        for change in ["target", "output", "guard", "restore"] {
            let mock = MockAudioEngine()
            let model = await makeModel(mock)
            await mock.setOutputVolumeReadHookForTests { @MainActor in
                switch change {
                case "target": model.setOutputVolume(0.7)
                case "output":
                    let index = model.config.mixes.firstIndex { $0.id == ConsoleViewModel.defaultMixID }!
                    model.config.mixes[index].dest = .hardware(uid: "OtherOutput")
                case "guard":
                    let state = OutputDeviceState(uid: "MockOutput", deviceID: 1,
                                                  volumes: [0: 0.42], mutes: [0: false])
                    model.guardedOutputs["MockOutput"] = ConsoleViewModel.GuardedOutput(state: state, calibration: state)
                default: model.restoringVolume = true
                }
            }
            await model.refreshOutputVolume()
            XCTAssertEqual(model.outputVolume, change == "target" ? 0.7 : 0.42,
                           accuracy: 0.0001, "stale read after \(change)")
            model.restoringVolume = false
            await model.stop()
        }
    }

    func testCompletedVolumeWriteDoesNotReplaceChangedOutputDisplay() async {
        let mock = MockAudioEngine()
        let model = await makeModel(mock)
        await mock.setOutputVolumeRestoreHookForTests { @MainActor in
            let index = model.config.mixes.firstIndex { $0.id == ConsoleViewModel.defaultMixID }!
            model.config.mixes[index].dest = .hardware(uid: "OtherOutput")
            model.outputVolume = 0.6
        }
        model.setOutputVolume(0.2)
        await model.enqueueRouterWork { _ in }.value
        XCTAssertEqual(model.outputVolume, 0.6, accuracy: 0.0001)
        await model.stop()
    }

    func testExitRestoresExactStockVolumeAndMute() async {
        let mock = MockAudioEngine()
        let original = OutputDeviceState(uid: "MockOutput", deviceID: 1,
                                         volumes: [1: 0.2, 2: 0.6], mutes: [1: false, 2: true])
        await mock.setOutputDeviceStateForTests(original)
        let model = await makeModel(mock)
        model.setOutputVolume(0.1)
        model.setMasterMuted(true)
        await model.enqueueRouterWork { _ in }.value
        let stopped = await ConsoleViewModel.restoreOutputsForExit(engine: mock, config: model.config,
                                                                   savedStates: model.stockOutputStates)
        XCTAssertTrue(stopped)
        let restored = await mock.outputDeviceState(uid: "MockOutput")
        XCTAssertEqual(restored, original)
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
