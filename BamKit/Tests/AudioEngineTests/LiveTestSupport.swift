import XCTest
import Foundation
import BamCore
@testable import AudioEngine

enum LiveProtectionError: Error { case unavailable, routingFailed }

/// Opt-in gate for tests that drive the real HAL: `BAM_LIVE=1` and no bam app owning the hardware.
enum LiveTestGate {
    /// Above this the restore at the end of a test would itself be an unsafe write.
    static let maxStartingVolume: Float = 0.15

    static func require() throws {
        guard ProcessInfo.processInfo.environment["BAM_LIVE"] == "1" else {
            throw XCTSkip("Set BAM_LIVE=1 (or run `make test-live`) to exercise the real CoreAudio HAL.")
        }
        if bamAppRunning() {
            throw XCTSkip("Quit bam / bam dev first: live tests must be the only owner of the output device.")
        }
    }

    static func bamAppRunning() -> Bool {
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
}

extension XCTestCase {
    /// Per-element snapshot of the device; skips instead of ever restoring a loud level.
    func captureOutput(_ engine: CoreAudioEngine, uid: String) async throws -> OutputDeviceState {
        guard let state = await engine.outputDeviceState(uid: uid) else { throw LiveProtectionError.unavailable }
        guard state.volume <= LiveTestGate.maxStartingVolume else {
            throw XCTSkip("Output volume is \(state.volume); set it to 15% or lower first (make test-live forces 8%).")
        }
        return state
    }

    static func restoreOutput(_ engine: CoreAudioEngine, _ states: [OutputDeviceState]) async throws {
        for state in states {
            guard await engine.restoreOutputDeviceState(state, restoreVolume: true, restoreMute: false) == .applied else {
                throw LiveProtectionError.unavailable
            }
        }
        for state in states {
            guard await engine.restoreOutputDeviceState(state, restoreVolume: false, restoreMute: true) == .applied else {
                throw LiveProtectionError.unavailable
            }
        }
        await engine.acknowledgeOutputRestore(uids: Set(states.map(\.uid)))
    }

    /// Mutes every router output, starts, then restores; teardown stops the router and restores again.
    func startProtected(_ engine: CoreAudioEngine, config: BamConfig) async throws {
        let uids = await engine.routerOutputUIDs(config: config)
        guard !uids.isEmpty else { throw LiveProtectionError.unavailable }
        var saved: [OutputDeviceState] = []
        for uid in uids.sorted() { saved.append(try await captureOutput(engine, uid: uid)) }
        let intended = saved
        addTeardownBlock {
            guard await engine.stopRouterChecked() else { throw LiveProtectionError.unavailable }
            try await Self.restoreOutput(engine, intended)
        }
        for uid in uids {
            guard await engine.setOutputMutedChecked(uid: uid, true) == .applied else { throw LiveProtectionError.unavailable }
        }
        guard !(await engine.startRouter(config: config)).isFailure else { throw LiveProtectionError.routingFailed }
        try await Self.restoreOutput(engine, intended)
    }

    /// Retries `startRouter` under mute until readiness is confirmed or `timeout` elapses, then restores `intended`.
    func applyProtected(_ engine: CoreAudioEngine, config: BamConfig, uid: String,
                        intended: OutputDeviceState, timeout: Duration) async throws -> RouterStatus {
        guard await engine.setOutputMutedChecked(uid: uid, true) == .applied else { throw LiveProtectionError.unavailable }
        let deadline = ContinuousClock.now + timeout
        var status = await engine.startRouter(config: config)
        while status.cause == .buildFailed, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(250))
            status = await engine.startRouter(config: config)
        }
        try await Self.restoreOutput(engine, [intended])
        return status
    }

    /// Processes other than this one that the HAL reports as rendering output right now.
    func liveOutputProcesses() -> [AudioProcessInfo] {
        let me = getpid()
        return ProcessEnumerator.allProcesses().filter { $0.isRunningOutput && !$0.bundleID.isEmpty && $0.pid != me }
    }
}
