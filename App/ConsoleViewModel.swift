import AudioEngine
import BamControlKit
import BamCore
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class ConsoleViewModel {
    private(set) var config = BamConfig()
    private(set) var snapshot: RouterSnapshot = .silent
    private(set) var runningApps: [AudioApp] = []
    private(set) var playing: Set<String> = []
    private(set) var outputDevices: [AudioDevice] = []
    private(set) var failedMixIDs: Set<String> = []
    /// Dominant reason the router is not fully online, for surfacing in the UI
    /// (e.g. "waiting for permission" vs "no output device"). `.ok` /
    /// `.noSourcesRunning` are healthy/idle.
    private(set) var routerStatus: RouterStatus = .ok
    private(set) var error: String?

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

    private let engine: any AudioEngineProtocol
    private let defaults: UserDefaults
    private var configURL: URL?
    private var meterTask: Task<Void, Never>?
    private var appsTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var routerEventTask: Task<Void, Never>?
    private var defaultOutputUID: String?
    private var controlServer: ControlServer?
    private var controlPushTask: Task<Void, Never>?

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
    }

    var mixes: [Mix] { config.mixes }
    var sources: [Source] { config.sources }

    var activeMix: Mix? {
        if let id = activeMixID, let m = config.mixes.first(where: { $0.id == id }) { return m }
        return config.mixes.first
    }

    // MARK: lifecycle

    func start() async {
        defaultOutputUID = await engine.defaultOutputUID()
        do {
            let (url, cfg) = try ConfigStore.loadOrSeed(seed: Self.seedYAML())
            configURL = url
            if cfg.mixes.isEmpty && cfg.sources.isEmpty {
                config = Self.normalize(Self.seedConfig(), defaultOutput: defaultOutputUID)
            } else {
                config = Self.normalize(cfg, defaultOutput: defaultOutputUID)
            }
            persist(config)
        } catch {
            self.error = String(describing: error)
            config = Self.normalize(Self.seedConfig(), defaultOutput: defaultOutputUID)
        }
        if activeMixID == nil { activeMixID = config.mixes.first?.id }
        await captureStockVolume()
        // Creating the aggregate + taps triggers the same momentary 100% device-volume
        // reset as teardown does. Mute across setup, restore stock, then unmute — this
        // also clears any mute a previous interrupted exit may have stranded.
        let setupUID = driverEnabled ? systemOutputUID : nil
        if let setupUID { CoreAudioEngine.setDeviceMuted(uid: setupUID, true) }
        await subscribe()
        if let setupUID {
            let stock = defaults.object(forKey: Self.stockVolumeKey) != nil
                ? defaults.double(forKey: Self.stockVolumeKey) : nil
            if let stock { CoreAudioEngine.setDeviceVolume(uid: setupUID, Float(stock)) }
            CoreAudioEngine.setDeviceMuted(uid: setupUID, false)
        }
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
        guard let v = await engine.outputVolume(uid: uid) else { return }
        defaults.set(Double(v), forKey: Self.stockVolumeKey)
    }

    /// Headless entry for previews/mocks: no disk, just drive the engine + meters.
    func startMock(config: BamConfig) async {
        defaultOutputUID = await engine.defaultOutputUID()
        self.config = Self.normalize(config, defaultOutput: defaultOutputUID)
        activeMixID = self.config.mixes.first?.id
        await subscribe()
    }

    private func subscribe() async {
        if driverEnabled {
            await startRouterReconciling()
            subscribeRouterEvents()
            let stream = await engine.routerSnapshots()
            meterTask = Task { [weak self] in
                for await s in stream { self?.snapshot = s }
            }
        } else {
            applyRouterStatus(.ok)
            snapshot = .silent
        }
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

    /// Start or tear down the router live when the dev driver toggle flips.
    private func reloadRouter() async {
        if driverEnabled {
            await startRouterReconciling()
            subscribeRouterEvents()
            let stream = await engine.routerSnapshots()
            meterTask?.cancel()
            meterTask = Task { [weak self] in
                for await s in stream { self?.snapshot = s }
            }
        } else {
            recoveryTask?.cancel(); recoveryTask = nil
            routerEventTask?.cancel(); routerEventTask = nil
            meterTask?.cancel(); meterTask = nil
            await engine.stopRouter()
            applyRouterStatus(.ok)
            snapshot = .silent
        }
    }

    /// Start the router, fold its status, then persist any output UID the engine
    /// had to re-bind: when the stored device re-enumerated under a new UID, the
    /// engine resolves it against the live list, and we write the resolved UID back
    /// so the Default mix points at the right device across restarts.
    private func startRouterReconciling() async {
        applyRouterStatus(await engine.startRouter(config: config))
        guard let bound = await engine.boundOutputUID(),
              let i = config.mixes.firstIndex(where: { $0.id == Self.defaultMixID })
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
    private func applyRouterStatus(_ status: RouterStatus) {
        routerStatus = status
        failedMixIDs = Set(status.failedMixIDs)
        scheduleRouterRecovery(for: status)
    }

    /// Recovery is cause-aware. The event subscription (`subscribeRouterEvents`)
    /// already retries the instant an app starts or a device appears, which heals
    /// `noOutput` and `noSourcesRunning` with no polling. The only cause an event
    /// can't catch is `permissionPending`: granting TCC fires no CoreAudio change,
    /// so for that we run a bounded backoff heartbeat (2→4→8→16→30s, capped) that
    /// stops as soon as the router comes online or the driver is turned off.
    /// Non-permission causes don't poll at all — they wait for their event.
    private func scheduleRouterRecovery(for status: RouterStatus) {
        recoveryTask?.cancel(); recoveryTask = nil
        guard driverEnabled, status.cause == .permissionPending else { return }
        recoveryTask = Task { [weak self] in
            var delay: UInt64 = 2
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Double(delay)))
                guard let self, self.driverEnabled, !Task.isCancelled else { return }
                let next = await self.engine.startRouter(config: self.config)
                self.routerStatus = next
                self.failedMixIDs = Set(next.failedMixIDs)
                if next.cause != .permissionPending { return }   // online or moved to a cause the events own
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
                // Reflect device add/remove in the picker immediately instead of
                // waiting on the 2s poll.
                self.outputDevices = await self.engine.outputDevices()
                // Always re-run: the engine's aggregate-signature check makes this a
                // cheap no-op when the output and tap set are unchanged, but a HEALTHY
                // router must still rebuild when its bound output device re-enumerated
                // or the default-output target moved (the old gate skipped that case
                // and left the aggregate bound to a dead device → silent speaker).
                await self.startRouterReconciling()
            }
        }
    }

    func stop() async {
        controlPushTask?.cancel(); controlPushTask = nil
        controlServer?.stop(); controlServer = nil
        recoveryTask?.cancel(); recoveryTask = nil
        routerEventTask?.cancel(); routerEventTask = nil
        meterTask?.cancel(); meterTask = nil
        appsTask?.cancel(); appsTask = nil
        await engine.stopRouter()
    }

    // MARK: live meters

    func sourceLevel(_ id: String) -> Float {
        snapshot.sources.first { $0.id == id }?.level ?? RMSMeter.floorDB
    }

    func mixLevel(_ id: String) -> Float {
        snapshot.mixes.first { $0.id == id }?.level ?? RMSMeter.floorDB
    }

    // MARK: mix CRUD

    func selectMix(_ id: String) { activeMixID = id }

    func addMix() {
        let slot = nextFreeSlot()
        let id = Self.uniqueID("mix", existing: config.mixes.map(\.id))
        let mix = Mix(id: id, name: "Mix \(config.mixes.count + 1)",
                      dest: .virtualSlot(slot), tone: Palette.hue(for: id))
        applyTopology { $0.mixes.append(mix) }
        activeMixID = id
    }

    func deleteMix(_ id: String) {
        applyTopology { $0.mixes.removeAll { $0.id == id } }
        if activeMixID == id { activeMixID = config.mixes.first?.id }
    }

    func renameMix(_ id: String, to name: String) {
        let t = name.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        applyGains { if let i = $0.mixes.firstIndex(where: { $0.id == id }) { $0.mixes[i].name = t } }
    }

    func setMixMaster(_ id: String, _ level: Double) {
        applyGains { if let i = $0.mixes.firstIndex(where: { $0.id == id }) { $0.mixes[i].level = level } }
    }

    // MARK: system output (the hardware the Default device feeds)

    var systemOutputUID: String? {
        if case .hardware(let uid) = config.mixes.first(where: { $0.id == Self.defaultMixID })?.dest { return uid }
        return nil
    }

    var systemOutputName: String {
        guard let uid = systemOutputUID else { return "No Output" }
        return outputDevices.first { $0.uid == uid }?.name ?? "Output"
    }

    var systemOutputIcon: String {
        guard let uid = systemOutputUID else { return "speaker.slash.fill" }
        return outputDevices.first { $0.uid == uid }?.outputIcon ?? "hifispeaker.fill"
    }

    func setSystemOutput(_ uid: String) {
        let previous = systemOutputUID
        guard uid != previous else { return }
        let target = outputVolume

        // Hardware-mute BOTH the old and new device BEFORE the swap. The rebuild is
        // break-before-make: tearing the old aggregate down resets the OLD device's
        // scalar to 100%, and building the new taps resets the NEW device's — a
        // CoreAudio quirk volume writes can't beat (the reset lands after the write),
        // only a mute survives it. With both muted, neither device can blast across
        // the swap; we unmute the old one and fade the new one up once it's live.
        if let previous, previous != uid { CoreAudioEngine.setDeviceMuted(uid: previous, true) }
        CoreAudioEngine.setDeviceMuted(uid: uid, true)

        // Drive the topology change ourselves instead of via applyTopology: it
        // fires startRouter as a detached Task, so we'd never know when the new
        // device is actually up. We await the rebuild inline to get that signal.
        var draft = config
        if let i = draft.mixes.firstIndex(where: { $0.id == Self.defaultMixID }) {
            draft.mixes[i].dest = .hardware(uid: uid)
        }
        do { try draft.validate() } catch {
            self.error = String(describing: error)
            CoreAudioEngine.setDeviceMuted(uid: uid, false)
            return
        }
        error = nil
        config = draft
        persist(draft)
        guard driverEnabled else {
            CoreAudioEngine.setDeviceMuted(uid: uid, false)
            return
        }

        let muted = draft.masterMuted
        restoringVolume = true
        Task {
            defer { restoringVolume = false }
            // Bring the new aggregate up and BLOCK until it's live. The rebuild is
            // break-before-make (startRouter destroys the old aggregate, then builds
            // the new one) and that swap can BOTH reset the new device's scalar to
            // 100% AND clear the mute we set pre-build.
            applyRouterStatus(await engine.startRouter(config: draft))

            // So re-assert silence on the live device the moment the rebuild returns,
            // before anything audible — never trust that the pre-build mute survived
            // the aggregate swap. From here it's always: muted → 0 → reveal/fade.
            CoreAudioEngine.setDeviceMuted(uid: uid, true)
            await engine.setOutputVolume(uid: uid, 0)
            outputVolume = 0
            // Restore the device we left: the break-before-make teardown reset its
            // scalar to 100%. The reset has already landed by now, so re-assert its
            // prior level BEFORE unmuting — otherwise unmuting blasts it at 100%.
            if let previous, previous != uid {
                await engine.setOutputVolume(uid: previous, Float(target))
                await engine.setOutputMuted(uid: previous, false)
            }

            if muted {
                // Master is muted — hold at the saved level but keep the device silent.
                await engine.setOutputVolume(uid: uid, Float(target))
                outputVolume = target
            } else {
                CoreAudioEngine.setDeviceMuted(uid: uid, false)
                await rampOutputVolume(uid: uid, from: 0, to: target)
            }
        }
    }

    /// Hardware outputs only — hides BAM virtual devices from the system picker.
    var hardwareOutputDevices: [AudioDevice] {
        outputDevices.filter { !$0.uid.hasPrefix("BAM_UID_") }
    }

    // MARK: master (the routed hardware device's own OS volume)

    /// Volume scalar (0…1) of the hardware device the Default output feeds. The
    /// master fader reads/writes this — i.e. it is the physical output's slider.
    /// Seeded from the value saved at last exit so the fader shows the level it
    /// will restore to, instead of flashing 100% before the async restore lands.
    private(set) var outputVolume: Double = 1.0

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
    private static let captureConfirmDB: Float = -55

    /// True when a router frame shows real captured audio on any source. Real audio
    /// only flows *after* the capture-permission popup is accepted — at which point
    /// `.mutedWhenTapped` is also muting the apps — so this is the deterministic
    /// signal that raising the volume can't blast raw, unmuted output.
    private var captureConfirmed: Bool {
        snapshot.sources.contains { $0.level > Self.captureConfirmDB }
    }

    /// True while `restoreOutputVolume()` is holding the device dimmed waiting for
    /// the capture-permission grant. The periodic poll must not surface that
    /// transient dim on the fader — the fader should keep showing the user's level.
    private var restoringVolume = false

    /// True once this session has actually taken authority over the device volume —
    /// i.e. `restoreOutputVolume()` ran to completion (applied the saved bam level,
    /// or owned a fresh device with no saved level). Exit only persists the running
    /// level / resets to stock when this is true; otherwise (capture never confirmed,
    /// restore cancelled) it leaves the saved level untouched so a half-finished
    /// session can't clobber it with a stock/dimmed reading.
    private var bamVolumeApplied = false

    func refreshOutputVolume() async {
        guard !restoringVolume else { return }
        guard let uid = systemOutputUID else { return }
        if let v = await engine.outputVolume(uid: uid) { outputVolume = Double(v) }
    }

    /// On exit, in order:
    ///   1. Save the current device level as the *bam* level (what to resume at).
    ///   2. Tear our taps + aggregate down and BLOCK until that's finished — every
    ///      app un-mutes and normal direct-to-device playback is fully restored.
    ///   3. Only now set the device to the *stock* level we saved at launch, which
    ///      is the level that's correct for that raw, no-bam playback.
    /// Doing the volume change only after teardown is what avoids the exit spike:
    /// we never leave a bam-tuned level applied to un-muted raw audio.
    /// Synchronous (drives the async teardown via a semaphore) so it completes
    /// inside `applicationWillTerminate`.
    func dimOutputForExit() {
        guard let uid = systemOutputUID else { return }
        let stock = defaults.object(forKey: Self.stockVolumeKey) != nil
            ? defaults.double(forKey: Self.stockVolumeKey) : nil
        let current = CoreAudioEngine.deviceVolume(uid: uid).map(Double.init) ?? outputVolume

        // The actual exit blast: CoreAudio momentarily resets the physical device
        // volume to 100% while the aggregate + taps are torn down, before the level
        // is reapplied. Setting the volume can't beat that (the reset lands after our
        // write), so hardware-MUTE the device across the whole teardown and unmute it
        // only once the correct level is back. Launch clears any stale mute, so an
        // interrupted exit can't strand the device muted.
        CoreAudioEngine.setDeviceMuted(uid: uid, true)

        func teardownBlocking() {
            let sem = DispatchSemaphore(value: 0)
            Task { await engine.stopRouter(); sem.signal() }
            _ = sem.wait(timeout: .now() + 1.0)
        }

        switch VolumePolicy.exit(applied: bamVolumeApplied, currentDeviceLevel: current, stockLevel: stock) {
        case .teardownOnly:
            teardownBlocking()
        case let .persist(bamLevel, _):
            defaults.set(bamLevel, forKey: Self.savedVolumeKey)
            teardownBlocking()
        }

        // Restore the stock level (the post-teardown device sits at the 100% reset)
        // and only then drop the mute, so the device is never audible above stock.
        if let stock { CoreAudioEngine.setDeviceVolume(uid: uid, Float(stock)) }
        CoreAudioEngine.setDeviceMuted(uid: uid, false)
    }

    /// On launch: re-apply the volume we saved at last exit, but only once it is
    /// *safe*. With the router on, raising the device before the taps' muting has
    /// engaged would blast the apps' raw, unmuted output (the launch spike). The
    /// hard gate: wait for sustained, real captured audio — which only exists after
    /// the capture-permission grant, the same moment `.mutedWhenTapped` starts
    /// muting the apps. No blind timer: if capture is never confirmed (e.g. a
    /// silent system, or permission denied) the device simply stays dimmed and the
    /// restore happens the instant real audio first flows. The wait is cancellable
    /// via the surrounding Task, so app teardown won't strand it.
    func restoreOutputVolume() async {
        guard let uid = systemOutputUID else { return }
        let saved = defaults.object(forKey: Self.savedVolumeKey) != nil
            ? defaults.double(forKey: Self.savedVolumeKey) : nil

        switch VolumePolicy.launch(savedLevel: saved) {
        case .takeAuthorityNoChange:
            // No bam level yet: leave the device as is, but take authority so exit
            // saves whatever level the user lands on this first session.
            await refreshOutputVolume()
            bamVolumeApplied = true
        case let .applySaved(v):
            restoringVolume = true
            defer { restoringVolume = false }
            if driverEnabled {
                // Don't touch the volume during setup: the device stays at the user's
                // stock level (raw apps play at their normal level — no spike) until our
                // setup is *completely ready*. Ready = sustained real captured audio,
                // which only flows after the capture-permission grant, the same moment
                // `.mutedWhenTapped` is muting the apps and the summed mix becomes the
                // only thing audible. No timer: if capture never confirms (silent system
                // / permission denied) the device just stays at stock.
                var held = 0
                while held < 5, !Task.isCancelled {
                    held = captureConfirmed ? held + 1 : 0
                    try? await Task.sleep(for: .milliseconds(50))
                }
                if Task.isCancelled { return }
            }
            // Safe-to-raise point reached (event-gated above). Fade in from silence up
            // to the saved level so the hand-off is audibly gradual — ramping from the
            // current stock level was imperceptible whenever stock ≈ saved.
            await rampOutputVolume(uid: uid, from: 0, to: v)
            bamVolumeApplied = true
        }
    }

    /// Cosmetic volume slew used *after* the event-based safe-to-raise gate. Steps
    /// `from`→`to` over a short fixed transition (NOT a safety timer — the gate that
    /// decides *whether* to raise is event-based upstream). Cancellable: app teardown
    /// stops it wherever it is, and `restoringVolume` must stay true across the call
    /// so the periodic poll doesn't fight the slew.
    private func rampOutputVolume(uid: String, from: Double, to: Double) async {
        guard abs(to - from) > 0.01 else {
            await engine.setOutputVolume(uid: uid, Float(to)); outputVolume = to; return
        }
        await engine.setOutputVolume(uid: uid, Float(from)); outputVolume = from
        let steps = 24
        let stepDelay = Duration.milliseconds(50)   // ~1.2s total transition
        for i in 1...steps {
            if Task.isCancelled { return }
            let v = from + (to - from) * (Double(i) / Double(steps))
            await engine.setOutputVolume(uid: uid, Float(v))
            outputVolume = v
            try? await Task.sleep(for: stepDelay)
        }
        await engine.setOutputVolume(uid: uid, Float(to))
        outputVolume = to
    }

    func setOutputVolume(_ v: Double) {
        let clamped = max(0, min(1, v))
        outputVolume = clamped
        guard let uid = systemOutputUID else { return }
        Task { await engine.setOutputVolume(uid: uid, Float(clamped)) }
    }

    var masterMuted: Bool { config.masterMuted }
    func setMasterMuted(_ muted: Bool) {
        applyGains { $0.masterMuted = muted }   // gates the router when it runs
        pushMasterMuteToHardware()              // …and the physical device itself
    }

    /// Apply the current master-mute state to the routed hardware device, so mute
    /// works even when the router/driver is off and audio is hardware-direct.
    private func pushMasterMuteToHardware() {
        guard let uid = systemOutputUID else { return }
        let muted = config.masterMuted
        Task { await engine.setOutputMuted(uid: uid, muted) }
    }
    var masterMeter: Float { config.mixes.map { mixLevel($0.id) }.max() ?? RMSMeter.floorDB }

    // MARK: sends (routing within a mix)

    func isRouted(_ sourceID: String, in mixID: String) -> Bool {
        config.mixes.first { $0.id == mixID }?.sends.contains { $0.source == sourceID } ?? false
    }

    func send(_ sourceID: String, in mixID: String) -> Send? {
        config.mixes.first { $0.id == mixID }?.sends.first { $0.source == sourceID }
    }

    func setRouted(_ sourceID: String, in mixID: String, _ routed: Bool) {
        applyTopology { cfg in
            guard let i = cfg.mixes.firstIndex(where: { $0.id == mixID }) else { return }
            if routed {
                if !cfg.mixes[i].sends.contains(where: { $0.source == sourceID }) {
                    cfg.mixes[i].sends.append(Send(source: sourceID))
                }
            } else {
                cfg.mixes[i].sends.removeAll { $0.source == sourceID }
            }
        }
    }

    func setSendLevel(_ sourceID: String, in mixID: String, _ level: Double) {
        applyGains { cfg in
            if let i = cfg.mixes.firstIndex(where: { $0.id == mixID }),
               let j = cfg.mixes[i].sends.firstIndex(where: { $0.source == sourceID }) {
                cfg.mixes[i].sends[j].level = level
            }
        }
    }

    func setSendMuted(_ sourceID: String, in mixID: String, _ muted: Bool) {
        applyGains { cfg in
            if let i = cfg.mixes.firstIndex(where: { $0.id == mixID }),
               let j = cfg.mixes[i].sends.firstIndex(where: { $0.source == sourceID }) {
                cfg.mixes[i].sends[j].muted = muted
            }
        }
    }

    // MARK: sources

    /// Every running app is selectable in every device; assigning moves it.
    var assignableApps: [AudioApp] { runningApps }

    func addSource(app: AudioApp) {
        let id = Self.uniqueID("src", existing: config.sources.map(\.id))
        applyTopology { cfg in
            let src = Source(id: id, name: app.displayName, kind: .app,
                             bundleIDs: [app.bundleID], hue: Palette.hue(for: id))
            cfg.sources.append(src)
            // Route new sources into the active mix by default.
            if let mixID = self.activeMixID, let mi = cfg.mixes.firstIndex(where: { $0.id == mixID }) {
                cfg.mixes[mi].sends.append(Send(source: id))
            }
        }
    }

    func deleteSource(_ id: String) {
        applyTopology { cfg in
            cfg.sources.removeAll { $0.id == id }
            for i in cfg.mixes.indices { cfg.mixes[i].sends.removeAll { $0.source == id } }
            if cfg.solo == id { cfg.solo = nil }
            cfg.pans[id] = nil
        }
        if openGroupID == id { openGroupID = nil }
    }

    // MARK: source app membership (group panel)

    /// The apps grouped under a source, resolved to display metadata.
    func apps(for source: Source) -> [SourceApp] {
        source.bundleIDs.map { bid in
            let live = runningApps.first { $0.bundleID == bid }
            return SourceApp(bundleID: bid,
                             name: live?.displayName ?? Self.prettyName(bid),
                             playing: playing.contains(bid))
        }
    }

    func assignApp(_ app: AudioApp, to sourceID: String) {
        applyTopology { cfg in
            guard let i = cfg.sources.firstIndex(where: { $0.id == sourceID }) else { return }
            if !cfg.sources[i].bundleIDs.contains(app.bundleID) {
                cfg.sources[i].bundleIDs.append(app.bundleID)
            }
        }
    }

    func removeApp(_ bundleID: String, from sourceID: String) {
        applyTopology { cfg in
            guard let i = cfg.sources.firstIndex(where: { $0.id == sourceID }) else { return }
            cfg.sources[i].bundleIDs.removeAll { $0 == bundleID }
        }
    }

    private static func prettyName(_ bundleID: String) -> String {
        let last = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        return last.replacingOccurrences(of: "-", with: " ").capitalized
    }

    // MARK: devices (a device = one virtual output mix + its app-group source)

    /// Columns are output devices. Each maps to a `Mix`; its apps live in the
    /// single `Source` that mix sends from.
    var devices: [Mix] { config.mixes }

    func isDefaultDevice(_ mixID: String) -> Bool { mixID == Self.defaultMixID }

    func deviceSourceID(_ mixID: String) -> String? {
        config.mixes.first { $0.id == mixID }?.sends.first?.source
    }

    func deviceApps(_ mixID: String) -> [SourceApp] {
        if isDefaultDevice(mixID) {
            // Remainder device: every running app not claimed by an app-source.
            let claimed = Set(config.sources.filter { $0.kind == .app }.flatMap(\.bundleIDs))
            return runningApps.filter { !claimed.contains($0.bundleID) }
                .map { SourceApp(bundleID: $0.bundleID, name: $0.displayName, playing: playing.contains($0.bundleID)) }
        }
        guard let sid = deviceSourceID(mixID),
              let src = config.sources.first(where: { $0.id == sid }) else { return [] }
        return apps(for: src)
    }

    func deviceAppCount(_ mixID: String) -> Int {
        if isDefaultDevice(mixID) { return deviceApps(mixID).count }
        guard let sid = deviceSourceID(mixID) else { return 0 }
        return config.sources.first { $0.id == sid }?.bundleIDs.count ?? 0
    }

    /// Device id the app currently lives in; the Default catch-all when unclaimed.
    func currentDeviceID(forApp bundleID: String) -> String {
        for src in config.sources where src.kind == .app && src.bundleIDs.contains(bundleID) {
            if let mix = config.mixes.first(where: { $0.sends.contains { $0.source == src.id } }) {
                return mix.id
            }
        }
        return Self.defaultMixID
    }

    func currentDeviceName(forApp bundleID: String) -> String {
        config.mixes.first { $0.id == currentDeviceID(forApp: bundleID) }?.name ?? "Default"
    }

    func addDevice() {
        let slot = nextFreeSlot()
        let mixID = Self.uniqueID("mix", existing: config.mixes.map(\.id))
        let srcID = Self.uniqueID("src", existing: config.sources.map(\.id))
        let name = "Device \(config.mixes.count)"
        applyTopology { cfg in
            cfg.sources.append(Source(id: srcID, name: name, kind: .app,
                                      bundleIDs: [], hue: Palette.hue(for: srcID)))
            cfg.mixes.append(Mix(id: mixID, name: name, dest: .virtualSlot(slot),
                                 level: 0.5, sends: [Send(source: srcID)],
                                 tone: Palette.hue(for: mixID)))
        }
        activeMixID = mixID
    }

    func deleteDevice(_ mixID: String) {
        guard !isDefaultDevice(mixID) else { return }
        let sid = deviceSourceID(mixID)
        applyTopology { cfg in
            cfg.mixes.removeAll { $0.id == mixID }
            if let sid { cfg.sources.removeAll { $0.id == sid && $0.kind == .app } }
        }
        if activeMixID == mixID { activeMixID = config.mixes.first?.id }
    }

    func renameDevice(_ mixID: String, to name: String) {
        guard !isDefaultDevice(mixID) else { return }
        let t = name.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        let sid = deviceSourceID(mixID)
        applyGains { cfg in
            if let i = cfg.mixes.firstIndex(where: { $0.id == mixID }) { cfg.mixes[i].name = t }
            if let sid, let j = cfg.sources.firstIndex(where: { $0.id == sid }) { cfg.sources[j].name = t }
        }
    }

    /// Set (or clear, with nil) the device's icon glyph shown in place of its initials.
    func setDeviceEmoji(_ mixID: String, _ emoji: String?) {
        guard !isDefaultDevice(mixID) else { return }
        applyGains { cfg in
            if let i = cfg.mixes.firstIndex(where: { $0.id == mixID }) { cfg.mixes[i].emoji = emoji }
        }
    }

    /// Set (or clear, with nil → auto hue) the device's chip color, stored as a 0…1 hue.
    func setDeviceColor(_ mixID: String, _ hue: Double?) {
        guard !isDefaultDevice(mixID) else { return }
        applyGains { cfg in
            if let i = cfg.mixes.firstIndex(where: { $0.id == mixID }) { cfg.mixes[i].tone = hue }
        }
    }

    /// Move an app to a device. Stripped from every app-source first; if the
    /// target is the Default catch-all it just stays stripped (remainder routes it).
    func assignApp(_ app: AudioApp, toDevice mixID: String) {
        applyTopology { cfg in
            for i in cfg.sources.indices where cfg.sources[i].kind == .app {
                cfg.sources[i].bundleIDs.removeAll { $0 == app.bundleID }
            }
            guard mixID != Self.defaultMixID,
                  let sid = cfg.mixes.first(where: { $0.id == mixID })?.sends.first?.source,
                  let si = cfg.sources.firstIndex(where: { $0.id == sid }) else { return }
            if !cfg.sources[si].bundleIDs.contains(app.bundleID) {
                cfg.sources[si].bundleIDs.append(app.bundleID)
            }
        }
    }

    /// Remove an app from a device → it falls back into the Default remainder.
    func removeApp(_ bundleID: String, fromDevice mixID: String) {
        guard !isDefaultDevice(mixID), let sid = deviceSourceID(mixID) else { return }
        removeApp(bundleID, from: sid)
    }

    func deviceLevel(_ mixID: String) -> Double {
        config.mixes.first { $0.id == mixID }?.level ?? 1.0
    }
    func setDeviceLevel(_ mixID: String, _ level: Double) { setMixMaster(mixID, level) }

    func deviceMuted(_ mixID: String) -> Bool {
        guard let sid = deviceSourceID(mixID) else { return false }
        return send(sid, in: mixID)?.muted ?? false
    }
    func setDeviceMuted(_ mixID: String, _ muted: Bool) {
        guard let sid = deviceSourceID(mixID) else { return }
        setSendMuted(sid, in: mixID, muted)
    }

    // MARK: solo + pan (global, gains-only)

    var soloID: String? { config.solo }
    func toggleSolo(_ id: String) { applyGains { $0.solo = ($0.solo == id) ? nil : id } }

    func pan(_ id: String) -> Double { config.pans[id] ?? 0.5 }
    func setPan(_ id: String, _ pan: Double) { applyGains { $0.pans[id] = pan } }

    // MARK: apply

    private func applyTopology(_ mutate: (inout BamConfig) -> Void) { apply(topology: true, mutate) }
    private func applyGains(_ mutate: (inout BamConfig) -> Void) { apply(topology: false, mutate) }

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
        if topology {
            Task { applyRouterStatus(await engine.startRouter(config: draft)) }
        } else {
            Task { await engine.updateRouterGains(config: draft) }
        }
    }

    private func persist(_ cfg: BamConfig) {
        guard let url = configURL else { return }
        do { try ConfigStore.save(cfg, to: url) } catch let err { self.error = String(describing: err) }
    }

    private func nextFreeSlot() -> Int {
        let used = Set(config.mixes.compactMap { mix -> Int? in
            if case .virtualSlot(let s) = mix.dest { return s } else { return nil }
        })
        var s = 0
        while used.contains(s) { s += 1 }
        return s
    }

    private static func uniqueID(_ base: String, existing: [String]) -> String {
        let set = Set(existing)
        var n = 0
        while set.contains("\(base)\(n)") { n += 1 }
        return "\(base)\(n)"
    }

    private static func seedYAML() -> String {
        if let url = Bundle.main.url(forResource: "bam", withExtension: "yaml"),
           let text = try? String(contentsOf: url, encoding: .utf8) { return text }
        return "groups: []\n"
    }

    static func seedConfig() -> BamConfig { BamConfig() }

    /// Guarantee a Default catch-all device exists, first in the list, sending the
    /// `.rest` remainder to the system default hardware output.
    static func normalize(_ cfg: BamConfig, defaultOutput: String?) -> BamConfig {
        var c = cfg
        if !c.sources.contains(where: { $0.kind == .rest }) {
            c.sources.insert(Source(id: restSourceID, name: "Default", kind: .rest), at: 0)
        }
        let restID = c.sources.first { $0.kind == .rest }!.id
        let dest: MixDestination = defaultOutput.map { .hardware(uid: $0) } ?? .virtualSlot(0)
        if let di = c.mixes.firstIndex(where: { $0.id == defaultMixID }) {
            c.mixes[di].name = "Default"
            c.mixes[di].dest = dest
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
