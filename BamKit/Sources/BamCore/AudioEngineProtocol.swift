import Foundation

public enum OutputWriteResult: Sendable, Equatable {
    case applied, unsupported, failed
}

/// Exact writable hardware controls, separate from the user's master scalar.
public struct OutputDeviceState: Sendable, Equatable {
    public let uid: String
    public let deviceID: UInt32
    public var volumes: [UInt32: Float]
    public var mutes: [UInt32: Bool]

    public init(uid: String, deviceID: UInt32, volumes: [UInt32: Float], mutes: [UInt32: Bool]) {
        self.uid = uid
        self.deviceID = deviceID
        self.volumes = volumes
        self.mutes = mutes
    }

    public var volume: Float { volumes.isEmpty ? 0 : volumes.values.reduce(0, +) / Float(volumes.count) }
    public var muted: Bool { !mutes.isEmpty && mutes.values.allSatisfy { $0 } }

    /// Apply a master target to the original calibration, including when current hardware is zero.
    /// A common gain preserves balance; the loudest channel bounds available hardware headroom.
    public func withVolume(_ target: Float) -> OutputDeviceState {
        guard target.isFinite else { return self }
        var result = self
        let target = max(0, min(1, target))
        if volume > 0, let peak = volumes.values.max(), peak > 0 {
            let gain = min(target / volume, 1 / peak)
            result.volumes = volumes.mapValues { min(1, $0 * gain) }
        } else {
            result.volumes = volumes.mapValues { _ in target }
        }
        return result
    }
}

public protocol AudioEngineProtocol: Sendable {
    func audioDiagnostics() async -> AudioDiagnostics?
    func runningAudioApps() async -> [AudioApp]
    /// Bundle IDs of processes currently producing output audio (live playback).
    func playingBundleIDs() async -> Set<String>
    func outputDevices() async -> [AudioDevice]
    /// UID of the current system default output device (where the Default
    /// catch-all device should send so unassigned apps stay audible).
    func defaultOutputUID() async -> String?
    /// UID the live router aggregate is actually bound to after resolving the
    /// stored config UID against the live device list; nil if no output. Differs
    /// from the stored UID when a device re-enumerated, so the caller can persist it.
    func boundOutputUID() async -> String?
    /// Current OS volume scalar (0…1) of the given output device, nil if unknown.
    func outputVolume(uid: String) async -> Float?
    /// Set the OS volume scalar (0…1) of the given output device.
    func setOutputVolume(uid: String, _ volume: Float) async
    /// Whether the given output device is currently OS-muted.
    func outputMuted(uid: String) async -> Bool
    /// Mute/unmute the given output device at the OS level (preserves volume).
    func setOutputMuted(uid: String, _ muted: Bool) async
    func setOutputMutedChecked(uid: String, _ muted: Bool) async -> OutputWriteResult
    func setOutputVolumeChecked(uid: String, _ volume: Float) async -> OutputWriteResult
    func outputDeviceState(uid: String) async -> OutputDeviceState?
    func restoreOutputDeviceState(_ state: OutputDeviceState, restoreVolume: Bool, restoreMute: Bool) async -> OutputWriteResult
    /// True authorizes doing nothing only; never an unguarded subsequent rebuild.
    func canKeepCurrentRouter(config: BamConfig) async -> Bool
    func routerOutputUIDs(config: BamConfig) async -> Set<String>
    /// Called only after the caller finishes a safe route and all checked output restoration.
    func acknowledgeOutputRestore(uids: Set<String>) async
    /// The serialized caller owns output protection until it releases this suspension.
    func setRouterRecoverySuspended(_ suspended: Bool) async
    func stop() async

    /// Build/rebuild the router from a v3 config (taps + mixes + destinations).
    /// Returns which mixes are offline and the dominant cause (for recovery).
    func startRouter(config: BamConfig) async -> RouterStatus
    /// Recompute routing gains live (level/mute/solo/pan/master) without
    /// rebuilding taps or reopening devices.
    func updateRouterGains(config: BamConfig) async
    func stopRouter() async
    func stopRouterChecked() async -> Bool
    /// Live per-source + per-mix levels while the router runs.
    func routerSnapshots() async -> AsyncStream<RouterSnapshot>
    /// Fires whenever the audio process list or output-device list changes —
    /// the moments when a previously failed `startRouter` might now succeed.
    /// Drives event-driven recovery instead of blind polling.
    func routerEvents() async -> AsyncStream<Void>
    /// Emits automatic router health recovery attempts and rate-limit pauses.
    func routerRecoveryEvents() async -> AsyncStream<RouterRecoveryEvent>
    /// Clears any automatic recovery pause before a user-requested rebuild.
    func resetRouterRecovery() async
}

public extension AudioEngineProtocol {
    func audioDiagnostics() async -> AudioDiagnostics? { nil }
    func outputDeviceState(uid: String) async -> OutputDeviceState? { nil }
    func restoreOutputDeviceState(_ state: OutputDeviceState, restoreVolume: Bool, restoreMute: Bool) async -> OutputWriteResult { .unsupported }
    func setRouterRecoverySuspended(_ suspended: Bool) async {}
    func stopRouterChecked() async -> Bool { false }
    func acknowledgeOutputRestore(uids: Set<String>) async {}
    func setOutputMutedChecked(uid: String, _ muted: Bool) async -> OutputWriteResult { .unsupported }
    func setOutputVolumeChecked(uid: String, _ volume: Float) async -> OutputWriteResult { .unsupported }
    func canKeepCurrentRouter(config: BamConfig) async -> Bool { false }
    func routerOutputUIDs(config: BamConfig) async -> Set<String> {
        Set(config.mixes.compactMap { if case .hardware(let uid) = $0.dest { uid } else { nil } })
    }
}
