import BamCore
import Foundation

/// Mutes hardware outputs around router changes and restores each one only after a checked route or teardown.
@MainActor
final class OutputProtection {
    struct Guarded {
        var state: OutputDeviceState
        let calibration: OutputDeviceState
        var volume: Float {
            get { state.volume }
            set { state.volumes = calibration.withVolume(newValue).volumes }
        }
        var muted: Bool {
            get { state.muted }
            set { state.mutes = newValue ? state.mutes.mapValues { _ in true } : OutputProtection.masterUnmuted(calibration).mutes }
        }
    }

    /// How a batch of guards is released; `requested`/`overrides` let a rebound UID inherit the intended level.
    struct RestoreRequest {
        var bound: String? = nil
        var fadeIn = false
        var requested: String? = nil
        var overrides: [String: Float] = [:]
        var toStock = false
        var masterMuted: @MainActor () -> Bool = { false }
        var currentOutput: @MainActor () -> String? = { nil }
        var stale: @MainActor () -> Bool = { false }
    }

    static let exitMutedKey = "bam.exitLeftOutputMuted"

    /// Explicit master-unmute releases a whole-device mute (e.g. left by failed startup); partial channel mutes stay.
    nonisolated static func masterUnmuted(_ state: OutputDeviceState) -> OutputDeviceState {
        var result = state
        if state.muted { result.mutes = state.mutes.mapValues { _ in false } }
        return result
    }

    let engine: any AudioEngineProtocol
    let defaults: UserDefaults
    // Failed routes keep their guard; only a checked rebuild or teardown releases it.
    var guarded: [String: Guarded] = [:]
    var stockStates: [String: OutputDeviceState] = [:]
    var calibrations: [String: OutputDeviceState] = [:]
    var requestedVolumes: [String: Float] = [:]
    var rampTargets: [String: Float] = [:]
    var restoring = false
    private(set) var treatMutedAsCalibration: Bool
    var rampSleep: @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    var onVolumeWritten: @MainActor (String, Float) -> Void = { _, _ in }

    init(engine: any AudioEngineProtocol, defaults: UserDefaults) {
        self.engine = engine
        self.defaults = defaults
        treatMutedAsCalibration = defaults.bool(forKey: Self.exitMutedKey)
    }

    func markExitMuted() {
        defaults.set(true, forKey: Self.exitMutedKey)
    }

    private func outputsRestored() {
        treatMutedAsCalibration = false
        if defaults.object(forKey: Self.exitMutedKey) != nil {
            defaults.removeObject(forKey: Self.exitMutedKey)
        }
    }

    func capture(uid: String) async -> OutputDeviceState? {
        guard var state = await engine.outputDeviceState(uid: uid) else { return nil }
        // A device still muted from an exit that never unmuted is not the user's calibration.
        if treatMutedAsCalibration, state.muted { state.mutes = state.mutes.mapValues { _ in false } }
        remember(state)
        return state
    }

    private func remember(_ state: OutputDeviceState) {
        if stockStates[state.uid]?.deviceID != state.deviceID {
            stockStates[state.uid] = state
        }
        if let previous = calibrations[state.uid], previous.deviceID == state.deviceID {
            if state.volume > 0 {
                var calibration = state
                calibration.mutes = previous.mutes
                calibrations[state.uid] = calibration
            }
        } else {
            calibrations[state.uid] = state
        }
    }

    func protect(_ uids: Set<String>, overriding volumes: [String: Float] = [:]) async -> Bool {
        for uid in uids.sorted() {
            if guarded[uid] == nil {
                let previousTarget = requestedVolumes[uid]
                guard let state = await capture(uid: uid) else { return false }
                guarded[uid] = Guarded(state: state, calibration: calibrations[uid] ?? state)
                if requestedVolumes[uid] != previousTarget, let target = requestedVolumes[uid] {
                    guarded[uid]?.volume = target
                }
            }
            if let volume = volumes[uid] { guarded[uid]?.volume = requestedVolumes[uid] ?? volume }
        }
        for uid in uids.sorted() {
            guard await engine.setOutputMutedChecked(uid: uid, true) == .applied else { return false }
        }
        return true
    }

