import BamCore
import Foundation

/// Scriptable in-memory implementation of MixerControl for headless unit tests.
/// Tests configure `mixes` and `masterSnapshot`, then assert mutations via the
/// recorded `calls` array.
@MainActor
public final class MockMixerControl: MixerControl {

    // MARK: - Scripted state

    public var mixes: [MixSnapshot]
    public var masterSnapshot: MasterSnapshot
    public var outputs: [OutputSnapshot]
    /// v2 default: switching is unsupported (false). Tests flip this to exercise v3 path.
    public var outputSwitchSupported: Bool = false

    public init(
        mixes: [MixSnapshot] = [],
        master: MasterSnapshot = MasterSnapshot(pos: 1.0, pct: 100, muted: false, level: -12),
        outputs: [OutputSnapshot] = []
    ) {
        self.mixes = mixes
        self.masterSnapshot = master
        self.outputs = outputs
    }

    // MARK: - MixerControl

    public var controlSnapshot: ControlSnapshot {
        ControlSnapshot(mixes: mixes, master: masterSnapshot)
    }

    public func setPos(mixID: String, pos: Double) {
        calls.append(.setPos(mixID: mixID, pos: pos))
        mutate(mixID: mixID) { s in
            MixSnapshot(id: s.id, name: s.name, emoji: s.emoji,
                        pos: pos, pct: Int((pos * 100).rounded()),
                        muted: s.muted, level: s.level)
        }
    }

    public func nudgePos(mixID: String, delta: Double) {
        calls.append(.nudgePos(mixID: mixID, delta: delta))
        mutate(mixID: mixID) { s in
            let newPos = min(1, max(0, s.pos + delta))
            return MixSnapshot(id: s.id, name: s.name, emoji: s.emoji,
                               pos: newPos, pct: Int((newPos * 100).rounded()),
                               muted: s.muted, level: s.level)
        }
    }

    public func setMuted(mixID: String, muted: Bool) {
        calls.append(.setMuted(mixID: mixID, muted: muted))
        mutate(mixID: mixID) { s in
            MixSnapshot(id: s.id, name: s.name, emoji: s.emoji,
                        pos: s.pos, pct: s.pct, muted: muted, level: s.level)
        }
    }

    public func toggleMuted(mixID: String) {
        calls.append(.toggleMuted(mixID: mixID))
        mutate(mixID: mixID) { s in
            MixSnapshot(id: s.id, name: s.name, emoji: s.emoji,
                        pos: s.pos, pct: s.pct, muted: !s.muted, level: s.level)
        }
    }

    public func setMasterPos(pos: Double) {
        calls.append(.setMasterPos(pos: pos))
        let p = min(1, max(0, pos))
        masterSnapshot = MasterSnapshot(pos: p, pct: Int((p * 100).rounded()),
                                        muted: masterSnapshot.muted, level: masterSnapshot.level)
    }

    public func nudgeMasterPos(delta: Double) {
        calls.append(.nudgeMasterPos(delta: delta))
        let p = min(1, max(0, masterSnapshot.pos + delta))
        masterSnapshot = MasterSnapshot(pos: p, pct: Int((p * 100).rounded()),
                                        muted: masterSnapshot.muted, level: masterSnapshot.level)
    }

    public func setMasterMuted(muted: Bool) {
        calls.append(.setMasterMuted(muted: muted))
        masterSnapshot = MasterSnapshot(pos: masterSnapshot.pos, pct: masterSnapshot.pct,
                                        muted: muted, level: masterSnapshot.level)
    }

    public func listMixes() -> [MixSnapshot] { mixes }

    public func listOutputs() -> [OutputSnapshot] { outputs }

    public func setOutputDevice(uid: String) -> Bool {
        calls.append(.setOutputDevice(uid: uid))
        guard outputSwitchSupported else { return false }
        outputs = outputs.map { OutputSnapshot(uid: $0.uid, name: $0.name, active: $0.uid == uid) }
        return true
    }

    // MARK: - Recorded calls (test assertions)

    public enum Call: Equatable {
        case setPos(mixID: String, pos: Double)
        case nudgePos(mixID: String, delta: Double)
        case setMuted(mixID: String, muted: Bool)
        case toggleMuted(mixID: String)
        case setMasterPos(pos: Double)
        case nudgeMasterPos(delta: Double)
        case setMasterMuted(muted: Bool)
        case setOutputDevice(uid: String)
    }

    public private(set) var calls: [Call] = []

    public func resetCalls() { calls = [] }

    // MARK: - Private helpers

    private func mutate(mixID: String, transform: (MixSnapshot) -> MixSnapshot) {
        guard let idx = mixes.firstIndex(where: { $0.id == mixID }) else { return }
        mixes[idx] = transform(mixes[idx])
    }
}
