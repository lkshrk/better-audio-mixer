import XCTest
@testable import bam
import BamCore

/// Persist debouncing, exit-mute handling on launch, compare-before-assign, and live fader routing.
@MainActor
final class ConsoleViewModelLifecycleTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var configURL: URL!

    override func setUp() async throws {
        suiteName = "bam.lifecycle.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        configURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bam-\(UUID().uuidString).yaml")
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: configURL)
    }

    private func eventually(_ timeout: TimeInterval = 1.0, _ cond: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await cond() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await cond()
    }

    private func config() -> BamConfig {
        BamConfig(
            sources: [Source(id: "s0", name: "App", kind: .app, bundleIDs: ["com.x"])],
            mixes: [Mix(id: "m0", name: "Mix", dest: .virtualSlot(0), sends: [Send(source: "s0")])],
            pans: ["s0": 0.5]
        )
    }

    private func makeModel(_ mock: MockAudioEngine, driver: Bool) async -> ConsoleViewModel {
        defaults.set(driver, forKey: ConsoleViewModel.driverKey)
        let model = ConsoleViewModel(engine: mock, defaults: defaults)
        await model.startMock(config: config())
        model.configURL = configURL
        await mock.resetCalls()
        return model
    }

    private func savedMaster() throws -> Double {
        try BamConfig.load(url: configURL).master
    }

    // MARK: persist debounce

    func testPersistCoalescesBurstIntoOneDeferredWrite() async throws {
        let model = await makeModel(MockAudioEngine(), driver: false)
        for i in 1...100 { model.applyGains { $0.master = Double(i) / 200 } }
        XCTAssertFalse(FileManager.default.fileExists(atPath: configURL.path),
                       "a burst must not hit disk synchronously")
        let written = await eventually { FileManager.default.fileExists(atPath: self.configURL.path) }
        XCTAssertTrue(written)
        XCTAssertEqual(try savedMaster(), 0.5, accuracy: 0.0001, "latest value wins")
        await model.stop()
    }

    func testFlushPersistWritesImmediately() async throws {
        let model = await makeModel(MockAudioEngine(), driver: false)
        model.applyGains { $0.master = 0.3 }
        model.flushPersist()
        XCTAssertEqual(try savedMaster(), 0.3, accuracy: 0.0001)
        await model.stop()
    }

    func testStopFlushesPendingPersist() async throws {
        let model = await makeModel(MockAudioEngine(), driver: false)
        model.applyGains { $0.master = 0.7 }
        await model.stop()
        XCTAssertEqual(try savedMaster(), 0.7, accuracy: 0.0001)
    }

    func testExitFlushesPendingPersist() async throws {
        let model = await makeModel(MockAudioEngine(), driver: false)
        model.applyGains { $0.master = 0.6 }
        _ = await model.prepareForExit()
        XCTAssertEqual(try savedMaster(), 0.6, accuracy: 0.0001)
    }

    // MARK: live fader

    func testPreviewDeviceLevelRoutesGainWithoutPersisting() async throws {
        let mock = MockAudioEngine()
        let model = await makeModel(mock, driver: true)
        model.previewDeviceLevel("m0", 0.25)
        await model.enqueueRouterWork { _ in }.value
        let live = await mock.lastRouterConfig?.mixes.first { $0.id == "m0" }?.level
        XCTAssertEqual(live ?? -1, 0.25, accuracy: 0.0001, "drag must reach the router immediately")
        XCTAssertEqual(model.deviceLevel("m0"), 0.25, accuracy: 0.0001)
        try? await Task.sleep(for: .milliseconds(450))
        XCTAssertFalse(FileManager.default.fileExists(atPath: configURL.path), "drag must not persist")

        model.setDeviceLevel("m0", 0.25)
        let written = await eventually { FileManager.default.fileExists(atPath: self.configURL.path) }
        XCTAssertTrue(written, "release persists")
        XCTAssertEqual(try BamConfig.load(url: configURL).mixes.first { $0.id == "m0" }?.level ?? -1,
                       0.25, accuracy: 0.0001)
        await model.stop()
    }

    // MARK: exit-muted flag on launch

    private func mutedState(_ uid: String = "MockOutput") -> OutputDeviceState {
        OutputDeviceState(uid: uid, deviceID: 1, volumes: [1: 0.5, 2: 0.5], mutes: [1: true, 2: true])
    }

    func testExitMutedFlagTreatsAllMutedCaptureAsUnmutedCalibration() async {
        defaults.set(true, forKey: OutputProtection.exitMutedKey)
        defaults.set(true, forKey: ConsoleViewModel.driverKey)
        let mock = MockAudioEngine()
        await mock.setOutputDeviceStateForTests(mutedState())
        let model = ConsoleViewModel(engine: mock, defaults: defaults)
        await model.startMock(config: config())

        let unmuted = await mock.outputMuted(uid: "MockOutput")
        XCTAssertFalse(unmuted, "the first protected rebuild must unmute a device bam left muted")
        XCTAssertEqual(model.protection.stockStates["MockOutput"]?.muted, false)
        XCTAssertNil(defaults.object(forKey: OutputProtection.exitMutedKey))
        await model.stop()
        let afterStop = await mock.outputMuted(uid: "MockOutput")
        XCTAssertFalse(afterStop)
    }

    func testAllMutedCaptureWithoutFlagStaysMuted() async {
        defaults.set(true, forKey: ConsoleViewModel.driverKey)
        let mock = MockAudioEngine()
        await mock.setOutputDeviceStateForTests(mutedState())
        let model = ConsoleViewModel(engine: mock, defaults: defaults)
        await model.startMock(config: config())

        let muted = await mock.outputMuted(uid: "MockOutput")
        XCTAssertTrue(muted, "a user-muted device is calibration and must stay muted")
        XCTAssertEqual(model.protection.stockStates["MockOutput"]?.muted, true)
        await model.stop()
    }

    func testExitSavesRunningLevelOnlyWhenBamOwnsVolume() async {
        let mock = MockAudioEngine()
        let model = await makeModel(mock, driver: true)
        model.bamVolumeApplied = false
        _ = await model.prepareForExit()
        XCTAssertNil(defaults.object(forKey: ConsoleViewModel.savedVolumeKey))

        let owned = await makeModel(mock, driver: true)
        owned.setOutputVolume(0.33)
        await owned.enqueueRouterWork { _ in }.value
        owned.bamVolumeApplied = true
        _ = await owned.prepareForExit()
        XCTAssertEqual(defaults.double(forKey: ConsoleViewModel.savedVolumeKey), 0.33, accuracy: 0.001)
    }

    // MARK: compare-before-assign

    func testRefreshAppStateDoesNotNotifyWhenNothingChanged() async {
        let mock = MockAudioEngine()
        let model = await makeModel(mock, driver: true)
        await model.refreshAppState()
        XCTAssertEqual(model.runningApps.map(\.bundleID), ["com.x"])

        let unchanged = expectation(description: "no observation change")
        unchanged.isInverted = true
        withObservationTracking {
            _ = model.runningApps
            _ = model.outputDevices
            _ = model.playing
        } onChange: {
            unchanged.fulfill()
        }
        await model.refreshAppState()
        await fulfillment(of: [unchanged], timeout: 0.2)
        await model.stop()
    }

    func testSilentSnapshotIsNotReassigned() async {
        defaults.set(true, forKey: ConsoleViewModel.driverKey)
        let mock = MockAudioEngine(silentRouter: true)
        let model = ConsoleViewModel(engine: mock, defaults: defaults)
        await model.startMock(config: config())
        let firstFrame = await eventually { model.snapshot != .silent }
        XCTAssertTrue(firstFrame, "a router frame with mixes replaces the silent placeholder")

        let unchanged = expectation(description: "identical frames skip assignment")
        unchanged.isInverted = true
        withObservationTracking { _ = model.snapshot } onChange: { unchanged.fulfill() }
        await fulfillment(of: [unchanged], timeout: 0.2)
        await model.stop()
    }

    // MARK: driver toggle

    func testDriverToggleOffThenOnSerializesReloads() async {
        let mock = MockAudioEngine()
        let model = await makeModel(mock, driver: true)
        let startsBefore = await mock.startRouterCalls
        model.driverEnabled = false
        model.driverEnabled = true
        let back = await eventually(2.0) {
            await mock.startRouterCalls == startsBefore + 1 && model.routerStatus.cause == .ok
        }
        XCTAssertTrue(back, "the superseded off-reload is skipped; the on-reload restarts once")
        try? await Task.sleep(for: .milliseconds(150))
        let live = await mock.lastRouterConfig
        XCTAssertEqual(live, model.config, "no stale off-reload tears the router down afterwards")
        let starts = await mock.startRouterCalls
        XCTAssertEqual(starts, startsBefore + 1)
        await model.stop()
    }

    // MARK: poll vs pending hardware write

    func testRefreshOutputVolumeSkipsWhileWritePending() async {
        let mock = MockAudioEngine()
        let model = await makeModel(mock, driver: false)
        model.setOutputVolume(0.3)
        XCTAssertNotNil(model.pendingOutputTargets)
        await model.refreshOutputVolume()
        XCTAssertEqual(model.outputVolume, 0.3, accuracy: 0.0001, "poll must not snap the fader back")
        await model.enqueueRouterWork { _ in }.value
        await model.refreshOutputVolume()
        XCTAssertEqual(model.outputVolume, 0.3, accuracy: 0.0001)
        await model.stop()
    }

    // MARK: corrupt config

    func testQuarantineURLKeepsOriginalNextToConfig() {
        let url = URL(fileURLWithPath: "/tmp/bam/bam.yaml")
        let date = Date(timeIntervalSince1970: 1_789_000_000)
        let broken = ConsoleViewModel.quarantineURL(for: url, date: date)
        XCTAssertEqual(broken.deletingLastPathComponent().path, "/tmp/bam")
        XCTAssertTrue(broken.lastPathComponent.hasPrefix("bam.yaml.broken-2026-09-"))
        XCTAssertFalse(broken.lastPathComponent.contains(":"))
    }
}

final class VersionLabelTests: XCTestCase {
    func testVersionLabelNamesAppAndVersion() {
        let label = AppDelegate.versionLabel
        XCTAssertTrue(label.hasPrefix("BAM "), label)
        XCTAssertTrue(label.dropFirst(4).contains(where: \.isNumber) || label.hasSuffix("dev"), label)
    }
}
