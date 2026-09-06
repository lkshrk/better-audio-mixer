import AudioEngine
import BamControlKit
import BamCore
import Foundation
import Observation
import os
import SwiftUI

@MainActor
@Observable
final class ConsoleViewModel {
    var config = BamConfig()
    private(set) var snapshot: RouterSnapshot = .silent
    private(set) var runningApps: [AudioApp] = []
    private(set) var playing: Set<String> = []
    private(set) var outputDevices: [AudioDevice] = []
    private(set) var failedMixIDs: Set<String> = []
    private(set) var audioRecoveryDisplayState: AudioRecoveryDisplayState = .ok
    /// Dominant reason the router is not fully online, for surfacing in the UI
    /// (e.g. "waiting for permission" vs "no output device"). `.ok` /
    /// `.noSourcesRunning` are healthy/idle.
    private(set) var routerStatus: RouterStatus = .ok
    var error: String?

    /// Human-readable reason the router is offline, for the strip's Offline badge
    /// tooltip. nil when healthy or merely idle (no app producing audio).
    var routerStatusMessage: String? {
        switch routerStatus.cause {
        case .ok, .noSourcesRunning: return nil
        case .noOutput: return "No output device — connect or select one in the menu bar."
        case .permissionPending: return "Waiting for audio-capture permission. Accept the system prompt to come online."
        case .buildFailed: return "Audio engine couldn't start — retrying automatically."
        }
    }
    var activeMixID: String?
    var dark = true
    var openGroupID: String?

    /// Hidden dev switch: when off, the CoreAudio router (slot-claim + taps) is
    /// never started, so the machine keeps its normal sound while you work on the
    /// UI. Persisted in UserDefaults; env var BAM_DISABLE_DRIVER forces it off.
    var driverEnabled: Bool {
        didSet {
            guard driverEnabled != oldValue else { return }
            defaults.set(driverEnabled, forKey: Self.driverKey)
            Task { await self.reloadRouter() }
        }
    }
    static let driverKey = "bam.driverEnabled"

    let engine: any AudioEngineProtocol
    let defaults: UserDefaults
    var configURL: URL?
    private var meterTask: Task<Void, Never>?
    private var appsTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var recoveryCause: RouterFailureCause?
    private var recoveryGeneration = 0
    var recoverySleep: @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    var outputRampSleep: @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    private var routerEventTask: Task<Void, Never>?
    private var routerRecoveryEventTask: Task<Void, Never>?
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
    var requestedOutputVolumes: [String: Float] = [:]
    var rampOutputTargets: [String: Float] = [:]
    var stockOutputStates: [String: OutputDeviceState] = [:]
    var outputCalibrations: [String: OutputDeviceState] = [:]
    var routerWorkGeneration = 0

    /// The catch-all device. Its source is the `.rest` remainder; it routes every
    /// app not claimed by another device to the system default hardware output.
    static let defaultMixID = "mix-default"
    static let restSourceID = "src-rest"

    init(engine: any AudioEngineProtocol = CoreAudioEngine(),
         defaults: UserDefaults = .standard) {
        self.engine = engine
        self.defaults = defaults
        if ProcessInfo.processInfo.environment["BAM_DISABLE_DRIVER"] != nil {
            driverEnabled = false
        } else if defaults.object(forKey: Self.driverKey) != nil {
            driverEnabled = defaults.bool(forKey: Self.driverKey)
        } else {
            // Dev builds default the driver OFF so UI work keeps normal system
            // sound; the Release build installed to /Applications routes for real.
            #if DEBUG
            driverEnabled = false
            #else
            driverEnabled = true
            #endif
        }
        // Seed the fader from the level saved at last exit so it shows what it will
        // restore to, instead of flashing 100% before the async restore lands.
        if defaults.object(forKey: Self.savedVolumeKey) != nil {
            outputVolume = defaults.double(forKey: Self.savedVolumeKey)
        }
        AppLog.app.debug("initialized driverEnabled=\(self.driverEnabled, privacy: .public)")
    }

