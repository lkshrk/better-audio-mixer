import XCTest
@testable import bam
import BamCore

/// Rebound-UID and delayed-write intent (4574f01); needs the MockAudioEngine resolve/read/restore hooks.
@MainActor
final class RouterStartupIntentTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "bam.startup-intent.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(true, forKey: ConsoleViewModel.driverKey)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeModel(_ mock: MockAudioEngine) async -> ConsoleViewModel {
        let model = ConsoleViewModel(engine: mock, defaults: defaults)
        await model.startMock(config: BamConfig())
        model.outputVolume = 0.42
        await mock.resetCalls()
        return model
    }

    func testReboundStartupTransfersSavedAndNewerLogicalTargetBeforeUnmute() async {
        for newerTarget in [false, true] {
            let mock = MockAudioEngine(silentRouter: true)
            await mock.setResolvedOutputUIDForTests("ReboundOutput")
            defaults.set(0.6, forKey: ConsoleViewModel.savedVolumeKey)
            let model = ConsoleViewModel(engine: mock, defaults: defaults)
            if newerTarget {
                await mock.setOutputVolumeRestoreHookForTests { @MainActor in
                    // UI still refers to the stored UID until startup reconciles it.
                    model.setOutputVolume(0.3)
                }
            }
            await model.startMock(config: BamConfig())
            await model.enqueueRouterWork { _ in }.value
            let calls = await mock.calls
            let target: Float = newerTarget ? 0.3 : 0.6
            let writeIndex = calls.firstIndex(of: .setOutputVolume(uid: "ReboundOutput", volume: target))!
            let unmuteIndex = calls.firstIndex(of: .setOutputMuted(uid: "ReboundOutput", muted: false))!
            XCTAssertLessThan(writeIndex, unmuteIndex)
            XCTAssertEqual(model.systemOutputUID, "ReboundOutput")
            let volume = await mock.outputVolume(uid: "ReboundOutput")
            XCTAssertEqual(volume ?? -1, target, accuracy: 0.001)
            XCTAssertEqual(model.protection.stockStates["ReboundOutput"]?.volume ?? -1, 0.8, accuracy: 0.001)
            await model.stop()
        }
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
                    model.protection.guarded["MockOutput"] = OutputProtection.Guarded(state: state, calibration: state)
                default: model.protection.restoring = true
                }
            }
            await model.refreshOutputVolume()
            XCTAssertEqual(model.outputVolume, change == "target" ? 0.7 : 0.42,
                           accuracy: 0.0001, "stale read after \(change)")
            model.protection.restoring = false
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
}