    /// Restores every guarded output in `uids` (the bound one first) and releases its guard; on false the remaining guards stay muted.
    func restore(uids: Set<String>, _ request: RestoreRequest) async -> Bool {
        let bound = request.bound
        let ordered = uids.sorted { a, b in
            if a == bound { return b != bound }
            if b == bound { return false }
            return a < b
        }
        transferReboundTarget(request)
        for uid in ordered {
            guard !request.stale(), guarded[uid] != nil,
                  await engine.setOutputMutedChecked(uid: uid, true) == .applied, !request.stale() else { return false }
            transferReboundTarget(request)
            guard let state = target(uid, request) else { return false }
            if request.fadeIn, uid == bound, !request.masterMuted(), !state.muted {
                guard await engine.setOutputVolumeChecked(uid: uid, 0) == .applied, !request.stale() else { return false }
                guard await restoreMute(uid, request) else { return false }
                let intentUID = uid == request.requested ? nil : request.requested
                guard await ramp(uid: uid, from: 0, to: Double(state.volume), intentUID: intentUID, request) else {
                    _ = await engine.setOutputMutedChecked(uid: uid, true)
                    return false
                }
            } else {
                var written = state
                // A fader move during the write lands as one more write instead of being lost.
                repeat {
                    transferReboundTarget(request)
                    written = target(uid, request) ?? written
                    guard await engine.restoreOutputDeviceState(written, restoreVolume: true, restoreMute: false) == .applied,
                          !request.stale() else { return false }
                    transferReboundTarget(request)
                } while (target(uid, request) ?? written).volumes != written.volumes
                guard await restoreMute(uid, request) else { return false }
            }
            onVolumeWritten(uid, guarded[uid]?.volume ?? state.volume)
            await engine.acknowledgeOutputRestore(uids: [uid])
            guarded[uid] = nil
        }
        outputsRestored()
        return true
    }

    private func target(_ uid: String, _ request: RestoreRequest) -> OutputDeviceState? {
        guard let current = guarded[uid] else { return nil }
        return request.toStock ? (stockStates[uid] ?? current.state) : current.state
    }

    /// A stored UID that re-enumerated is bound under a new UID; the intended level follows it.
    private func transferReboundTarget(_ request: RestoreRequest) {
        guard let bound = request.bound, let requested = request.requested, bound != requested,
              let original = request.overrides[requested] else { return }
        let intentUID = request.currentOutput() == bound ? bound : requested
        guarded[bound]?.volume = requestedVolumes[intentUID] ?? original
    }

    private func restoreMute(_ uid: String, _ request: RestoreRequest) async -> Bool {
        guard !request.masterMuted(), let latest = target(uid, request), !latest.muted else { return true }
        return await engine.restoreOutputDeviceState(latest, restoreVolume: false, restoreMute: true) == .applied
    }

    private func ramp(uid: String, from: Double, to: Double, intentUID: String?, _ request: RestoreRequest) async -> Bool {
        let initial: OutputDeviceState
        if let state = guarded[uid]?.state { initial = state }
        else if let state = await capture(uid: uid) { initial = state }
        else { return false }
        rampTargets[uid] = Float(to)
        defer { rampTargets[uid] = nil }
        func write(_ scalar: Float) async -> Bool {
            let calibration = guarded[uid]?.calibration ?? calibrations[uid] ?? initial
            let state = calibration.withVolume(scalar)
            guard await engine.restoreOutputDeviceState(state, restoreVolume: true, restoreMute: false) == .applied else { return false }
            onVolumeWritten(uid, state.volume)
            return true
        }
        func adoptIntent() {
            guard let intentUID,
                  let latest = requestedVolumes[request.currentOutput() == uid ? uid : intentUID] else { return }
            guarded[uid]?.volume = latest
        }
        func target() -> Double { Double(guarded[uid]?.volume ?? rampTargets[uid] ?? Float(to)) }
        guard abs(to - from) > 0.01 else { return await write(Float(to)) }
        guard await write(Float(from)) else { return false }
        let steps = Tuning.rampSteps
        for i in 1...steps {
            if request.stale() { return false }
            adoptIntent()
            if request.masterMuted() || guarded[uid]?.muted == true {
                guard await engine.setOutputMutedChecked(uid: uid, true) == .applied else { return false }
                return await write(Float(target()))
            }
            guard await write(Float(from + (target() - from) * (Double(i) / Double(steps)))) else { return false }
            do { try await rampSleep(Tuning.rampStepDelay) } catch { return false }
        }
        guard !request.stale() else { return false }
        adoptIntent()
        return await write(Float(target()))
    }
}
