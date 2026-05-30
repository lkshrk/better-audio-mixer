import AppKit
import BamCore
import CoreAudio
import Foundation

public actor CoreAudioEngine: AudioEngineProtocol {
    private struct SourceEntry {
        let key: String
        let bundleID: String
        let displayName: String
        let deviceUID: String
        let deviceName: String
        let chain: TapChain
    }

    private var groups: [Group] = []
    private var master: Double = 1.0
    private var outputDeviceUID: String?
    private var outputDeviceList: [OutputDeviceInfo] = []
    private var enforce = false
    private var entriesByGroup: [String: [SourceEntry]] = [:]
    private var chainByKey: [String: TapChain] = [:]
    private var masterChain: TapChain?
    private var allAudioChain: TapChain?
    private var listener: ChangeListener?
    private var samplerTask: Task<Void, Never>?

    // v3 router: one aggregate (all source taps + the selected output) summing
    // each tap × its gain in a single hardware-clocked IOProc.
    private var router: RouterAggregate?
    private var routerConfig: BamConfig?
    private var routerSamplerTask: Task<Void, Never>?
    /// Live process taps kept ALIVE across topology edits, keyed by source id.
    /// `sig` is the tap's target-process signature; a tap is reused as long as
    /// its signature is unchanged, so a no-op edit (e.g. adding an empty device)
    /// never recreates a tap → no TCC re-prompt and no unmute/blast window.
    private var liveTaps: [String: (sig: String, tap: RouterAggregate.Tap)] = [:]
    /// Signature of the aggregate currently live (output + ordered tap uuids).
    /// When the next desired signature matches, the aggregate is left running and
    /// only its gains are refolded — no rebuild, no offline flash.
    private var routerTapSig: String?

    public init() {}

    public func start(config: BamConfig) -> AsyncStream<MeterSnapshot> {
        groups = config.groups
        master = config.master
        outputDeviceUID = config.outputDeviceUID
        masterChain = TapChain(
            description: CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        )
        rebuild()
        listener = ChangeListener(
            object: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyProcessObjectList
        ) { [weak self] in
            Task { await self?.rebuild() }
        }

        return AsyncStream { continuation in
            let task = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { break }
                    continuation.yield(await self.snapshot())
                    try? await Task.sleep(for: .milliseconds(100))
                }
                continuation.finish()
            }
            self.samplerTask = task
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func update(config: BamConfig) {
        groups = config.groups
        master = config.master
        outputDeviceUID = config.outputDeviceUID
        rebuild()
    }

    public func outputDevices() -> [AudioDevice] {
        ProcessEnumerator.systemOutputDevices().map {
            AudioDevice(uid: $0.uid, name: $0.name, transportType: $0.transportType)
        }
    }

    public func defaultOutputUID() -> String? {
        ProcessEnumerator.defaultOutputDeviceUID()
    }

    public func outputVolume(uid: String) -> Float? { Self.deviceVolume(uid: uid) }

    /// Synchronous, actor-free device-volume read (mirror of `setDeviceVolume`).
    public nonisolated static func deviceVolume(uid: String) -> Float? {
        guard let dev = ProcessEnumerator.deviceID(forUID: uid) else { return nil }
        let main = CA.address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput)
        if let v = CA.float32(dev, main) { return v }
        // Some devices expose no main element — average the L/R channels.
        let l = CA.float32(dev, CA.address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, 1))
        let r = CA.float32(dev, CA.address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, 2))
        if let l, let r { return (l + r) / 2 }
        return l ?? r
    }

    public func setOutputVolume(uid: String, _ volume: Float) {
        Self.setDeviceVolume(uid: uid, volume)
    }

    /// Synchronous, actor-free device-volume write. Safe to call from app
    /// termination (which can't await the actor) — CoreAudio's setter is itself
    /// synchronous and thread-safe.
    public nonisolated static func setDeviceVolume(uid: String, _ volume: Float) {
        guard let dev = ProcessEnumerator.deviceID(forUID: uid) else { return }
        let v = max(0, min(1, volume))
        let main = CA.address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput)
        if CA.isSettable(dev, main), CA.setFloat32(dev, main, v) { return }
        // Fall back to writing each output channel for devices without a main.
        for ch: AudioObjectPropertyElement in [1, 2] {
            let a = CA.address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, ch)
            if CA.isSettable(dev, a) { CA.setFloat32(dev, a, v) }
        }
    }

    public func outputMuted(uid: String) -> Bool {
        guard let dev = ProcessEnumerator.deviceID(forUID: uid) else { return false }
        let main = CA.address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
        return CA.uint32(dev, main) != 0
    }

    public func setOutputMuted(uid: String, _ muted: Bool) {
        guard let dev = ProcessEnumerator.deviceID(forUID: uid) else { return }
        let v: UInt32 = muted ? 1 : 0
        let main = CA.address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
        if CA.isSettable(dev, main), CA.setUInt32(dev, main, v) { return }
        for ch: AudioObjectPropertyElement in [1, 2] {
            let a = CA.address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput, ch)
            if CA.isSettable(dev, a) { CA.setUInt32(dev, a, v) }
        }
    }

    public func playingBundleIDs() -> Set<String> {
        Set(ProcessEnumerator.allProcesses()
            .filter { $0.isRunningOutput && !$0.bundleID.isEmpty }
            .map(\.bundleID))
    }

    public func applyGains(config: BamConfig) {
        groups = config.groups
        master = config.master
        pushGains()
    }

    public func setEnforce(_ on: Bool) {
        guard on != enforce else { return }
        enforce = on
        rebuild()
    }

    public func runningAudioApps() -> [AudioApp] {
        let selfBundle = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter {
                $0.activationPolicy == .regular
                && $0.bundleIdentifier != nil
                && $0.bundleIdentifier != selfBundle
            }
            .compactMap { app -> AudioApp? in
                let bid = app.bundleIdentifier!
                guard seen.insert(bid).inserted else { return nil }
                return AudioApp(
                    bundleID: bid,
                    displayName: app.localizedName ?? Self.displayName(bid)
                )
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    public func stop() {
        samplerTask?.cancel()
        samplerTask = nil
        listener = nil
        entriesByGroup = [:]
        chainByKey = [:]
        allAudioChain = nil
        masterChain = nil
    }

    // MARK: - v3 router

    /// Build the central router from a v3 config: one capture tap per grouped
    /// source, all gathered with the selected output device into a single
    /// hardware-clocked aggregate that sums each tap × its gain to the output.
    /// Returns mix ids that could not be brought online (empty on success).
    ///
    /// First pass omits the remainder (ungrouped) tap: it isolates the summing
    /// aggregate and avoids self-capture feedback while the design is verified.
    public func startRouter(config: BamConfig) -> RouterStatus {
        // The single output everything mixes into: the hardware dest the picker
        // drives (the Default device), else the system default output.
        let outputUID = config.mixes.compactMap { mix -> String? in
            if case .hardware(let uid) = mix.dest { return uid } else { return nil }
        }.first ?? ProcessEnumerator.defaultOutputDeviceUID()
        guard let outputUID else {
            bamLog("startRouter: no output device (no hardware dest, no default output) — all \(config.mixes.count) mixes offline", level: .error)
            router = nil
            return RouterStatus(failedMixIDs: config.mixes.map(\.id), cause: .noOutput)
        }

        let allProcs = ProcessEnumerator.allProcesses()

        // Resolve every desired tap to (sourceID, target signature, builder).
        // The signature is the exact set of process objects the tap captures; it
        // is what determines whether an existing live tap can be reused or a new
        // ProcessTap (which re-fires the TCC consent prompt) must be created.
        var desired: [(sourceID: String, sig: String, make: () -> CATapDescription)] = []
        var groupedObjectIDs: [AudioObjectID] = []
        for source in config.sources where source.kind == .app {
            let procIDs = allProcs
                .filter { Self.matchedTarget($0.bundleID, source.bundleIDs) != nil }
                .map(\.objectID)
                .sorted()
            guard !procIDs.isEmpty else { continue }
            groupedObjectIDs.append(contentsOf: procIDs)
            let sig = "app:" + procIDs.map(String.init).joined(separator: ",")
            desired.append((source.id, sig, {
                let desc = CATapDescription(stereoMixdownOfProcesses: procIDs)
                desc.muteBehavior = .mutedWhenTapped
                return desc
            }))
        }

        // The Default group: a global tap of everything NOT in a named group and
        // NOT bam itself. `.mutedWhenTapped` silences those ungrouped apps' own
        // output; they are then summed at the Default mix's gain (0 while Default
        // is muted → ungrouped audio is silent everywhere, as intended). Excluding
        // the grouped apps avoids double-counting (they have their own taps);
        // excluding bam avoids a self-capture feedback loop.
        if let rest = config.sources.first(where: { $0.kind == .rest }) {
            var exclude = groupedObjectIDs
            if let selfObj = ProcessEnumerator.processObject(forPID: getpid()) {
                exclude.append(selfObj)
            }
            let sig = "rest:" + exclude.sorted().map(String.init).joined(separator: ",")
            desired.append((rest.id, sig, {
                let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: exclude)
                desc.muteBehavior = .mutedWhenTapped
                return desc
            }))
        }

        // Build the ordered tap list, REUSING any live tap whose target signature
        // is unchanged. Only genuinely new/changed targets create a ProcessTap, so
        // edits that don't alter the tap set (adding an empty device, renaming,
        // gain tweaks) create nothing — no permission prompt, no unmute window.
        var newLive: [String: (sig: String, tap: RouterAggregate.Tap)] = [:]
        var orderedTaps: [RouterAggregate.Tap] = []
        for d in desired {
            if let cached = liveTaps[d.sourceID], cached.sig == d.sig {
                newLive[d.sourceID] = cached
                orderedTaps.append(cached.tap)
            } else if let proc = ProcessTap(description: d.make()) {
                let tap = RouterAggregate.Tap(sourceID: d.sourceID, proc: proc)
                newLive[d.sourceID] = (d.sig, tap)
                orderedTaps.append(tap)
            }
        }
        // Taps dropped here (no longer desired) deinit and unmute their apps —
        // correct: those apps left their group and should hear themselves again.
        liveTaps = newLive
        routerConfig = config

        // No grouped app is running yet → nothing to route. Idle, not offline.
        guard !orderedTaps.isEmpty else {
            router = nil; routerTapSig = nil
            return RouterStatus(cause: .noSourcesRunning)
        }

        let aggSig = outputUID + "|" + orderedTaps.map(\.proc.uuid).joined(separator: ",")
        if let live = router, routerTapSig == aggSig {
            // Tap set AND output unchanged → leave the running aggregate alone and
            // only refold gains. This is the hot path for ordinary edits: no
            // rebuild, no offline flash, no blast.
            applyRouterGains(config, to: live)
            return .ok
        }

        // Tap set or output changed → rebuild the aggregate. Break-before-make is
        // safe here precisely because the taps are reused and stay ALIVE across
        // the swap: their apps remain muted, so the gap is brief silence, never an
        // unmute blast. Destroying the old aggregate first also frees the fixed
        // UID so the new build cannot collide with a live device (bug-172/174).
        router = nil
        guard let agg = RouterAggregate(outputUID: outputUID, taps: orderedTaps) else {
            bamLog("startRouter: aggregate build failed (\(orderedTaps.count) taps, output \(outputUID)) — likely audio-capture permission not yet granted; \(config.mixes.count) mixes offline", level: .error)
            routerTapSig = nil
            return RouterStatus(failedMixIDs: config.mixes.map(\.id), cause: .permissionPending)
        }
        applyRouterGains(config, to: agg)
        router = agg
        routerTapSig = aggSig
        bamLog("startRouter: aggregate live with \(orderedTaps.count) taps → \(outputUID)")
        return .ok
    }

    // MARK: router recovery events

    private var routerEventListeners: [ChangeListener] = []

    /// Emits whenever the audio process list or output-device list changes — the
    /// only moments a previously failed `startRouter` could newly succeed (an app
    /// started, or an output device appeared). The view model retries on each
    /// event, so recovery is event-driven rather than a blind poll.
    public func routerEvents() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let procL = ChangeListener(
                object: AudioObjectID(kAudioObjectSystemObject),
                selector: kAudioHardwarePropertyProcessObjectList
            ) { continuation.yield(()) }
            let devL = ChangeListener(
                object: AudioObjectID(kAudioObjectSystemObject),
                selector: kAudioHardwarePropertyDevices
            ) { continuation.yield(()) }
            // Held by the actor so they outlive this closure; freed on deinit.
            routerEventListeners.append(contentsOf: [procL, devL])
        }
    }

    /// Equal-power pan law. 0 = hard left, 0.5 = center, 1 = hard right.
    private static func equalPower(pan: Float) -> (Float, Float) {
        let p = min(max(pan, 0), 1)
        let theta = p * (Float.pi / 2)
        return (cos(theta), sin(theta))
    }

    /// Fold each source's level · mute · solo-gate · device level · master · pan
    /// into L/R scalars and push them to the aggregate (off the audio thread).
    private func applyRouterGains(_ config: BamConfig, to target: RouterAggregate? = nil) {
        guard let router = target ?? self.router else { return }
        let master = config.masterMuted ? 0 : Float(config.master)
        let solo = config.solo
        for source in config.sources {
            var l: Float = 0, r: Float = 0
            for mix in config.mixes {
                guard let send = mix.sends.first(where: { $0.source == source.id }) else { continue }
                let gated = (send.muted || (solo != nil && solo != source.id))
                    ? 0 : Float(mix.level * send.level) * master
                let (pl, pr) = Self.equalPower(pan: Float(config.pans[source.id] ?? 0.5))
                l += gated * pl
                r += gated * pr
            }
            router.setGain(sourceID: source.id, l: l, r: r)
        }
    }

    /// Live per-source + per-mix levels while the router runs.
    public func routerSnapshots() -> AsyncStream<RouterSnapshot> {
        AsyncStream { continuation in
            let task = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { break }
                    continuation.yield(await self.routerSnapshot())
                    try? await Task.sleep(for: .milliseconds(33))
                }
                continuation.finish()
            }
            self.routerSamplerTask = task
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func routerSnapshot() -> RouterSnapshot {
        guard let cfg = routerConfig else { return .silent }
        let sources = cfg.sources.map { s in
            RouterSourceMeter(
                id: s.id, name: s.name,
                level: router?.meter(sourceID: s.id) ?? RMSMeter.floorDB
            )
        }
        let mixes = cfg.mixes.map { m -> MixMeter in
            // A device's level mirrors the source it groups (one source per mix).
            let lvl: Float
            if let sid = m.sends.first?.source, let r = router {
                lvl = r.meter(sourceID: sid)
            } else {
                lvl = RMSMeter.floorDB
            }
            return MixMeter(id: m.id, name: m.name, level: lvl)
        }
        return RouterSnapshot(sources: sources, mixes: mixes)
    }

    /// Recompute routing gains live (level/mute/solo/pan/master) without
    /// rebuilding the aggregate or its taps.
    public func updateRouterGains(config: BamConfig) {
        routerConfig = config
        applyRouterGains(config)
    }

    public func stopRouter() {
        routerSamplerTask?.cancel()
        routerSamplerTask = nil
        router = nil          // deinit tears down the aggregate → un-mutes apps
        routerConfig = nil
    }

    private func rebuild() {
        bamLog("REBUILD enforce=\(enforce) groups=\(groups.filter { !$0.bundleIDs.isEmpty }.map(\.name))")
        outputDeviceList = ProcessEnumerator.systemOutputDevices()
        var newChainByKey: [String: TapChain] = [:]
        var newEntriesByGroup: [String: [SourceEntry]] = [:]
        var groupedProcessIDs = Set<AudioObjectID>()

        let allProcs = ProcessEnumerator.allProcesses()
        let outUID = enforce ? (outputDeviceUID ?? ProcessEnumerator.defaultOutputDeviceUID()) : nil
        let outName = outUID.flatMap { uid in outputDeviceList.first { $0.uid == uid }?.name } ?? "all output"

        for group in groups where !group.bundleIDs.isEmpty {
            var entries: [SourceEntry] = []
            for target in group.bundleIDs {
                let procIDs = allProcs
                    .filter { Self.matchedTarget($0.bundleID, [target]) != nil }
                    .map(\.objectID)
                guard !procIDs.isEmpty else { continue }
                for id in procIDs { groupedProcessIDs.insert(id) }

                let procKey = procIDs.sorted().map(String.init).joined(separator: ",")
                let key = "\(enforce)|\(outUID ?? "")|\(group.name)|\(target)|\(procKey)"
                let chain: TapChain
                if let existing = chainByKey[key] {
                    chain = existing
                } else if let created = makeAppChain(procIDs: procIDs, outputUID: outUID) {
                    bamLog("NEW CHAIN \(group.name)/\(target) procs=\(procKey) enforce=\(enforce)")
                    chain = created
                } else {
                    continue
                }
                newChainByKey[key] = chain
                entries.append(SourceEntry(
                    key: key,
                    bundleID: target,
                    displayName: Self.displayName(target),
                    deviceUID: outUID ?? "",
                    deviceName: outName,
                    chain: chain
                ))
            }
            newEntriesByGroup[group.name] = entries
        }

        chainByKey = newChainByKey
        entriesByGroup = newEntriesByGroup
        rebuildRemainder(excluding: groupedProcessIDs)
        pushGains()
    }

    private func pushGains() {
        for group in groups {
            let g = group.muted ? 0 : Float(master * group.volume)
            for entry in entriesByGroup[group.name] ?? [] {
                entry.chain.setGain(g)
            }
        }
    }

    private func rebuildRemainder(excluding: Set<AudioObjectID>) {
        allAudioChain = TapChain(
            description: CATapDescription(stereoGlobalTapButExcludeProcesses: Array(excluding))
        )
    }

    private func makeAppChain(procIDs: [AudioObjectID], outputUID: String?) -> TapChain? {
        let desc = CATapDescription(stereoMixdownOfProcesses: procIDs)
        return TapChain(description: desc, outputDeviceUID: outputUID)
    }

    private func snapshot() -> MeterSnapshot {
        let master = masterChain?.slot.load() ?? RMSMeter.floorDB
        let claimingGroup = groups.contains(where: \.includesUnassigned)

        let groupMeters: [GroupMeter] = groups.map { group in
            let entries = entriesByGroup[group.name] ?? []
            var levels = entries.map { $0.chain.slot.load() }
            if group.includesUnassigned, let remainder = allAudioChain?.slot.load() {
                levels.append(remainder)
            }
            let sources = entries.map {
                SourceMeter(
                    bundleID: $0.bundleID,
                    displayName: $0.displayName,
                    deviceUID: $0.deviceUID,
                    deviceName: $0.deviceName,
                    level: $0.chain.slot.load()
                )
            }
            return GroupMeter(
                name: group.name,
                volume: group.volume,
                muted: group.muted,
                level: RMSMeter.combine(levels),
                sources: sources,
                isUnassignedBucket: group.includesUnassigned
            )
        }

        let unassigned: GroupMeter? = claimingGroup ? nil : GroupMeter(
            name: "All Audio",
            volume: 1.0,
            muted: false,
            level: allAudioChain?.slot.load() ?? RMSMeter.floorDB,
            sources: [],
            isUnassignedBucket: true
        )
        return MeterSnapshot(master: master, groups: groupMeters, unassigned: unassigned)
    }

    private static func displayName(_ bundleID: String) -> String {
        bundleID.components(separatedBy: ".").last ?? bundleID
    }

    /// A process matches a group target if its bundle equals the target or is a
    /// helper of it (e.g. com.brave.Browser.helper matches com.brave.Browser).
    private static func matchedTarget(_ procBundle: String, _ targets: [String]) -> String? {
        guard !procBundle.isEmpty else { return nil }
        return targets.first { procBundle == $0 || procBundle.hasPrefix($0 + ".") }
    }
}