    var mixes: [Mix] { config.mixes }
    var sources: [Source] { config.sources }

    var activeMix: Mix? {
        if let id = activeMixID, let m = config.mixes.first(where: { $0.id == id }) { return m }
        return config.mixes.first
    }

    // MARK: lifecycle

    func start() async {
        AppLog.app.debug("start driverEnabled=\(self.driverEnabled, privacy: .public)")
        defaultOutputUID = await engine.defaultOutputUID()
        do {
            let (url, cfg) = try ConfigStore.loadOrSeed(seed: Self.seedYAML())
            configURL = url
            AppLog.config.info("loaded config url=\(url.path, privacy: .private) mixes=\(cfg.mixes.count, privacy: .public) sources=\(cfg.sources.count, privacy: .public)")
            if cfg.mixes.isEmpty && cfg.sources.isEmpty {
                config = Self.normalize(Self.seedConfig(), defaultOutput: defaultOutputUID)
            } else {
                config = Self.normalize(cfg, defaultOutput: defaultOutputUID)
            }
            persist(config)
        } catch {
            self.error = String(describing: error)
            AppLog.config.error("load failed: \(String(describing: error), privacy: .public)")
            config = Self.normalize(Self.seedConfig(), defaultOutput: defaultOutputUID)
        }
        if activeMixID == nil { activeMixID = config.mixes.first?.id }
        await captureStockVolume()
        // startRouterGuarded owns setup protection and restores only a safe route.
        await subscribe()
        startControlServer()
        await restoreOutputVolume()
    }

