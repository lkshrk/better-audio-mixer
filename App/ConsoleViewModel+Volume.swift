import BamCore
import Foundation

extension ConsoleViewModel {
    // MARK: system output (the hardware the Default device feeds)

    static func hardwareOutputUID(in config: BamConfig) -> String? {
        if case .hardware(let uid) = config.mixes.first(where: { $0.id == Self.defaultMixID })?.dest { return uid }
        return nil
    }

    var systemOutputUID: String? {
        Self.hardwareOutputUID(in: config)
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
        AppLog.router.notice("system output changing previous=\(previous ?? "none", privacy: .private) next=\(uid, privacy: .private)")
        let target = outputVolume

        var draft = config
        if let i = draft.mixes.firstIndex(where: { $0.id == Self.defaultMixID }) {
            draft.mixes[i].dest = .hardware(uid: uid)
        }
        do { try draft.validate() } catch {
            self.error = String(describing: error)
            AppLog.config.error("system output draft invalid: \(String(describing: error), privacy: .public)")
            return
        }
        error = nil
        config = draft
        persist(draft)
        guard driverEnabled else { return }
        protection.requestedVolumes[uid] = Float(target)
        enqueueRouterWork { model in
            let generation = model.routerWorkGeneration
            let target = Double(model.protection.requestedVolumes[uid] ?? Float(target))
            let status = await model.startRouterGuarded(config: draft, fadeIn: true, targetVolume: target)
            guard !model.routerWorkStale(generation) else { return }
            model.applyRouterStatus(status)
        }
    }

    func startRouterGuarded(config draft: BamConfig, fadeIn: Bool = false,
                            targetVolume: Double? = nil) async -> RouterStatus {
        await engine.setRouterRecoverySuspended(true)
        let status = await rebuildProtectedRouter(config: draft, fadeIn: fadeIn, targetVolume: targetVolume)
        await engine.setRouterRecoverySuspended(false)
        return status
    }

    private func rebuildProtectedRouter(config draft: BamConfig, fadeIn: Bool,
                                        targetVolume: Double?) async -> RouterStatus {
        guard driverEnabled else {
            return await engine.startRouter(config: draft)
        }
        protection.restoring = true
        defer { protection.restoring = false }
        let generation = routerWorkGeneration
        let uids = await protectedOutputUIDs(for: draft, retaining: Set(protection.guarded.keys))
        let requested = Self.hardwareOutputUID(in: draft)
        var overrides: [String: Float] = [:]
        // First protected start applies the staged saved level; later rebuilds keep the guarded intent.
        if let requested,
           let target = targetVolume.map(Float.init) ?? (!bamVolumeApplied ? protection.requestedVolumes[requested] : nil) {
            overrides[requested] = target
        }
        guard await protection.protect(uids, overriding: overrides), !routerWorkStale(generation) else {
            return outputProtectionFailed()
        }
        let status = await engine.startRouter(config: draft)
        guard !status.isFailure else { return status }
        guard !routerWorkStale(generation) else { return outputProtectionFailed() }
        var request = restoreRequest(generation: generation)
        request.bound = await engine.boundOutputUID()
        request.fadeIn = fadeIn
        request.requested = requested
        request.overrides = overrides
        guard await protection.restore(uids: uids, request) else { return outputProtectionFailed() }
        error = nil
        bamVolumeApplied = true
        return status
    }

    /// Closures read live model state; `generation == nil` means the caller must run to completion.
    func restoreRequest(generation: Int?) -> OutputProtection.RestoreRequest {
        var request = OutputProtection.RestoreRequest()
        request.masterMuted = { self.config.masterMuted }
        request.currentOutput = { self.systemOutputUID }
        if let generation { request.stale = { self.routerWorkStale(generation) } }
        return request
    }

