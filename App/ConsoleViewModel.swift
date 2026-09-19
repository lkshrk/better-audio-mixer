import AudioEngine
import BamControlKit
import BamCore
import Foundation
import Observation
import os
import SwiftUI

enum Tuning {
    static let controlPushInterval: Duration = .milliseconds(33)
    static let appPollInterval: Duration = .seconds(2)
    static let persistDebounce: Duration = .milliseconds(300)
    static let rampSteps = 24
    static let rampStepDelay: Duration = .milliseconds(50)
    static let exitTeardownTimeout: Duration = .seconds(4)
    static let recoveryBackoffFloorSeconds: UInt64 = 2
    static let recoveryBackoffCapSeconds: UInt64 = 30
    static let faderChangeInterval: TimeInterval = 1.0 / 30
    static let titleBarHeight: CGFloat = 38
}

@MainActor
@Observable
final class ConsoleViewModel {
    var config = BamConfig()
    private(set) var snapshot: RouterSnapshot = .silent
    private(set) var mixPeaks: [String: StereoPeak] = [:]
    private(set) var masterPeak = StereoPeak()
    var now: () -> TimeInterval = { Date.timeIntervalSinceReferenceDate }
    private(set) var runningApps: [AudioApp] = []
    private(set) var playing: Set<String> = []
    private(set) var outputDevices: [AudioDevice] = []
    private(set) var failedMixIDs: Set<String> = []
    private(set) var audioRecoveryDisplayState: AudioRecoveryDisplayState = .ok
    private(set) var routerStatus: RouterStatus = .ok
    var error: String?
    /// Sticks for the session, unlike `error`, which the next successful apply clears.
    private(set) var configWarning: String?

    var routerStatusMessage: String? {
        switch routerStatus.cause {
        case .ok, .noSourcesRunning: return nil
        case .noOutput: return "No output device — connect or select one in the menu bar."
        case .permissionPending: return "Waiting for audio-capture permission. Accept the system prompt to come online."
        case .buildFailed: return "Audio engine couldn't start — retrying automatically."
        }
    }
    var activeMixID: String?

    /// Dev switch: off keeps the CoreAudio router down so the machine keeps its normal sound; BAM_DISABLE_DRIVER forces it off.
    var driverEnabled: Bool {
        didSet {
            guard driverEnabled != oldValue else { return }
            defaults.set(driverEnabled, forKey: Self.driverKey)
            scheduleRouterReload()
        }
    }
    static let driverKey = "bam.driverEnabled"

    let engine: any AudioEngineProtocol
    let defaults: UserDefaults
    let protection: OutputProtection
    var configURL: URL?
    private var meterTask: Task<Void, Never>?
    private var appsTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var recoveryCause: RouterFailureCause?
    private var recoveryGeneration = 0
    var recoverySleep: @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    private var routerEventTask: Task<Void, Never>?
    private var routerRecoveryEventTask: Task<Void, Never>?
    private var reloadTask: Task<Void, Never>?
    private var persistTask: Task<Void, Never>?
    private var pendingPersist: BamConfig?
    private var defaultOutputUID: String?
    var controlServer: ControlServer?
    private var controlPushTask: Task<Void, Never>?
    private var routerMutationTask: Task<Void, Never>?
    private final class GainTargets {
        var config: BamConfig
        init(_ config: BamConfig) { self.config = config }
    }
    private var pendingGains: GainTargets?
    final class OutputTargets {
        var volumes: [String: Float] = [:]
        var muteUIDs: Set<String> = []
    }
    var pendingOutputTargets: OutputTargets?
    var routerWorkGeneration = 0
    // Once set, queued router work never runs again: a late startup rebuild must not re-mute after the exit restore.
    private(set) var exiting = false

    /// The catch-all device: its `.rest` source routes every unclaimed app to the system default output.
    static let defaultMixID = "mix-default"
    static let restSourceID = "src-rest"