    /// Stand up the Stream Deck control socket and feed it the current snapshot at
    /// ~12fps. The server reads the latest pushed snapshot on its own timer, so a
    /// steady push keeps remote clients live without coupling to the router stream.
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
                try? await Task.sleep(for: .milliseconds(83))
            }
        }
    }

    /// Remember the device's *stock* volume — its level right now, before bam has
    /// touched anything — so exit can restore it once our taps are torn down and
    /// normal direct-to-device playback is back. Captured every launch; the device
    /// is left exactly as is (no dim, no mute) so the pre-setup window just plays at
    /// the user's own normal level.
    private func captureStockVolume() async {
        guard let uid = systemOutputUID else { return }
        guard let state = await captureOutputState(uid: uid) else { return }
        defaults.set(Double(state.volume), forKey: Self.stockVolumeKey)
    }

    /// Headless entry for previews/mocks: no disk, just drive the engine + meters.
    func startMock(config: BamConfig) async {
        defaultOutputUID = await engine.defaultOutputUID()
        self.config = Self.normalize(config, defaultOutput: defaultOutputUID)
        activeMixID = self.config.mixes.first?.id
        await captureStockVolume()
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

    /// Start or tear down the router live when the dev driver toggle flips.
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
        AppLog.router.debug("\(reason, privacy: .public)")
        await enqueueRouterWork { model in await model.startRouterReconciling() }.value
        subscribeRouterEvents()
        subscribeRouterRecoveryEvents()
        let stream = await engine.routerSnapshots()
        meterTask?.cancel()
        meterTask = Task { [weak self] in
            for await s in stream { self?.snapshot = s }
        }
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
    }

    private func startAppPolling() {
        appsTask?.cancel()
        appsTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                self.runningApps = await self.engine.runningAudioApps()
                self.outputDevices = await self.engine.outputDevices()
                self.playing = await self.engine.playingBundleIDs()
                await self.refreshOutputVolume()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Start the router, fold its status, then persist any output UID the engine
    /// had to re-bind: when the stored device re-enumerated under a new UID, the
    /// engine resolves it against the live list, and we write the resolved UID back
    /// so the Default mix points at the right device across restarts.
    private func startRouterReconciling() async {
        let generation = routerWorkGeneration
        let requestedDestination = config.mixes.first { $0.id == Self.defaultMixID }?.dest
        let status = await startRouterGuarded(config: config)
        guard generation == routerWorkGeneration, !Task.isCancelled, driverEnabled else { return }
        applyRouterStatus(status)
        guard !status.isFailure,
              let bound = await engine.boundOutputUID(),
              generation == routerWorkGeneration, !Task.isCancelled, driverEnabled,
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

    /// Fold a `startRouter` result into UI state and (re)arm cause-aware recovery.
    /// Single choke point for every router (re)start so status and recovery stay
    /// consistent no matter which path triggered the build.
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

    /// Recovery is cause-aware. The event subscription (`subscribeRouterEvents`)
    /// already retries the instant an app starts or a device appears, which heals
    /// `noOutput` and `noSourcesRunning` with no polling. The only cause an event
    /// can't catch is `permissionPending`: granting TCC fires no CoreAudio change.
    /// `buildFailed` can also be a transient HAL/aggregate failure with no later
    /// event. Both use a bounded backoff heartbeat (2→4→8→16→30s, capped) that
    /// stops as soon as the router comes online or the driver is turned off.
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
            var delay: UInt64 = 2
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
                delay = min(delay * 2, 30)
            }
        }
    }

    /// Retry the router the moment the system changes in a way that could let a
    /// previously failed build succeed — an app starting (process-list change) or
    /// an output device appearing (device-list change). Replaces blind polling for
    /// `noOutput`/`noSourcesRunning`. One long-lived subscription per router start.
    private func subscribeRouterEvents() {
        routerEventTask?.cancel()
        routerEventTask = Task { [weak self] in
            guard let self else { return }
            let events = await self.engine.routerEvents()
            for await _ in events {
                guard !Task.isCancelled, self.driverEnabled else { return }
                AppLog.router.debug("router event received; reconciling")
                // Reflect device add/remove in the picker immediately instead of
                // waiting on the 2s poll.
                self.outputDevices = await self.engine.outputDevices()
                // Await the queued pass so the newest-only stream bounds pending
                // invalidations instead of turning each one into another Task.
                await self.enqueueRouterWork { model in
                    let checkedConfig = model.config
                    let unchanged = await model.engine.canKeepCurrentRouter(config: checkedConfig)
                    guard !Task.isCancelled else { return }
                    let relevantOutputs = await model.engine.routerOutputUIDs(config: checkedConfig)
                    if unchanged, model.config == checkedConfig,
                       relevantOutputs.isDisjoint(with: model.guardedOutputs.keys) { return }
                    await model.startRouterReconciling()
                }.value
            }
        }
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
        controlPushTask?.cancel(); controlPushTask = nil
        controlServer?.stop(); controlServer = nil
        stopRouterSubscriptions()
        await drainRouterWork()
        appsTask?.cancel(); appsTask = nil
        _ = await stopRouterGuarded()
    }

    // MARK: master (the routed hardware device's own OS volume)

    /// Volume scalar (0…1) of the hardware device the Default output feeds. The
    /// master fader reads/writes this — i.e. it is the physical output's slider.
    /// Seeded from the value saved at last exit so the fader shows the level it
    /// will restore to, instead of flashing 100% before the async restore lands.
    var outputVolume: Double = 1.0

    /// The level to run the device at *while bam is live* (the summed-mix master).
    /// Saved on exit (the current level), restored on launch once setup is ready.
    static let savedVolumeKey = "bam.savedOutputVolume"

    /// The device's *stock* level for normal, no-bam playback. Saved at launch
    /// (before bam touches the volume), restored on exit after teardown.
    static let stockVolumeKey = "bam.stockVolume"

    /// dBFS bar a source must clear to count as *real* captured audio. The taps
    /// deliver exact silence (level == floorDB, -120) until the capture-permission
    /// grant lands; at -55 we're safely above any startup/denormal noise yet well
    /// below normal program level (-30…-12), so this never false-positives on the
    /// pre-permission silence that caused the launch volume spike.
    static let captureConfirmDB: Float = -55

    /// True while `restoreOutputVolume()` is holding the device dimmed waiting for
    /// the capture-permission grant. The periodic poll must not surface that
    /// transient dim on the fader — the fader should keep showing the user's level.
    var restoringVolume = false

    struct GuardedOutput {
        var state: OutputDeviceState
        let calibration: OutputDeviceState
        var volume: Float {
            get { state.volume }
            set { state.volumes = calibration.withVolume(newValue).volumes }
        }
        var muted: Bool {
            get { state.muted }
            set { state.mutes = newValue ? state.mutes.mapValues { _ in true } : calibration.mutes }
        }
    }
    // Keep user intent across failed rebuilds; HAL may reset the hardware to 100%.
    var guardedOutputs: [String: GuardedOutput] = [:]

    /// True once this session has actually taken authority over the device volume —
    /// i.e. `restoreOutputVolume()` ran to completion (applied the saved bam level,
    /// or owned a fresh device with no saved level). Exit only persists the running
    /// level / resets to stock when this is true; otherwise (capture never confirmed,
    /// restore cancelled) it leaves the saved level untouched so a half-finished
    /// session can't clobber it with a stock/dimmed reading.
    var bamVolumeApplied = false

    // MARK: apply

    func applyTopology(_ mutate: (inout BamConfig) -> Void) { apply(topology: true, mutate) }
    func applyGains(_ mutate: (inout BamConfig) -> Void) { apply(topology: false, mutate) }

    private func apply(topology: Bool, _ mutate: (inout BamConfig) -> Void) {
        var draft = config
        mutate(&draft)
        do { try draft.validate() } catch {
            self.error = String(describing: error)
            return
        }
        error = nil
        config = draft
        persist(draft)
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
            guard !Task.isCancelled, generation == model.routerWorkGeneration else { return }
            model.applyRouterStatus(status)
        }
    }

    @discardableResult
    func enqueueRouterWork(requiresDriver: Bool = true, isControlUpdate: Bool = false,
                           _ work: @escaping @MainActor (ConsoleViewModel) async -> Void) -> Task<Void, Never> {
        // Every serialized operation is a boundary: a gain snapshot must never
        // cross a later topology mutation and put its old routes back.
        if !isControlUpdate {
            pendingGains = nil
            pendingOutputTargets = nil
        }
        let previous = routerMutationTask
        let generation = routerWorkGeneration
        routerMutationTask = Task { [weak self] in
            await previous?.value
            guard let self, (!requiresDriver || self.driverEnabled), !Task.isCancelled,
                  self.routerWorkGeneration == generation else { return }
            await work(self)
        }
        return routerMutationTask!
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

    func pendingRouterWorkForExit() -> Task<Void, Never>? {
        routerMutationTask?.cancel()
        return routerMutationTask
    }

    func persist(_ cfg: BamConfig) {
        guard let url = configURL else { return }
        do { try ConfigStore.save(cfg, to: url) } catch let err { self.error = String(describing: err) }
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

    /// Guarantee a Default catch-all mix exists first. Seed an unset hardware
    /// choice from macOS once; preserve the user's BAM output on later starts.
    static func normalize(_ cfg: BamConfig, defaultOutput: String?) -> BamConfig {
        var c = cfg
        if !c.sources.contains(where: { $0.kind == .rest }) {
            c.sources.insert(Source(id: restSourceID, name: "Default", kind: .rest), at: 0)
        }
        let restID = c.sources.first { $0.kind == .rest }!.id
        let dest: MixDestination = defaultOutput.map { .hardware(uid: $0) } ?? .virtualSlot(0)
        if let di = c.mixes.firstIndex(where: { $0.id == defaultMixID }) {
            c.mixes[di].name = "Default"
            if case .virtualSlot = c.mixes[di].dest { c.mixes[di].dest = dest }
            if !c.mixes[di].sends.contains(where: { $0.source == restID }) {
                // Tapped (so the app's own output is muted) but not passed through:
                // ungrouped audio is silenced until the user assigns it to a device.
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
struct SourceApp: Identifiable {
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