    /// Outputs the route touches plus any still-connected device holding a guard from an earlier failure.
    func protectedOutputUIDs(for draft: BamConfig, retaining: Set<String>) async -> Set<String> {
        var uids = await engine.routerOutputUIDs(config: draft)
        guard !retaining.isEmpty else { return uids }
        let available = Set(await engine.outputDevices().map(\.uid))
        uids.formUnion(available.intersection(retaining))
        return uids
    }

    /// Returns to direct system playback only after protected teardown succeeds.
    func stopRouterGuarded() async -> Bool {
        await engine.setRouterRecoverySuspended(true)
        let stopped = await stopProtectedRouter()
        await engine.setRouterRecoverySuspended(false)
        return stopped
    }

    private func stopProtectedRouter() async -> Bool {
        if await engine.boundOutputUID() == nil, protection.guarded.isEmpty {
            return await engine.stopRouterChecked()
        }
        protection.restoring = true
        defer { protection.restoring = false }
        let uids = await protectedOutputUIDs(for: config, retaining: Set(protection.guarded.keys))
        guard await protection.protect(uids), await engine.stopRouterChecked() else {
            _ = outputProtectionFailed()
            return false
        }
        guard await protection.restore(uids: uids, restoreRequest(generation: nil)) else {
            _ = outputProtectionFailed()
            return false
        }
        return true
    }

    private func outputProtectionFailed() -> RouterStatus {
        error = "Audio output could not be safely restored. Check the output device and retry audio."
        return RouterStatus(cause: .buildFailed)
    }

    /// User-selectable hardware outputs only: hides BAM's virtual devices and the private router aggregate.
    var hardwareOutputDevices: [AudioDevice] {
        outputDevices.filter(Self.isSelectableHardwareOutput)
    }

    nonisolated static func isSelectableHardwareOutput(_ device: AudioDevice) -> Bool {
        if device.uid.hasPrefix("BAM_UID_") { return false }
        if device.uid.hasPrefix("bam-router") { return false }
        if device.name.caseInsensitiveCompare("bam-router") == .orderedSame { return false }
        return true
    }

    // MARK: master (the routed hardware device's own OS volume)

    func refreshOutputVolume() async {
        guard !protection.restoring, pendingOutputTargets == nil,
              let uid = systemOutputUID, protection.guarded[uid] == nil else { return }
        let requested = protection.requestedVolumes[uid]
        // Anything that changed during the read makes the value stale.
        guard let v = await engine.outputVolume(uid: uid),
              systemOutputUID == uid, !protection.restoring, protection.guarded[uid] == nil,
              pendingOutputTargets == nil, protection.requestedVolumes[uid] == requested else { return }
        if Double(v) != outputVolume { outputVolume = Double(v) }
    }

    /// Stages the saved level as intent so the first protected start applies it before unmuting.
    func stageSavedOutputVolume() {
        guard driverEnabled, let uid = systemOutputUID, protection.requestedVolumes[uid] == nil,
              defaults.object(forKey: Self.savedVolumeKey) != nil else { return }
        let saved = defaults.double(forKey: Self.savedVolumeKey)
        guard saved.isFinite else { return }
        protection.requestedVolumes[uid] = Float(max(0, min(1, saved)))
    }

    func restoreOutputVolume() async {
        guard driverEnabled else {
            await refreshOutputVolume()
            bamVolumeApplied = false
            return
        }
        guard !bamVolumeApplied else { return }
        stageSavedOutputVolume()
        await enqueueRouterWork { model in
            let generation = model.routerWorkGeneration
            let status = await model.startRouterGuarded(config: model.config)
            guard !model.routerWorkStale(generation) else { return }
            model.applyRouterStatus(status)
        }.value
    }

    func setOutputVolume(_ v: Double, origin: String = "ui") {
        guard v.isFinite else { return }
        let clamped = max(0, min(1, v))
        AppLog.router.debug("hardware volume requested origin=\(origin, privacy: .public) target=\(clamped, privacy: .public)")
        outputVolume = clamped
        guard let uid = systemOutputUID else { return }
        protection.requestedVolumes[uid] = Float(clamped)
        if protection.rampTargets[uid] != nil { protection.rampTargets[uid] = Float(clamped) }
        if protection.guarded[uid] != nil { protection.guarded[uid]?.volume = Float(clamped) }
        outputTargets().volumes[uid] = Float(clamped)
    }

