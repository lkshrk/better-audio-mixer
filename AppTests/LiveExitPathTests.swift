import XCTest
@testable import bam
import AudioEngine
import BamCore

/// Drives a real `ConsoleViewModel` on the real engine through the app's exit path.
/// Opt-in via `BAM_LIVE=1` and only when no bam app owns the hardware.
@MainActor
final class LiveExitPathTests: XCTestCase {
    private static let maxStartingVolume: Float = 0.15
    private static let lowVolume: Float = 0.10
    private var suiteName = ""
    private var defaults: UserDefaults?
    private var configURL: URL?

    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["BAM_LIVE"] == "1" else {
            throw XCTSkip("Set BAM_LIVE=1 (or run `make test-live`) to exercise the real CoreAudio HAL.")
        }
        if Self.bamAppRunning() {
            throw XCTSkip("Quit bam / bam dev first: live tests must be the only owner of the output device.")
        }
        suiteName = "bam.live-exit.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.set(true, forKey: ConsoleViewModel.driverKey)
        self.defaults = defaults
        configURL = FileManager.default.temporaryDirectory.appendingPathComponent("bam-live-\(UUID().uuidString).yaml")
    }

    override func tearDown() async throws {
        defaults?.removePersistentDomain(forName: suiteName)
        if let configURL { try? FileManager.default.removeItem(at: configURL) }
    }

    private static func bamAppRunning() -> Bool {
        let me = getpid()
        let found = pids(["-x", "bam"]) + pids(["-f", "bam dev.app/Contents/MacOS/bam dev"])
        return found.contains { $0 != me }
    }

    private static func pids(_ arguments: [String]) -> [pid_t] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
    }

    private static func restore(_ engine: CoreAudioEngine, _ state: OutputDeviceState) async -> Bool {
        _ = await engine.stopRouterChecked()
        guard await engine.restoreOutputDeviceState(state, restoreVolume: true, restoreMute: false) == .applied,
              await engine.restoreOutputDeviceState(state, restoreVolume: false, restoreMute: true) == .applied
        else { return false }
        await engine.acknowledgeOutputRestore(uids: [state.uid])
        return true
    }

    private func eventually(_ timeout: Duration, _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return await condition()
    }

    func testPrepareForExitRestoresOutputAndClearsExitMutedFlag() async throws {
        let defaults = try XCTUnwrap(defaults)
        let engine = CoreAudioEngine()
        guard let uid = await engine.defaultOutputUID() else { throw XCTSkip("No default output device.") }
        let capturedState = await engine.outputDeviceState(uid: uid)
        let captured = try XCTUnwrap(capturedState)
        guard captured.volume <= Self.maxStartingVolume else {
            throw XCTSkip("Output volume is \(captured.volume); set it to 15% or lower first (make test-live forces 8%).")
        }
        addTeardownBlock {
            let restored = await Self.restore(engine, captured)
            XCTAssertTrue(restored, "teardown could not return the output to its captured state")
        }

        let lowered = await engine.setOutputVolumeChecked(uid: uid, Self.lowVolume)
        XCTAssertEqual(lowered, .applied)
        let model = ConsoleViewModel(engine: engine, defaults: defaults)
        await model.startMock(config: BamConfig())
        model.configURL = configURL
        XCTAssertEqual(model.systemOutputUID, uid, "the Default mix must route to the current default output")
        let ready = await eventually(.seconds(10)) { model.routerStatus.cause == .ok }
        let stock = model.protection.stockStates[uid]
        XCTAssertNotNil(stock, "start must capture the stock output state before touching it")
        XCTAssertTrue(defaults.bool(forKey: OutputProtection.exitMutedKey) == false)

        let restored = await model.prepareForExit()
        XCTAssertTrue(restored, "exit teardown must finish inside Tuning.exitTeardownTimeout (router ready=\(ready))")
        let afterState = await engine.outputDeviceState(uid: uid)
        let after = try XCTUnwrap(afterState)
        XCTAssertFalse(after.muted, "exit must leave the output unmuted")
        XCTAssertEqual(after.volume, stock?.volume ?? Self.lowVolume, accuracy: 0.07,
                       "exit must return the output to the stock level captured at start")
        XCTAssertNil(defaults.object(forKey: OutputProtection.exitMutedKey), "a completed exit clears the exit-muted flag")
        let bound = await engine.boundOutputUID()
        XCTAssertNil(bound, "the router must be torn down after exit")
    }
}
