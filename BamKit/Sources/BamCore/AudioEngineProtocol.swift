import Foundation

public protocol AudioEngineProtocol: Sendable {
    func start(config: BamConfig) async -> AsyncStream<MeterSnapshot>
    func update(config: BamConfig) async
    func applyGains(config: BamConfig) async
    func setEnforce(_ on: Bool) async
    func runningAudioApps() async -> [AudioApp]
    /// Bundle IDs of processes currently producing output audio (live playback).
    func playingBundleIDs() async -> Set<String>
    func outputDevices() async -> [AudioDevice]
    /// UID of the current system default output device (where the Default
    /// catch-all device should send so unassigned apps stay audible).
    func defaultOutputUID() async -> String?
    /// Current OS volume scalar (0…1) of the given output device, nil if unknown.
    func outputVolume(uid: String) async -> Float?
    /// Set the OS volume scalar (0…1) of the given output device.
    func setOutputVolume(uid: String, _ volume: Float) async
    /// Whether the given output device is currently OS-muted.
    func outputMuted(uid: String) async -> Bool
    /// Mute/unmute the given output device at the OS level (preserves volume).
    func setOutputMuted(uid: String, _ muted: Bool) async
    func stop() async

    // MARK: v3 router
    /// Build/rebuild the router from a v3 config (taps + mixes + destinations).
    /// Returns which mixes are offline and the dominant cause (for recovery).
    func startRouter(config: BamConfig) async -> RouterStatus
    /// Recompute routing gains live (level/mute/solo/pan/master) without
    /// rebuilding taps or reopening devices.
    func updateRouterGains(config: BamConfig) async
    func stopRouter() async
    /// Live per-source + per-mix levels while the router runs.
    func routerSnapshots() async -> AsyncStream<RouterSnapshot>
    /// Fires whenever the audio process list or output-device list changes —
    /// the moments when a previously failed `startRouter` might now succeed.
    /// Drives event-driven recovery instead of blind polling.
    func routerEvents() async -> AsyncStream<Void>
}
