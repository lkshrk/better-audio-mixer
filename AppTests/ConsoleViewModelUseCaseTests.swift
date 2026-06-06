import XCTest
@testable import bam
import BamCore

/// Use-case tests for the launch/exit volume flow and app routing, driven through
/// the injected `MockAudioEngine` so nothing touches real CoreAudio.
@MainActor
final class ConsoleViewModelUseCaseTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "bam.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeModel(engine: MockAudioEngine, driver: Bool, saved: Double?) -> ConsoleViewModel {
        defaults.set(driver, forKey: ConsoleViewModel.driverKey)
        if let saved { defaults.set(saved, forKey: ConsoleViewModel.savedVolumeKey) }
        return ConsoleViewModel(engine: engine, defaults: defaults)
    }

    /// Poll a condition for up to `timeout` seconds; lets detached engine Tasks run.
    private func eventually(_ timeout: TimeInterval = 1.0,
                            _ cond: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await cond() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await cond()
    }

    // MARK: launch fader seed

    func testInitSeedsOutputVolumeFromSavedValue() {
        let model = makeModel(engine: MockAudioEngine(), driver: false, saved: 0.55)
        XCTAssertEqual(model.outputVolume, 0.55, accuracy: 0.0001,
                       "fader must seed from the saved level, not flash 1.0")
    }

    func testInitDefaultsToFullWhenNothingSaved() {
        let model = makeModel(engine: MockAudioEngine(), driver: false, saved: nil)
        XCTAssertEqual(model.outputVolume, 1.0, accuracy: 0.0001)
    }

    func testOutputPickerHidesBamInternalDevices() {
        XCTAssertTrue(ConsoleViewModel.isSelectableHardwareOutput(
            AudioDevice(uid: "AppleUSBAudioEngine:Display:2", name: "Studio Display")
        ))
        XCTAssertFalse(ConsoleViewModel.isSelectableHardwareOutput(
            AudioDevice(uid: "BAM_UID_0", name: "bam Device 0")
        ))
        XCTAssertFalse(ConsoleViewModel.isSelectableHardwareOutput(
            AudioDevice(uid: "bam-router-agg", name: "bam-router")
        ))
        XCTAssertFalse(ConsoleViewModel.isSelectableHardwareOutput(
            AudioDevice(uid: "private-aggregate", name: "bam-router")
        ))
    }

    func testSingleInstanceGuardDetectsSameBundleDifferentPID() {
        XCTAssertTrue(SingleInstanceGuard.hasOtherInstance(
            bundleIdentifier: "me.harke.bam",
            currentPID: 100,
            runningApplications: [
                RunningApplicationIdentity(bundleIdentifier: "me.harke.bam", processIdentifier: 200)
            ]
        ))
        XCTAssertFalse(SingleInstanceGuard.hasOtherInstance(
            bundleIdentifier: "me.harke.bam",
            currentPID: 100,
            runningApplications: [
                RunningApplicationIdentity(bundleIdentifier: "me.harke.bam", processIdentifier: 100),
                RunningApplicationIdentity(bundleIdentifier: "com.apple.finder", processIdentifier: 200)
            ]
        ))
    }

    func testSingleInstanceGuardTreatsDevAndReleaseAsConflictingInstances() {
        XCTAssertTrue(SingleInstanceGuard.hasOtherInstance(
            bundleIdentifier: "me.harke.bam",
            currentPID: 100,
            runningApplications: [
                RunningApplicationIdentity(bundleIdentifier: "me.harke.bam.dev", processIdentifier: 200)
            ]
        ))
        XCTAssertTrue(SingleInstanceGuard.hasOtherInstance(
            bundleIdentifier: "me.harke.bam.dev",
            currentPID: 100,
            runningApplications: [
                RunningApplicationIdentity(bundleIdentifier: "me.harke.bam", processIdentifier: 200)
            ]
        ))
    }

    func testPaletteHueIsStableAcrossProcessesForKnownIDs() {
        XCTAssertEqual(Palette.hue(for: "m-game"), 0.8194444444, accuracy: 0.0001)
        XCTAssertEqual(Palette.hue(for: "m-chat"), 0.4305555556, accuracy: 0.0001)
        XCTAssertEqual(Palette.hue(for: "Default"), 0.2555555556, accuracy: 0.0001)
    }

    func testAppIconCacheCachesMissingBundleLookups() {
        var lookups: [String] = []
        AppIconCache.resetForTests()
        AppIconCache.resolveIconForTests = { bundleID in
            lookups.append(bundleID)
            return nil
        }
        defer {
            AppIconCache.resolveIconForTests = nil
            AppIconCache.resetForTests()
        }

        XCTAssertNil(AppIconCache.icon(for: "com.example.Missing"))
        XCTAssertNil(AppIconCache.icon(for: "com.example.Missing"))

        XCTAssertEqual(lookups, ["com.example.Missing"])
    }

    // MARK: volume restore (driver off — hardware-direct)

    func testRestoreLeavesHardwareVolumeAloneWhenDriverOff() async {
        let mock = MockAudioEngine()
        let model = makeModel(engine: mock, driver: false, saved: 0.6)
        await model.startMock(config: BamConfig())

        await model.restoreOutputVolume()

        let applied = await mock.outputVolume(uid: "MockOutput")
        XCTAssertEqual(applied ?? -1, 0.8, accuracy: 0.001,
                       "driver-off mode must not push bam's saved level to the physical device")
        XCTAssertEqual(model.outputVolume, 0.8, accuracy: 0.001,
                       "driver-off mode should reflect the live hardware level")
        await model.stop()
    }

    // MARK: volume restore (driver on — gated on real captured audio)

    func testRestoreLeavesStockLevelWhileTapNotCapturing() async {
        // Silent router → meter frames stay at floor → setup not yet ready
        // (permission popup still pending). The device must stay at its STOCK level
        // (mock starts at 0.8), untouched — no dim, no mute — until capture confirms.
        let mock = MockAudioEngine(silentRouter: true)
        let model = makeModel(engine: mock, driver: true, saved: 0.6)
        await model.startMock(config: BamConfig())

        let restore = Task { await model.restoreOutputVolume() }
        try? await Task.sleep(for: .milliseconds(350))

        let dev = await mock.outputVolume(uid: "MockOutput")
        XCTAssertEqual(dev ?? -1, 0.8, accuracy: 0.001, "device stays at stock until setup is ready")
        XCTAssertEqual(model.outputVolume, 0.6, accuracy: 0.001, "fader still shows the bam-level seed")

        restore.cancel()
        await model.stop()
    }

    func testRestoreRaisesOnceTapCaptures() async {
        // Non-silent router → meter frames rise above floor → permission granted,
        // apps muted, safe to restore the saved level.
        let mock = MockAudioEngine()
        let model = makeModel(engine: mock, driver: true, saved: 0.6)
        await model.startMock(config: BamConfig())

        await model.restoreOutputVolume()

        let dev = await mock.outputVolume(uid: "MockOutput")
        XCTAssertEqual(dev ?? -1, 0.6, accuracy: 0.001, "once capturing, restore raises to the saved level")
        XCTAssertEqual(model.outputVolume, 0.6, accuracy: 0.001)
        await model.stop()
    }

    func testStaleRouterStartCannotOverwriteNewerGainConfig() async {
        let mock = MockAudioEngine()
        await mock.setStartRouterDelay(.milliseconds(200))
        let model = makeModel(engine: mock, driver: true, saved: nil)
        await model.startMock(config: BamConfig(
            sources: [Source(id: "s0", name: "App", bundleIDs: ["com.x"])],
            mixes: [Mix(id: "m0", name: "Mix", dest: .virtualSlot(0), sends: [Send(source: "s0")])],
            pans: ["s0": 0.5]
        ))

        model.addDevice()
        model.setDeviceLevel("m0", 0.25)

        let latestApplied = await eventually { await mock.lastRouterConfig?.mixes.first { $0.id == "m0" }?.level == 0.25 }
        XCTAssertTrue(latestApplied)

        try? await Task.sleep(for: .milliseconds(260))

        let level = await mock.lastRouterConfig?.mixes.first { $0.id == "m0" }?.level
        XCTAssertEqual(level ?? -1, 0.25, accuracy: 0.001)
        await model.stop()
    }

    // MARK: master mute → hardware

    func testMasterMutePushesToHardwareDevice() async {
        let mock = MockAudioEngine()
        let model = makeModel(engine: mock, driver: false, saved: nil)
        await model.startMock(config: BamConfig())

        model.setMasterMuted(true)
        XCTAssertTrue(model.masterMuted)
        let muted = await eventually { await mock.outputMuted(uid: "MockOutput") }
        XCTAssertTrue(muted, "master mute must reach the physical device")

        model.setMasterMuted(false)
        let unmuted = await eventually { await !mock.outputMuted(uid: "MockOutput") }
        XCTAssertTrue(unmuted, "un-mute must reach the physical device")
        await model.stop()
    }

    // MARK: app routing

    func testAssignThenRemoveAppMovesBetweenDeviceAndDefault() async {
        let mock = MockAudioEngine()
        let model = makeModel(engine: mock, driver: false, saved: nil)
        await model.startMock(config: BamConfig())

        model.addDevice()
        guard let deviceID = model.devices.last?.id, deviceID != ConsoleViewModel.defaultMixID else {
            return XCTFail("addDevice did not create a non-default device")
        }
        let app = AudioApp(bundleID: "com.test.app", displayName: "Test App")

        model.assignApp(app, toDevice: deviceID)
        XCTAssertEqual(model.currentDeviceID(forApp: app.bundleID), deviceID,
                       "assigned app should live in the target device")

        model.removeApp(app.bundleID, fromDevice: deviceID)
        XCTAssertEqual(model.currentDeviceID(forApp: app.bundleID), ConsoleViewModel.defaultMixID,
                       "removed app should fall back to the Default catch-all")
        await model.stop()
    }
}
