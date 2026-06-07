import Foundation

public actor MockAudioEngine: AudioEngineProtocol {
    public enum Call: Equatable, Sendable {
        case setOutputVolume(uid: String, volume: Float)
        case setOutputMuted(uid: String, muted: Bool)
        case startRouter
    }

    public private(set) var calls: [Call] = []

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

    public func boundOutputUID() -> String? { "MockOutput" }

    private var mockVolume: Float = 0.8
    public func outputVolume(uid: String) -> Float? { mockVolume }
    public func setOutputVolume(uid: String, _ volume: Float) {
        let clamped = max(0, min(1, volume))
        calls.append(.setOutputVolume(uid: uid, volume: clamped))
        mockVolume = clamped
    }

    private var mockMuted = false
    public func outputMuted(uid: String) -> Bool { mockMuted }
    public func setOutputMuted(uid: String, _ muted: Bool) {
        calls.append(.setOutputMuted(uid: uid, muted: muted))
        mockMuted = muted
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
        AsyncStream { continuation in
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
        routerConfig = config
    }

    public func stopRouter() {
        routerTask?.cancel()
        routerTask = nil
        routerConfig = nil
    }

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
