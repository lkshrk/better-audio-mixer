import AudioEngine
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
        enqueueRouterWork { model in
            let status = await model.startRouterGuarded(config: draft, fadeIn: true, targetVolume: target)
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
        restoringVolume = true
        defer { restoringVolume = false }
        let generation = routerWorkGeneration
        var uids = await engine.routerOutputUIDs(config: draft)
        // A failed earlier switch may have protected another still-connected output.
        let available = Set(await engine.outputDevices().map(\.uid))
        uids.formUnion(available.intersection(guardedOutputs.keys))
        let requested = Self.hardwareOutputUID(in: draft)
        let overrides: [String: Float]
        if let requested, let targetVolume { overrides = [requested: Float(targetVolume)] }
        else { overrides = [:] }
        guard await protectOutputs(uids, overriding: overrides) else {
            return outputProtectionFailed()
        }
        guard !Task.isCancelled, generation == routerWorkGeneration else { return outputProtectionFailed() }

        let status = await engine.startRouter(config: draft)
        guard !status.isFailure else { return status }
        guard !Task.isCancelled, generation == routerWorkGeneration else { return outputProtectionFailed() }
        let bound = await engine.boundOutputUID()
        // Restore/fade the new output first; release the previous capture device last.
        let ordered = uids.sorted { a, b in
            if a == bound { return b != bound }
            if b == bound { return false }
            return a < b
        }
        for uid in ordered {
            guard !Task.isCancelled, generation == routerWorkGeneration else { return outputProtectionFailed() }
            guard let saved = guardedOutputs[uid],
                  await engine.setOutputMutedChecked(uid: uid, true) == .applied else {
                return outputProtectionFailed()
            }
            let muted = config.masterMuted || (guardedOutputs[uid]?.muted ?? saved.muted)
            if fadeIn, uid == bound, !muted {
                guard await engine.setOutputVolumeChecked(uid: uid, 0) == .applied,
                      !Task.isCancelled, generation == routerWorkGeneration else {
                    return outputProtectionFailed()
                }
                if !config.masterMuted, guardedOutputs[uid]?.muted != true {
                    guard await engine.setOutputMutedChecked(uid: uid, false) == .applied else {
                        return outputProtectionFailed()
                    }
                }
                guard await rampOutputVolume(uid: uid, from: 0, to: Double(saved.volume)) else {
                    _ = await engine.setOutputMutedChecked(uid: uid, true)
                    return outputProtectionFailed()
                }
            } else {
                let volume = guardedOutputs[uid]?.volume ?? saved.volume
                guard await engine.setOutputVolumeChecked(uid: uid, volume) == .applied else {
                    return outputProtectionFailed()
                }
                guard !Task.isCancelled, generation == routerWorkGeneration else { return outputProtectionFailed() }
                if !config.masterMuted, !(guardedOutputs[uid]?.muted ?? saved.muted) {
                    guard await engine.setOutputMutedChecked(uid: uid, false) == .applied else {
                        return outputProtectionFailed()
                    }
                }
            }
            if fadeIn, uid == bound { outputVolume = Double(guardedOutputs[uid]?.volume ?? saved.volume) }
            await engine.acknowledgeOutputRestore(uids: [uid])
            guardedOutputs[uid] = nil
        }
        error = nil
        return status
    }

    private func protectOutputs(_ uids: Set<String>, overriding volumes: [String: Float] = [:]) async -> Bool {
        // Snapshot every device before the first mute, preserving intent from failures.
        for uid in uids.sorted() {
            if guardedOutputs[uid] == nil {
                guard let volume = await engine.outputVolume(uid: uid), volume.isFinite else { return false }
                let muted = await engine.outputMuted(uid: uid)
                guardedOutputs[uid] = GuardedOutput(volume: volume, muted: muted)
            }
            if let volume = volumes[uid] { guardedOutputs[uid]?.volume = volume }
        }
        for uid in uids.sorted() {
            guard await engine.setOutputMutedChecked(uid: uid, true) == .applied else { return false }
        }
        return true
    }

    /// Return to direct system playback only after protected teardown succeeds.
    func stopRouterGuarded() async -> Bool {
        await engine.setRouterRecoverySuspended(true)
        let stopped = await stopProtectedRouter()
        await engine.setRouterRecoverySuspended(false)
        return stopped
    }

    private func stopProtectedRouter() async -> Bool {
        if await engine.boundOutputUID() == nil, guardedOutputs.isEmpty {
            return await engine.stopRouterChecked()
        }
        restoringVolume = true
        defer { restoringVolume = false }
        var uids = await engine.routerOutputUIDs(config: config)
        let available = Set(await engine.outputDevices().map(\.uid))
        uids.formUnion(available.intersection(guardedOutputs.keys))
        guard await protectOutputs(uids), await engine.stopRouterChecked() else {
            _ = outputProtectionFailed()
            return false
        }
        for uid in uids.sorted() {
            guard let saved = guardedOutputs[uid],
                  await engine.setOutputVolumeChecked(uid: uid, saved.volume) == .applied else {
                _ = outputProtectionFailed()
                return false
            }
        }
        for uid in uids.sorted() {
            guard let saved = guardedOutputs[uid] else { continue }
            if !config.masterMuted, !saved.muted {
                guard await engine.setOutputMutedChecked(uid: uid, false) == .applied else {
                    _ = outputProtectionFailed()
                    return false
                }
            }
            await engine.acknowledgeOutputRestore(uids: [uid])
            guardedOutputs[uid] = nil
        }
        return true
    }

    private func outputProtectionFailed() -> RouterStatus {
        error = "Audio output could not be safely restored. Check the output device and retry audio."
        return RouterStatus(cause: .buildFailed)
    }

    /// User-selectable hardware outputs only - hides BAM's virtual devices and
    /// private router aggregate from the system picker.
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

    /// True when a router frame shows real captured audio on any source.
    var captureConfirmed: Bool {
        snapshot.sources.contains { $0.level > Self.captureConfirmDB }
    }

    func refreshOutputVolume() async {
        guard !restoringVolume else { return }
        guard let uid = systemOutputUID else { return }
        guard guardedOutputs[uid] == nil else { return }
        if let v = await engine.outputVolume(uid: uid) { outputVolume = Double(v) }
    }

    func dimOutputForExit() {
        guard let uid = systemOutputUID else { return }
        let stock = defaults.object(forKey: Self.stockVolumeKey) != nil
            ? defaults.double(forKey: Self.stockVolumeKey) : nil
        let current = CoreAudioEngine.deviceVolume(uid: uid).map(Double.init) ?? outputVolume

        switch VolumePolicy.exit(applied: bamVolumeApplied, currentDeviceLevel: current, stockLevel: stock) {
        case .teardownOnly:
            break
        case let .persist(bamLevel, _):
            defaults.set(bamLevel, forKey: Self.savedVolumeKey)
        }
        // Protect synchronously before process exit; never unmute after a timeout.
        guard CoreAudioEngine.setDeviceMutedChecked(uid: uid, true) == .applied else { return }
        // A Task inheriting MainActor cannot execute while this hook waits.
        // Invalidate queued work, then finish checked teardown off-actor.
        routerWorkGeneration += 1
        _ = pendingRouterWorkForExit()
        let engine = self.engine
        let draft = config
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            defer { sem.signal() }
            await engine.setRouterRecoverySuspended(true)
            let uids = await engine.routerOutputUIDs(config: draft)
            var saved: [String: (Float, Bool)] = [:]
            for output in uids {
                guard let level = await engine.outputVolume(uid: output) else { return }
                let muted = await engine.outputMuted(uid: output)
                saved[output] = (output == uid ? Float(stock ?? current) : level,
                                 output == uid ? false : muted)
            }
            for output in uids {
                guard await engine.setOutputMutedChecked(uid: output, true) == .applied else { return }
            }
            guard await engine.stopRouterChecked() else { return }
            for (output, state) in saved {
                guard await engine.setOutputVolumeChecked(uid: output, state.0) == .applied else { return }
            }
            for (output, state) in saved where !state.1 {
                guard await engine.setOutputMutedChecked(uid: output, false) == .applied else { return }
            }
            await engine.acknowledgeOutputRestore(uids: uids)
        }
        _ = sem.wait(timeout: .now() + 1.0)
    }

    func restoreOutputVolume() async {
        let generation = routerWorkGeneration
        guard let uid = systemOutputUID else { return }
        guard driverEnabled else {
            await refreshOutputVolume()
            bamVolumeApplied = false
            return
        }
        let saved = defaults.object(forKey: Self.savedVolumeKey) != nil
            ? defaults.double(forKey: Self.savedVolumeKey) : nil

        switch VolumePolicy.launch(savedLevel: saved) {
        case .takeAuthorityNoChange:
            await refreshOutputVolume()
            bamVolumeApplied = true
        case let .applySaved(v):
            restoringVolume = true
            defer { restoringVolume = false }
            if driverEnabled {
                var held = 0
                while held < 5, !Task.isCancelled {
                    guard driverEnabled, generation == routerWorkGeneration else { return }
                    held = captureConfirmed ? held + 1 : 0
                    try? await Task.sleep(for: .milliseconds(50))
                }
                if Task.isCancelled { return }
            }
            guard driverEnabled, generation == routerWorkGeneration,
                  guardedOutputs[uid] == nil, !routerStatus.isFailure else { return }
            await enqueueRouterWork { model in
                guard generation == model.routerWorkGeneration,
                      model.guardedOutputs[uid] == nil, !model.routerStatus.isFailure else { return }
                model.bamVolumeApplied = await model.rampOutputVolume(uid: uid, from: 0, to: v)
            }.value
        }
    }

    private func rampOutputVolume(uid: String, from: Double, to: Double) async -> Bool {
        let generation = routerWorkGeneration
        guard abs(to - from) > 0.01 else {
            guard await engine.setOutputVolumeChecked(uid: uid, Float(to)) == .applied else { return false }
            outputVolume = to
            return true
        }
        guard await engine.setOutputVolumeChecked(uid: uid, Float(from)) == .applied else { return false }
        outputVolume = from
        let steps = 24
        let stepDelay = Duration.milliseconds(50)
        for i in 1...steps {
            if Task.isCancelled || generation != routerWorkGeneration { return false }
            let target = guardedOutputs[uid].map { Double($0.volume) } ?? to
            if config.masterMuted || guardedOutputs[uid]?.muted == true {
                guard await engine.setOutputMutedChecked(uid: uid, true) == .applied,
                      await engine.setOutputVolumeChecked(uid: uid, Float(target)) == .applied else { return false }
                outputVolume = target
                return true
            }
            let v = from + (target - from) * (Double(i) / Double(steps))
            guard await engine.setOutputVolumeChecked(uid: uid, Float(v)) == .applied else { return false }
            outputVolume = v
            try? await Task.sleep(for: stepDelay)
        }
        guard !Task.isCancelled, generation == routerWorkGeneration else { return false }
        let target = guardedOutputs[uid].map { Double($0.volume) } ?? to
        guard await engine.setOutputVolumeChecked(uid: uid, Float(target)) == .applied else { return false }
        outputVolume = target
        return true
    }

    func setOutputVolume(_ v: Double) {
        let clamped = max(0, min(1, v))
        outputVolume = clamped
        guard let uid = systemOutputUID else { return }
        if guardedOutputs[uid] != nil {
            guardedOutputs[uid]?.volume = Float(clamped)
        }
        if driverEnabled {
            enqueueRouterWork { model in await model.engine.setOutputVolume(uid: uid, Float(clamped)) }
        } else {
            Task { await engine.setOutputVolume(uid: uid, Float(clamped)) }
        }
    }

    var masterMuted: Bool { config.masterMuted }
    func setMasterMuted(_ muted: Bool) {
        applyGains { $0.masterMuted = muted }
        pushMasterMuteToHardware()
    }

    private func pushMasterMuteToHardware() {
        guard let uid = systemOutputUID else { return }
        let muted = config.masterMuted
        if guardedOutputs[uid] != nil { guardedOutputs[uid]?.muted = muted }
        // Muting is safe immediately, even while a queued switch is fading in.
        if muted {
            Task { _ = await engine.setOutputMutedChecked(uid: uid, true) }
            return
        }
        if driverEnabled {
            enqueueRouterWork { model in
                if muted || model.guardedOutputs[uid] == nil {
                    await model.engine.setOutputMuted(uid: uid, muted)
                }
            }
        } else {
            Task { await engine.setOutputMuted(uid: uid, muted) }
        }
    }

    var masterMeter: Float { config.mixes.map { mixLevel($0.id) }.max() ?? RMSMeter.floorDB }
    var masterMeterLeft: Float { config.mixes.map { mixLevelLeft($0.id) }.max() ?? RMSMeter.floorDB }
    var masterMeterRight: Float { config.mixes.map { mixLevelRight($0.id) }.max() ?? RMSMeter.floorDB }
}