    var masterMuted: Bool { config.masterMuted }
    func setMasterMuted(_ muted: Bool) {
        applyGains { $0.masterMuted = muted }
        pushMasterMuteToHardware()
    }

    private func pushMasterMuteToHardware() {
        guard let uid = systemOutputUID else { return }
        let muted = config.masterMuted
        if protection.guarded[uid] != nil { protection.guarded[uid]?.muted = muted }
        // Muting is safe immediately, even while a queued switch is fading in.
        if muted {
            Task {
                if protection.guarded[uid] == nil { _ = await protection.capture(uid: uid) }
                guard config.masterMuted else { return }
                _ = await engine.setOutputMutedChecked(uid: uid, true)
            }
            return
        }
        outputTargets().muteUIDs.insert(uid)
    }

    private func outputTargets() -> OutputTargets {
        if let pendingOutputTargets { return pendingOutputTargets }
        let targets = OutputTargets()
        enqueueRouterWork(requiresDriver: false, isControlUpdate: true) { model in
            if model.pendingOutputTargets === targets { model.pendingOutputTargets = nil }
            await model.applyOutputTargets(targets)
        }
        pendingOutputTargets = targets
        return targets
    }

    private func applyOutputTargets(_ targets: OutputTargets) async {
        for (uid, volume) in targets.volumes {
            guard !Task.isCancelled else { return }
            guard protection.guarded[uid] == nil,
                  let current = await protection.capture(uid: uid),
                  protection.guarded[uid] == nil, !Task.isCancelled else { continue }
            let state = (protection.calibrations[uid] ?? current).withVolume(volume)
            AppLog.router.debug("hardware volume queued apply target=\(state.volume, privacy: .public) uid=\(uid, privacy: .private)")
            guard await engine.restoreOutputDeviceState(state, restoreVolume: true, restoreMute: false) == .applied else {
                protection.guarded[uid] = OutputProtection.Guarded(state: state, calibration: protection.calibrations[uid] ?? current)
                if let latest = protection.requestedVolumes[uid] { protection.guarded[uid]?.volume = latest }
                _ = await engine.setOutputMutedChecked(uid: uid, true)
                applyRouterStatus(outputProtectionFailed())
                continue
            }
            if uid == systemOutputUID, protection.requestedVolumes[uid] == volume {
                outputVolume = Double(state.volume)
            }
        }
        for uid in targets.muteUIDs {
            guard !Task.isCancelled else { return }
            guard protection.guarded[uid] == nil else {
                AppLog.router.notice("hardware unmute deferred; output protection retained uid=\(uid, privacy: .private)")
                continue
            }
            guard !config.masterMuted, let current = await protection.capture(uid: uid) else { continue }
            guard protection.guarded[uid] == nil else {
                AppLog.router.notice("hardware unmute deferred; output protection retained uid=\(uid, privacy: .private)")
                continue
            }
            guard !config.masterMuted, !Task.isCancelled else { continue }
            let state = OutputProtection.masterUnmuted(protection.calibrations[uid] ?? current)
            guard await engine.restoreOutputDeviceState(state, restoreVolume: false, restoreMute: true) == .applied else {
                AppLog.router.error("hardware unmute failed uid=\(uid, privacy: .private)")
                applyRouterStatus(outputProtectionFailed())
                continue
            }
        }
    }

    var masterMeter: Float { config.mixes.map { mixLevel($0.id) }.max() ?? RMSMeter.floorDB }
    var masterMeterLeft: Float { config.mixes.map { mixLevelLeft($0.id) }.max() ?? RMSMeter.floorDB }
    var masterMeterRight: Float { config.mixes.map { mixLevelRight($0.id) }.max() ?? RMSMeter.floorDB }
}
