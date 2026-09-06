import Foundation

public actor MockAudioEngine: AudioEngineProtocol {
    private var diagnostics: AudioDiagnostics?
    public func setAudioDiagnosticsForTests(_ value: AudioDiagnostics?) { diagnostics = value }
    public func audioDiagnostics() async -> AudioDiagnostics? { diagnostics }
    public enum Call: Equatable, Sendable {
        case setOutputVolume(uid: String, volume: Float)
        case setOutputMuted(uid: String, muted: Bool)
        case startRouter
        case updateRouterGains
    }

    public private(set) var calls: [Call] = []
    public private(set) var acknowledgedOutputRestores: [Set<String>] = []
    public func acknowledgeOutputRestore(uids: Set<String>) async { acknowledgedOutputRestores.append(uids) }

    public func resetCalls() {
        calls = []
    }

    /// When true, the router meter stream reports floor-level (silent) sources —
    /// simulating taps that are running but not yet capturing (e.g. before the
    /// capture-permission popup is accepted). Lets tests exercise the launch
    /// volume-restore gate without real CoreAudio.
    private let silentRouter: Bool

    public init(silentRouter: Bool = false) {
        self.silentRouter = silentRouter
    }

    public func outputDevices() -> [AudioDevice] {
        [AudioDevice(uid: "MockOutput", name: "Built-in Output")]
    }

    public func defaultOutputUID() -> String? { "MockOutput" }

    public func boundOutputUID() -> String? {
        routerConfig?.mixes.compactMap { if case .hardware(let uid) = $0.dest { uid } else { nil } }.first ?? "MockOutput"
    }
    public func routerOutputUIDs(config: BamConfig) async -> Set<String> {
        let uids = Set(config.mixes.compactMap { if case .hardware(let uid) = $0.dest { uid } else { nil } })
        return uids.isEmpty ? ["MockOutput"] : uids
    }

    private var mockVolumes: [String: Float] = [:]
    private var mockDeviceStates: [String: OutputDeviceState] = [:]
    public func setOutputDeviceStateForTests(_ state: OutputDeviceState) { mockDeviceStates[state.uid] = state }
    public func outputDeviceState(uid: String) async -> OutputDeviceState? {
        mockDeviceStates[uid] ?? OutputDeviceState(uid: uid, deviceID: 1,
                                                 volumes: [0: mockVolumes[uid] ?? 0.8],
                                                 mutes: [0: mockMutes[uid] ?? false])
    }
    public func restoreOutputDeviceState(_ state: OutputDeviceState, restoreVolume: Bool, restoreMute: Bool) async -> OutputWriteResult {
        guard var current = await outputDeviceState(uid: state.uid), current.deviceID == state.deviceID else { return .failed }
        if restoreVolume {
            guard checkedVolumeResult == .applied else { return checkedVolumeResult }
            guard Set(state.volumes.keys) == Set(current.volumes.keys),
                  state.volumes.values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return .failed }
            current.volumes = state.volumes
            calls.append(.setOutputVolume(uid: state.uid, volume: state.volume))
            mockVolumes[state.uid] = state.volume
        }
        if restoreMute {
            guard checkedMuteResult == .applied else { return checkedMuteResult }
            current.mutes = state.mutes
            calls.append(.setOutputMuted(uid: state.uid, muted: state.muted))
            mockMutes[state.uid] = state.muted
        }
        mockDeviceStates[state.uid] = current
        return .applied
    }
    public func outputVolume(uid: String) -> Float? { mockDeviceStates[uid]?.volume ?? mockVolumes[uid] ?? 0.8 }
    public func setOutputVolume(uid: String, _ volume: Float) {
        let clamped = max(0, min(1, volume))
        calls.append(.setOutputVolume(uid: uid, volume: clamped))
        mockVolumes[uid] = clamped
        if let state = mockDeviceStates[uid] { mockDeviceStates[uid]?.volumes = state.volumes.mapValues { _ in clamped } }
    }

    private var mockMutes: [String: Bool] = [:]
    public func outputMuted(uid: String) -> Bool { mockDeviceStates[uid]?.muted ?? mockMutes[uid] ?? false }
    public func setOutputMuted(uid: String, _ muted: Bool) {
        calls.append(.setOutputMuted(uid: uid, muted: muted))
        mockMutes[uid] = muted
        if let state = mockDeviceStates[uid] { mockDeviceStates[uid]?.mutes = state.mutes.mapValues { _ in muted } }
    }

    private var checkedMuteResult: OutputWriteResult = .applied
    private var checkedVolumeResult: OutputWriteResult = .applied
    private var keepCurrentRouter = false
    public func setCheckedWriteResults(mute: OutputWriteResult = .applied, volume: OutputWriteResult = .applied) {
        checkedMuteResult = mute
        checkedVolumeResult = volume
    }
    public func setCanKeepCurrentRouter(_ keep: Bool) { keepCurrentRouter = keep }
    public private(set) var canKeepCurrentRouterCalls = 0
    public func canKeepCurrentRouter(config: BamConfig) async -> Bool {
        canKeepCurrentRouterCalls += 1
        return keepCurrentRouter && routerConfig == config
    }
    public func setOutputMutedChecked(uid: String, _ muted: Bool) async -> OutputWriteResult {
        if checkedMuteResult == .applied { setOutputMuted(uid: uid, muted) }
        return checkedMuteResult
    }
    public func setOutputVolumeChecked(uid: String, _ volume: Float) async -> OutputWriteResult {
        if checkedVolumeResult == .applied { setOutputVolume(uid: uid, volume) }
        return checkedVolumeResult
    }

    public func runningAudioApps() -> [AudioApp] {
        routerConfig?.sources
            .flatMap(\.bundleIDs)
            .map { AudioApp(bundleID: $0, displayName: $0.components(separatedBy: ".").last ?? $0) }
        ?? []
    }

    public func playingBundleIDs() -> Set<String> {
        Set(routerConfig?.sources.flatMap(\.bundleIDs) ?? [])
    }

    public func stop() {
        stopRouter()
    }

    // MARK: v3 router (mock)

    private var routerConfig: BamConfig?
    private var routerTask: Task<Void, Never>?
    public var lastRouterConfig: BamConfig? { routerConfig }
    private var startRouterDelay: Duration?

    public func setStartRouterDelay(_ delay: Duration?) {
        startRouterDelay = delay
    }

    /// Test hook: statuses returned by successive `startRouter` calls. Each call
    /// pops the front; once drained, `.ok`. Empty by default → mock returns `.ok`
    /// as before, so previews are unaffected.
    private var scriptedRouterStatuses: [RouterStatus] = []
    public func scriptRouterStatuses(_ statuses: [RouterStatus]) {
        scriptedRouterStatuses = statuses
    }
    public private(set) var startRouterCalls = 0

    public func startRouter(config: BamConfig) async -> RouterStatus {
        if let startRouterDelay {
            try? await Task.sleep(for: startRouterDelay)
            if Task.isCancelled { return RouterStatus(cause: .ok) }
        }
        routerConfig = config
        startRouterCalls += 1
        calls.append(.startRouter)
        return scriptedRouterStatuses.isEmpty ? .ok : scriptedRouterStatuses.removeFirst()
    }

    private var routerEventSink: AsyncStream<Void>.Continuation?
    public func routerEvents() -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            routerEventSink = continuation
        }
    }

    /// Test hook: fire a router event (process/device list change) so recovery
    /// subscribers retry, mirroring the real engine's CoreAudio listeners.
    public func emitRouterEvent() {
        routerEventSink?.yield(())
    }

    private var routerRecoveryEventSink: AsyncStream<RouterRecoveryEvent>.Continuation?
    public private(set) var resetRouterRecoveryCalls = 0

    public func routerRecoveryEvents() -> AsyncStream<RouterRecoveryEvent> {
        AsyncStream { continuation in
            routerRecoveryEventSink = continuation
        }
    }

    public func emitRouterRecoveryEvent(_ event: RouterRecoveryEvent) {
        routerRecoveryEventSink?.yield(event)
    }

    public func resetRouterRecovery() {
        resetRouterRecoveryCalls += 1
        routerRecoveryEventSink?.yield(.recovered)
    }

    public func updateRouterGains(config: BamConfig) {
        calls.append(.updateRouterGains)
        routerConfig = config
    }

    public func stopRouter() {
        routerTask?.cancel()
        routerTask = nil
        routerConfig = nil
    }
    public func stopRouterChecked() async -> Bool { stopRouter(); return true }

    public func routerSnapshots() -> AsyncStream<RouterSnapshot> {
        AsyncStream { continuation in
            let t = Task { [weak self] in
                var phase: Float = 0
                while !Task.isCancelled {
                    guard let self else { break }
                    phase += 0.15
                    let cfg = await self.routerConfig
                    continuation.yield(Self.routerSnapshot(config: cfg, phase: phase, silent: self.silentRouter))
                    try? await Task.sleep(for: .milliseconds(33))
                }
                continuation.finish()
            }
            self.routerTask = t
            continuation.onTermination = { _ in t.cancel() }
        }
    }

    private static func routerSnapshot(config: BamConfig?, phase: Float, silent: Bool = false) -> RouterSnapshot {
        guard let config else { return .silent }
        func level(_ seed: Float) -> Float {
            if silent { return RMSMeter.floorDB }
            let amp = sin(phase + seed) * 0.5 + 0.5
            return RMSMeter.dbFS(rms: 0.0005 + amp * 0.7)
        }
        let sources = config.sources.enumerated().map { i, s in
            RouterSourceMeter(id: s.id, name: s.name, level: level(Float(i)))
        }
        let mixes = config.mixes.enumerated().map { i, m in
            MixMeter(id: m.id, name: m.name, level: level(Float(i) + 40))
        }
        return RouterSnapshot(sources: sources, mixes: mixes)
    }

}