    init(engine: any AudioEngineProtocol = CoreAudioEngine(),
         defaults: UserDefaults = .standard) {
        self.engine = engine
        self.defaults = defaults
        protection = OutputProtection(engine: engine, defaults: defaults)
        if ProcessInfo.processInfo.environment["BAM_DISABLE_DRIVER"] != nil {
            driverEnabled = false
        } else if defaults.object(forKey: Self.driverKey) != nil {
            driverEnabled = defaults.bool(forKey: Self.driverKey)
        } else {
            #if DEBUG
            driverEnabled = false
            #else
            driverEnabled = true
            #endif
        }
        if defaults.object(forKey: Self.savedVolumeKey) != nil {
            outputVolume = defaults.double(forKey: Self.savedVolumeKey)
        }
        protection.onVolumeWritten = { [weak self] uid, volume in
            guard let self, uid == self.systemOutputUID else { return }
            self.outputVolume = Double(volume)
        }
        AppLog.app.debug("initialized driverEnabled=\(self.driverEnabled, privacy: .public)")
    }

    // MARK: lifecycle

    func start() async {
        AppLog.app.debug("start driverEnabled=\(self.driverEnabled, privacy: .public)")
        defaultOutputUID = await engine.defaultOutputUID()
        loadConfig()
        if activeMixID == nil { activeMixID = config.mixes.first?.id }
        stageSavedOutputVolume()
        await captureStockOutputState()
        await subscribe()
        startControlServer()
    }

    private func loadConfig() {
        do {
            let (url, cfg) = try ConfigStore.loadOrSeed(seed: Self.seedYAML())
            configURL = url
            AppLog.config.info("loaded config url=\(url.path, privacy: .private) mixes=\(cfg.mixes.count, privacy: .public) sources=\(cfg.sources.count, privacy: .public)")
            let base = cfg.mixes.isEmpty && cfg.sources.isEmpty ? Self.seedConfig() : cfg
            config = Self.normalize(base, defaultOutput: defaultOutputUID)
            if config != cfg { persist(config) }
        } catch {
            AppLog.config.error("load failed: \(String(describing: error), privacy: .public)")
            config = Self.normalize(Self.seedConfig(), defaultOutput: defaultOutputUID)
            guard let url = try? ConfigStore.defaultURL(), FileManager.default.fileExists(atPath: url.path) else {
                self.error = String(describing: error)
                return
            }
            let broken = Self.quarantineURL(for: url)
            do {
                try FileManager.default.moveItem(at: url, to: broken)
            } catch let moveError {
                self.error = String(describing: moveError)
                return
            }
            configURL = url
            configWarning = "Config couldn't be read and was reset; the original is kept as \(broken.lastPathComponent)."
            persist(config)
        }
    }

