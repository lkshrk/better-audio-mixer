import XCTest
import BamCore
@testable import AudioEngine

final class GuardedOutputRebuildTests: XCTestCase {
    func testSeparateCaptureDeviceNeedsNoHardwareControls() async {
        let calls = MuteCallRecorder()
        let rebuilt = BoolFlag()
        await CoreAudioEngine.setDeviceOpsForTests((
            volume: { uid in uid == "listening" ? 0.4 : nil },
            muted: { _ in false },
            setVolume: { uid, _ in uid == "listening" ? .applied : .unsupported },
            setMuted: { uid, muted in
                calls.record(uid: uid, muted: muted, rebuildFiredBeforeThis: rebuilt.value)
                return uid == "listening" ? .applied : .unsupported
            }
        ))
        // Capture can be any separately selected device, including one without
        // mute/volume controls. It is not a listening-output protection owner.
        let uids = CoreAudioEngine.listeningOutputUIDs(selected: "listening", bound: "listening", pending: [])
        XCTAssertEqual(uids, ["listening"])
        let engine = CoreAudioEngine()
        await engine.performGuardedOutputRebuildForTests(uids: uids, unmute: true) {
            rebuilt.set(true)
            return true
        }
        XCTAssertTrue(rebuilt.value)
        XCTAssertEqual(calls.all().map(\.uid), ["listening", "listening"])
        XCTAssertEqual(calls.all().map(\.muted), [true, false])
    }

    func testPreviousAndUnrestoredListeningOutputsKeepProtection() {
        XCTAssertEqual(CoreAudioEngine.listeningOutputUIDs(selected: "new", bound: "old", pending: ["failed"]),
                       ["new", "old", "failed"])
        XCTAssertEqual(CoreAudioEngine.listeningOutputUIDs(selected: nil, bound: "old", pending: []), ["old"])
        XCTAssertEqual(CoreAudioEngine.listeningOutputUIDs(selected: nil, bound: nil, pending: []), [])
    }

    func testMissingListeningOutputCannotAuthorizeLiveTeardown() async {
        let engine = CoreAudioEngine()
        await engine.installRouterForTests(resources: RouterAggregate.IOResources())
        await engine.configureRecoveryForTests(config: BamConfig(), hooks: .init(
            outputUIDs: [], willTearDown: {}, rebuild: { .ok }))
        let status = await engine.startRouter(config: BamConfig())
        XCTAssertEqual(status.cause, .noOutput)
        let retainedAfterStart = await engine.hasRouterForTests()
        XCTAssertTrue(retainedAfterStart)
        let stopped = await engine.stopRouterChecked()
        XCTAssertFalse(stopped)
        let retainedAfterStop = await engine.hasRouterForTests()
        XCTAssertTrue(retainedAfterStop)
    }

    override func tearDown() async throws {
        await CoreAudioEngine.setDeviceOpsForTests(nil)
        await CoreAudioEngine.setChangeListenerFactoryForTests(nil)
    }

    func testGuardMutesBeforeRebuildAndUnmutesAfter() async {
        let calls = MuteCallRecorder()
        let rebuildFlag = BoolFlag()

        await CoreAudioEngine.setDeviceOpsForTests((
            volume: { _ in 0.7 },
            muted: { _ in false },
            setVolume: { _, _ in .applied },
            setMuted: { uid, muted in calls.record(uid: uid, muted: muted, rebuildFiredBeforeThis: rebuildFlag.value); return .applied }
        ))

        let engine = CoreAudioEngine()
        await engine.performGuardedOutputRebuildForTests(uids: ["dev-A", "dev-B"], unmute: true) {
            rebuildFlag.set(true)
            return true
        }

        let recorded = calls.all()
        let mutesBefore = recorded.filter { $0.muted && !$0.rebuildFiredBeforeThis }
        let unmutesAfter = recorded.filter { !$0.muted && $0.rebuildFiredBeforeThis }

        XCTAssertFalse(mutesBefore.isEmpty, "mute must be called before rebuild")
        XCTAssertFalse(unmutesAfter.isEmpty, "unmute must be called after rebuild")
        XCTAssertTrue(recorded.filter { $0.muted && $0.rebuildFiredBeforeThis }.isEmpty,
                      "no mute calls should occur after rebuild fires")
    }

    func testGuardSkipsUnmuteWhenMasterMuted() async {
        let calls = MuteCallRecorder()

        await CoreAudioEngine.setDeviceOpsForTests((
            volume: { _ in 0.5 },
            muted: { _ in false },
            setVolume: { _, _ in .applied },
            setMuted: { uid, muted in calls.record(uid: uid, muted: muted, rebuildFiredBeforeThis: false); return .applied }
        ))

        let engine = CoreAudioEngine()
        await engine.performGuardedOutputRebuildForTests(uids: ["dev-A"], unmute: false) { true }

        let recorded = calls.all()
        XCTAssertTrue(recorded.allSatisfy { $0.muted }, "when unmute=false, only mute calls should occur (no unmute)")
    }

    func testGainOnlyUpdateDoesNotToggleMute() async {
        let calls = MuteCallRecorder()

        await CoreAudioEngine.setDeviceOpsForTests((
            volume: { _ in 0.7 },
            muted: { _ in false },
            setVolume: { _, _ in .applied },
            setMuted: { uid, muted in calls.record(uid: uid, muted: muted, rebuildFiredBeforeThis: false); return .applied }
        ))
        await CoreAudioEngine.setChangeListenerFactoryForTests { _, _, _ in NoOpToken() }

        let engine = CoreAudioEngine()
        let config = BamConfig(
            sources: [Source(id: "s1", name: "Browser", kind: .app, bundleIDs: ["com.test.fake"])],
            mixes: [Mix(id: "m1", name: "Mix1", dest: .hardware(uid: "fake-uid-A"),
                        sends: [Send(source: "s1")])],
            pans: ["s1": 0.5]
        )
        _ = await engine.startRouter(config: config)
        calls.reset()

        let config2 = BamConfig(
            sources: [Source(id: "s1", name: "Browser", kind: .app, bundleIDs: ["com.test.fake"])],
            mixes: [Mix(id: "m1", name: "Mix1", dest: .hardware(uid: "fake-uid-A"),
                        sends: [Send(source: "s1", level: 0.5)])],
            pans: ["s1": 0.5]
        )
        await engine.updateRouterGains(config: config2)

        XCTAssertTrue(calls.all().isEmpty, "gain-only update must not toggle device mute")
    }
}

private struct MuteEntry {
    let uid: String
    let muted: Bool
    let rebuildFiredBeforeThis: Bool
}

private final class MuteCallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [MuteEntry] = []

    func record(uid: String, muted: Bool, rebuildFiredBeforeThis: Bool) {
        lock.lock()
        entries.append(MuteEntry(uid: uid, muted: muted, rebuildFiredBeforeThis: rebuildFiredBeforeThis))
        lock.unlock()
    }

    func all() -> [MuteEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    func reset() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }
}

private final class NoOpToken: ChangeListenerToken {}

private final class BoolFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false

    var value: Bool {
        lock.lock(); defer { lock.unlock() }
        return _value
    }

    func set(_ v: Bool) {
        lock.lock(); _value = v; lock.unlock()
    }
}
