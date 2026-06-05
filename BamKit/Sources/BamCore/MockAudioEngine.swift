import Foundation

public actor MockAudioEngine: AudioEngineProtocol {
    private var task: Task<Void, Never>?
    private var groups: [Group] = []

    /// When true, the router meter stream reports floor-level (silent) sources —
    /// simulating taps that are running but not yet capturing (e.g. before the
    /// capture-permission popup is accepted). Lets tests exercise the launch
    /// volume-restore gate without real CoreAudio.
    private let silentRouter: Bool

    public init(silentRouter: Bool = false) {
        self.silentRouter = silentRouter
    }

    public func start(config: BamConfig) -> AsyncStream<MeterSnapshot> {
        groups = config.groups
        return AsyncStream { continuation in
            let t = Task { [weak self] in
                var phase: Float = 0
                while !Task.isCancelled {
                    guard let self else { break }
                    phase += 0.15
                    let groups = await self.groups
                    continuation.yield(Self.snapshot(groups: groups, phase: phase))
                    try? await Task.sleep(for: .milliseconds(100))
                }
                continuation.finish()
            }
            self.task = t
            continuation.onTermination = { _ in t.cancel() }
        }
    }

    public func update(config: BamConfig) {
        groups = config.groups
    }

    public func applyGains(config: BamConfig) {
        groups = config.groups
    }

    public func setEnforce(_ on: Bool) {}

    public func outputDevices() -> [AudioDevice] {
        [AudioDevice(uid: "MockOutput", name: "Built-in Output")]
    }

    public func defaultOutputUID() -> String? { "MockOutput" }

    public func boundOutputUID() -> String? { "MockOutput" }

    private var mockVolume: Float = 0.8
    public func outputVolume(uid: String) -> Float? { mockVolume }
    public func setOutputVolume(uid: String, _ volume: Float) { mockVolume = max(0, min(1, volume)) }

    private var mockMuted = false
    public func outputMuted(uid: String) -> Bool { mockMuted }
    public func setOutputMuted(uid: String, _ muted: Bool) { mockMuted = muted }

    public func runningAudioApps() -> [AudioApp] {
        groups.flatMap(\.bundleIDs).map {
            AudioApp(bundleID: $0, displayName: $0.components(separatedBy: ".").last ?? $0)
        }
    }

    public func playingBundleIDs() -> Set<String> { Set(groups.flatMap(\.bundleIDs)) }

    public func stop() {
        task?.cancel()
        task = nil
    }

    // MARK: v3 router (mock)

    private var routerConfig: BamConfig?
    private var routerTask: Task<Void, Never>?

    /// Test hook: statuses returned by successive `startRouter` calls. Each call
    /// pops the front; once drained, `.ok`. Empty by default → mock returns `.ok`
    /// as before, so previews are unaffected.
    private var scriptedRouterStatuses: [RouterStatus] = []
    public func scriptRouterStatuses(_ statuses: [RouterStatus]) {
        scriptedRouterStatuses = statuses
    }
    public private(set) var startRouterCalls = 0

    public func startRouter(config: BamConfig) -> RouterStatus {
        routerConfig = config
        startRouterCalls += 1
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

    private static func snapshot(groups: [Group], phase: Float) -> MeterSnapshot {
        func level(_ seed: Float) -> Float {
            let amp = (sin(phase + seed) * 0.5 + 0.5)
            return RMSMeter.dbFS(rms: 0.0005 + amp * 0.7)
        }
        let groupMeters: [GroupMeter] = groups.enumerated().map { i, g in
            let sources = g.bundleIDs.enumerated().map { j, bid in
                SourceMeter(
                    bundleID: bid,
                    displayName: bid.components(separatedBy: ".").last ?? bid,
                    deviceUID: "MockOutput",
                    deviceName: "Built-in Output",
                    level: level(Float(i * 3 + j))
                )
            }
            return GroupMeter(
                name: g.name,
                volume: g.volume,
                muted: g.muted,
                level: RMSMeter.combine(sources.map(\.level)),
                sources: sources,
                isUnassignedBucket: g.includesUnassigned
            )
        }
        let unassigned: GroupMeter? = groups.contains(where: \.includesUnassigned) ? nil : GroupMeter(
            name: "All Audio",
            volume: 1.0,
            muted: false,
            level: level(50),
            sources: [],
            isUnassignedBucket: true
        )
        return MeterSnapshot(master: level(99), groups: groupMeters, unassigned: unassigned)
    }
}