    static func quarantineURL(for url: URL, date: Date = .now) -> URL {
        let stamp = date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "-")
        return url.appendingPathExtension("broken-\(stamp)")
    }

    private func startControlServer() {
        let server = ControlServer()
        server.mixer = self
        server.start()
        controlServer = server
        AppLog.control.debug("control server starting")
        controlPushTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                self.controlServer?.pushSnapshot(self.controlSnapshot)
                try? await Task.sleep(for: Tuning.controlPushInterval)
            }
        }
    }

    /// Records the device's pre-bam state so exit can put it back once taps are gone.
    private func captureStockOutputState() async {
        guard let uid = systemOutputUID else { return }
        _ = await protection.capture(uid: uid)
    }

    /// Headless entry for previews/mocks: no disk, just drive the engine + meters.
    func startMock(config: BamConfig) async {
        defaultOutputUID = await engine.defaultOutputUID()
        self.config = Self.normalize(config, defaultOutput: defaultOutputUID)
        activeMixID = self.config.mixes.first?.id
        stageSavedOutputVolume()
        await captureStockOutputState()
        await subscribe()
    }

    private func subscribe() async {
        if driverEnabled {
            await startRouterSubscriptions(reason: "subscribing router")
        } else {
            enterSilentRouterState(reason: "router disabled; using silent snapshot")
        }
        startAppPolling()
    }

    private func scheduleRouterReload() {
        reloadTask?.cancel()
        let previous = reloadTask
        reloadTask = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            await self.reloadRouter()
        }
    }

    private func reloadRouter() async {
        if driverEnabled {
            await startRouterSubscriptions(reason: "reload starting router")
        } else {
            stopRouterSubscriptions(reason: "reload stopping router")
            await drainRouterWork()
            guard await stopRouterGuarded() else {
                applyRouterStatus(RouterStatus(cause: .buildFailed))
                return
            }
            enterSilentRouterState(reason: nil)
        }
    }

    private func startRouterSubscriptions(reason: StaticString) async {
        guard !exiting else { return }
        AppLog.router.debug("\(reason, privacy: .public)")
        await enqueueRouterWork { model in await model.startRouterReconciling() }.value
        subscribeRouterEvents()
        subscribeRouterRecoveryEvents()
        let stream = await engine.routerSnapshots()
        meterTask?.cancel()
        meterTask = Task { [weak self] in
            for await s in stream {
                guard let self else { return }
                self.receiveSnapshot(s)
            }
        }
    }

    /// Peaks decay on every tick; `snapshot` and the peaks are assigned only when they actually changed.
    func receiveSnapshot(_ s: RouterSnapshot) {
        if s != snapshot { snapshot = s }
        let t = now()
        var peaks: [String: StereoPeak] = [:]
        for m in s.mixes {
            var p = mixPeaks[m.id] ?? StereoPeak()
            p.update(left: m.levelLeft, right: m.levelRight, at: t)
            peaks[m.id] = p
        }
        if peaks != mixPeaks { mixPeaks = peaks }
        var master = masterPeak
        master.update(left: masterMeterLeft, right: masterMeterRight, at: t)
        if master != masterPeak { masterPeak = master }
    }

    private func stopRouterSubscriptions(reason: StaticString? = nil) {
        if let reason {
            AppLog.router.debug("\(reason, privacy: .public)")
        }
        recoveryTask?.cancel(); recoveryTask = nil
        recoveryCause = nil
        recoveryGeneration += 1
        routerEventTask?.cancel(); routerEventTask = nil
        routerRecoveryEventTask?.cancel(); routerRecoveryEventTask = nil
        meterTask?.cancel(); meterTask = nil
    }

    private func enterSilentRouterState(reason: StaticString?) {
        if let reason {
            AppLog.router.debug("\(reason, privacy: .public)")
        }
        applyRouterStatus(.ok)
        audioRecoveryDisplayState = .ok
        snapshot = .silent
        mixPeaks = [:]
        masterPeak = StereoPeak()
    }

    private func startAppPolling() {
        appsTask?.cancel()
        appsTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                await self.refreshAppState()
                try? await Task.sleep(for: Tuning.appPollInterval)
            }
        }
    }

    func refreshAppState() async {
        let apps = await engine.runningAudioApps()
        if apps != runningApps { runningApps = apps }
        let devices = await engine.outputDevices()
        if devices != outputDevices { outputDevices = devices }
        let playingNow = await engine.playingBundleIDs()
        if playingNow != playing { playing = playingNow }
        await refreshOutputVolume()
    }

    /// Starts the router and writes back the UID the engine actually bound, so a re-enumerated device sticks across restarts.
    private func startRouterReconciling() async {
        let generation = routerWorkGeneration
        let requestedDestination = config.mixes.first { $0.id == Self.defaultMixID }?.dest
        let status = await startRouterGuarded(config: config)
        guard !routerWorkStale(generation), driverEnabled else { return }
        applyRouterStatus(status)
        guard !status.isFailure,
              let bound = await engine.boundOutputUID(),
              !routerWorkStale(generation), driverEnabled,
              let i = config.mixes.firstIndex(where: { $0.id == Self.defaultMixID }),
              config.mixes[i].dest == requestedDestination
        else { return }
        let current: String? = {
            if case .hardware(let u) = config.mixes[i].dest { return u } else { return nil }
        }()
        guard current != bound else { return }
        config.mixes[i].dest = .hardware(uid: bound)
        persist(config)
    }

    /// Single choke point for every router (re)start so status and recovery stay consistent.
    func applyRouterStatus(_ status: RouterStatus) {
        let previous = routerStatus
        routerStatus = status
        failedMixIDs = Set(status.failedMixIDs)
        if previous != status {
            let level: OSLogType = status.isFailure ? .error : .default
            if status.isFailure {
                AppLog.router.log(
                    level: level,
                    "status cause=\(status.cause.rawValue, privacy: .public) failedMixes=\(status.failedMixIDs.count, privacy: .public)"
                )
            } else {
                AppLog.router.debug(
                    "status cause=\(status.cause.rawValue, privacy: .public) failedMixes=\(status.failedMixIDs.count, privacy: .public)"
                )
            }
        }
        if status.cause == .ok || status.cause == .noSourcesRunning {
            audioRecoveryDisplayState = .ok
        }
        scheduleRouterRecovery(for: status)
    }

    /// Router events heal `noOutput`/`noSourcesRunning`; a TCC grant or transient HAL failure fires none, so those two causes get a bounded backoff heartbeat.
    private func scheduleRouterRecovery(for status: RouterStatus) {
        if driverEnabled, recoveryTask != nil, recoveryCause == status.cause { return }
        recoveryTask?.cancel(); recoveryTask = nil
        recoveryCause = nil
        recoveryGeneration += 1
        guard driverEnabled, status.cause == .permissionPending || status.cause == .buildFailed else { return }
        let cause = status.cause
        let heartbeatGeneration = recoveryGeneration
        recoveryCause = cause
        AppLog.router.debug("router recovery heartbeat scheduled cause=\(cause.rawValue, privacy: .public)")
        recoveryTask = Task { [weak self] in
            var delay = Tuning.recoveryBackoffFloorSeconds
            while !Task.isCancelled {
                guard let sleep = self?.recoverySleep else { return }
                do { try await sleep(.seconds(Double(delay))) } catch { return }
                guard let self, self.driverEnabled, !Task.isCancelled else { return }
                AppLog.router.debug("router recovery heartbeat cause=\(cause.rawValue, privacy: .public) delay=\(delay, privacy: .public)s")
                await self.enqueueRouterWork { model in
                    guard !Task.isCancelled, model.recoveryGeneration == heartbeatGeneration else { return }
                    await model.startRouterReconciling()
                }.value
                if self.routerStatus.cause != cause { return }
                delay = min(delay * 2, Tuning.recoveryBackoffCapSeconds)
            }
        }
    }

    private func subscribeRouterEvents() {
        routerEventTask?.cancel()
        routerEventTask = Task { [weak self] in
            guard let self else { return }
            let events = await self.engine.routerEvents()
            for await _ in events {
                guard !Task.isCancelled, self.driverEnabled else { return }
                AppLog.router.debug("router event received")
                await self.reconcileRouterIfNeeded()
            }
        }
    }

    /// Rebuilds only when the live router can no longer serve `config`.
    func reconcileRouterIfNeeded() async {
        let devices = await engine.outputDevices()
        if devices != outputDevices { outputDevices = devices }
        await enqueueRouterWork { model in
            // Failed builds emit HAL events during their own teardown; the heartbeat owns that retry.
            guard model.routerStatus.cause != .buildFailed else { return }
            let checkedConfig = model.config
            let unchanged = await model.engine.canKeepCurrentRouter(config: checkedConfig)
            guard !Task.isCancelled else { return }
            let relevantOutputs = await model.engine.routerOutputUIDs(config: checkedConfig)
            if unchanged, model.config == checkedConfig,
               relevantOutputs.isDisjoint(with: model.protection.guarded.keys) { return }
            await model.startRouterReconciling()
        }.value
    }

    func systemDidWake() {
        guard driverEnabled else { return }
        AppLog.router.debug("system woke; reconciling")
        Task { await reconcileRouterIfNeeded() }
    }

    private func subscribeRouterRecoveryEvents() {
        routerRecoveryEventTask?.cancel()
        routerRecoveryEventTask = Task { [weak self] in
            guard let self else { return }
            let events = await self.engine.routerRecoveryEvents()
            for await event in events {
                guard !Task.isCancelled, self.driverEnabled else { return }
                self.applyRouterRecoveryEvent(event)
            }
        }
    }

    private func applyRouterRecoveryEvent(_ event: RouterRecoveryEvent) {
        switch event {
        case .attempting(let reason, let attempt):
            AppLog.router.warning("recovery attempting reason=\(reason, privacy: .public) attempt=\(attempt, privacy: .public)")
            audioRecoveryDisplayState = .recovering(reason: reason, attempt: attempt)
        case .paused(let reason, let attempts, let window, let cooldown):
            AppLog.router.error("recovery paused reason=\(reason, privacy: .public) attempts=\(attempts, privacy: .public) window=\(window, privacy: .public) cooldown=\(cooldown, privacy: .public)")
            audioRecoveryDisplayState = .paused(
                reason: reason,
                attempts: attempts,
                window: Self.shortDuration(window),
                cooldown: Self.shortDuration(cooldown)
            )
        case .recovered:
            AppLog.router.debug("recovery cleared")
            audioRecoveryDisplayState = .ok
        }
    }

    static func shortDuration(_ seconds: TimeInterval) -> String {
        let rounded = max(1, Int(seconds.rounded()))
        if rounded % 60 == 0 {
            let minutes = rounded / 60
            return "\(minutes) min"
        }
        if rounded < 60 {
            return "\(rounded) sec"
        }
        let minutes = rounded / 60
        let remainder = rounded % 60
        return remainder == 0 ? "\(minutes) min" : "\(minutes)m \(remainder)s"
    }

    func restartAudio() async {
        AppLog.router.notice("manual restart requested")
        await enqueueRouterWork { model in
            await model.engine.resetRouterRecovery()
            model.audioRecoveryDisplayState = .ok
            await model.startRouterReconciling()
        }.value
    }

    func stop() async {
        AppLog.app.debug("stop")
        flushPersist()
        controlPushTask?.cancel(); controlPushTask = nil
        controlServer?.stop(); controlServer = nil
        reloadTask?.cancel()
        await reloadTask?.value
        reloadTask = nil
        stopRouterSubscriptions()
        await drainRouterWork()
        appsTask?.cancel(); appsTask = nil
        _ = await stopRouterGuarded()
    }

    /// Bounded exit: saves the running level, flags the exit mute, then restores the stock output state.
    func prepareForExit() async -> Bool {
        AppLog.app.debug("prepare for exit")
        exiting = true
        flushPersist()
        controlPushTask?.cancel(); controlPushTask = nil
        controlServer?.stop(); controlServer = nil
        reloadTask?.cancel(); reloadTask = nil
        stopRouterSubscriptions()
        appsTask?.cancel(); appsTask = nil
        if bamVolumeApplied, let uid = systemOutputUID, let state = await protection.capture(uid: uid) {
            switch VolumePolicy.exit(applied: true, currentDeviceLevel: Double(state.volume), stockLevel: nil) {
            case .teardownOnly: break
            case let .persist(level, _): defaults.set(level, forKey: Self.savedVolumeKey)
            }
        }
        protection.markExitMuted()
        routerWorkGeneration += 1
        let teardown = Task { await self.teardownForExit() }
        let restored = await Self.awaitBounded(Tuning.exitTeardownTimeout, teardown) ?? false
        AppLog.app.log(level: restored ? .debug : .error, "exit teardown restored=\(restored, privacy: .public)")
        return restored
    }

    func teardownForExit() async -> Bool {
        await engine.setRouterRecoverySuspended(true)
        let retained = Set(protection.guarded.keys).union(protection.stockStates.keys)
        let uids = await protectedOutputUIDs(for: config, retaining: retained)
        guard await protection.protect(uids) else { return false }
        await drainRouterWork()
        guard await engine.stopRouterChecked() else { return false }
        var request = OutputProtection.RestoreRequest()
        request.toStock = true
        return await protection.restore(uids: uids, request)
    }

    /// Waits for `task` up to `timeout` without cancelling it: a late teardown must finish muted, not half-restored.
    nonisolated static func awaitBounded<T: Sendable>(_ timeout: Duration, _ task: Task<T, Never>) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await task.value }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    // MARK: master (the routed hardware device's own OS volume)

    /// Volume scalar (0…1) of the hardware device the Default output feeds; seeded from the saved level so the fader never flashes 100%.
    var outputVolume: Double = 1.0

    static let savedVolumeKey = "bam.savedOutputVolume"

    /// Only a successful protected start takes authority over the device volume; exit persists the running level only then.
    var bamVolumeApplied = false

    // MARK: apply

    func applyTopology(_ mutate: (inout BamConfig) -> Void) { apply(topology: true, mutate) }
    func applyGains(_ mutate: (inout BamConfig) -> Void) { apply(topology: false, mutate) }

    /// Live-drag path: routes the gain without persisting; `setDeviceLevel` persists on release.
    func previewDeviceLevel(_ mixID: String, _ level: Double) {
        apply(topology: false, persist: false) { cfg in
            if let i = cfg.mixes.firstIndex(where: { $0.id == mixID }) { cfg.mixes[i].level = level }
        }
    }

    private func apply(topology: Bool, persist shouldPersist: Bool = true, _ mutate: (inout BamConfig) -> Void) {
        var draft = config
        mutate(&draft)
        do { try draft.validate() } catch {
            self.error = String(describing: error)
            return
        }
        error = nil
        config = draft
        if shouldPersist { persist(draft) }
        guard driverEnabled else { return }
        enqueueRouterMutation(topology: topology, draft: draft)
    }

    private func enqueueRouterMutation(topology: Bool, draft: BamConfig) {
        if !topology {
            if let pendingGains {
                pendingGains.config = draft
                return
            }
            let targets = GainTargets(draft)
            enqueueRouterWork(isControlUpdate: true) { model in
                if model.pendingGains === targets { model.pendingGains = nil }
                await model.engine.updateRouterGains(config: targets.config)
            }
            pendingGains = targets
            return
        }
        enqueueRouterWork { model in
            let generation = model.routerWorkGeneration
            let status = await model.startRouterGuarded(config: draft)
            guard !model.routerWorkStale(generation) else { return }
            model.applyRouterStatus(status)
        }
    }

    func routerWorkStale(_ generation: Int) -> Bool {
        Task.isCancelled || generation != routerWorkGeneration
    }

    @discardableResult
    func enqueueRouterWork(requiresDriver: Bool = true, isControlUpdate: Bool = false,
                           _ work: @escaping @MainActor (ConsoleViewModel) async -> Void) -> Task<Void, Never> {
        // A gain snapshot must never cross a later topology mutation and put its old routes back.
        if !isControlUpdate {
            pendingGains = nil
            pendingOutputTargets = nil
        }
        let previous = routerMutationTask
        let generation = routerWorkGeneration
        let task = Task { [weak self] in
            await previous?.value
            guard let self, !self.exiting, (!requiresDriver || self.driverEnabled), !Task.isCancelled,
                  self.routerWorkGeneration == generation else { return }
            await work(self)
        }
        routerMutationTask = task
        return task
    }

    private func drainRouterWork() async {
        routerWorkGeneration += 1
        let pending = routerMutationTask
        pending?.cancel()
        await pending?.value
        routerMutationTask = nil
        pendingGains = nil
        pendingOutputTargets = nil
    }

    /// Coalesces bursts (Stream Deck nudges, fader drags) into one write; `flushPersist` writes now.
    func persist(_ cfg: BamConfig) {
        guard configURL != nil else { return }
        pendingPersist = cfg
        guard persistTask == nil else { return }
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: Tuning.persistDebounce)
            guard !Task.isCancelled else { return }
            self?.flushPersist()
        }
    }

    func flushPersist() {
        persistTask?.cancel()
        persistTask = nil
        guard let cfg = pendingPersist, let url = configURL else { return }
        pendingPersist = nil
        do { try ConfigStore.save(cfg, to: url) } catch { self.error = String(describing: error) }
    }

    func nextFreeSlot() -> Int {
        let used = Set(config.mixes.compactMap { mix -> Int? in
            if case .virtualSlot(let s) = mix.dest { return s } else { return nil }
        })
        var s = 0
        while used.contains(s) { s += 1 }
        return s
    }

    static func uniqueID(_ base: String, existing: [String]) -> String {
        let set = Set(existing)
        var n = 0
        while set.contains("\(base)\(n)") { n += 1 }
        return "\(base)\(n)"
    }

    private static func seedYAML() -> String {
        if let url = Bundle.main.url(forResource: "bam", withExtension: "yaml"),
           let text = try? String(contentsOf: url, encoding: .utf8) { return text }
        return "{}\n"
    }

    static func seedConfig() -> BamConfig { BamConfig() }

    /// Guarantees a Default catch-all mix exists first; seeds an unset hardware choice from macOS once and keeps the user's BAM output afterwards.
    static func normalize(_ cfg: BamConfig, defaultOutput: String?) -> BamConfig {
        var c = cfg
        let restID: String
        if let rest = c.sources.first(where: { $0.kind == .rest }) {
            restID = rest.id
        } else {
            restID = restSourceID
            c.sources.insert(Source(id: restID, name: "Default", kind: .rest), at: 0)
        }
        let dest: MixDestination = defaultOutput.map { .hardware(uid: $0) } ?? .virtualSlot(0)
        if let di = c.mixes.firstIndex(where: { $0.id == defaultMixID }) {
            c.mixes[di].name = "Default"
            if case .virtualSlot = c.mixes[di].dest { c.mixes[di].dest = dest }
            if !c.mixes[di].sends.contains(where: { $0.source == restID }) {
                // Tapped but muted: ungrouped audio stays silent until assigned to a device.
                c.mixes[di].sends.append(Send(source: restID, muted: true))
            }
        } else {
            c.mixes.insert(Mix(id: defaultMixID, name: "Default", dest: dest,
                               level: 0.5, sends: [Send(source: restID, muted: true)],
                               tone: Palette.hue(for: defaultMixID)), at: 0)
        }
        if let idx = c.mixes.firstIndex(where: { $0.id == defaultMixID }), idx != 0 {
            let m = c.mixes.remove(at: idx)
            c.mixes.insert(m, at: 0)
        }
        return c
    }
}

/// An app grouped under a source, resolved for the group panel UI.
struct SourceApp: Identifiable, Equatable {
    let bundleID: String
    let name: String
    let playing: Bool
    var id: String { bundleID }
    var mono: String { initials(name) }
    var color: Color { Palette.color(forID: bundleID) }
}

/// Two-letter identity monogram from a display name.
func initials(_ text: String) -> String {
    let parts = text.split(separator: " ").filter { !$0.isEmpty }
    if parts.count >= 2 { return "\(parts[0].prefix(1))\(parts[1].prefix(1))".uppercased() }
    return String(text.prefix(2)).uppercased()
}

extension Source {
    var chipMono: String { initials(monogram ?? name) }
    var chipColor: Color { Palette.color(hue: hue ?? Palette.hue(for: id)) }
}

extension Mix {
    var chipMono: String { initials(name) }
    var chipColor: Color { Palette.color(hue: tone ?? Palette.hue(for: id)) }
}
