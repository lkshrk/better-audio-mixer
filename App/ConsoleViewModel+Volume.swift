import AudioEngine
import BamCore
import Foundation

extension ConsoleViewModel {
    /// Explicit master-unmute releases a whole-device mute, including one left
    /// by failed startup. Partial channel mute calibration remains intact.
    nonisolated static func outputStateWithMasterUnmuted(_ state: OutputDeviceState) -> OutputDeviceState {
        var result = state
        if state.muted { result.mutes = state.mutes.mapValues { _ in false } }
        return result
    }

    func captureOutputState(uid: String) async -> OutputDeviceState? {
        guard let state = await engine.outputDeviceState(uid: uid) else { return nil }
        rememberOutputState(state)
        return state
    }

    private func rememberOutputState(_ state: OutputDeviceState) {
        if stockOutputStates[state.uid]?.deviceID != state.deviceID {
            stockOutputStates[state.uid] = state
        }
        if let previous = outputCalibrations[state.uid], previous.deviceID == state.deviceID {
            if state.volume > 0 {
                var calibration = state
                calibration.mutes = previous.mutes
                outputCalibrations[state.uid] = calibration
            }
        } else {
            outputCalibrations[state.uid] = state
        }
    }

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
        requestedOutputVolumes[uid] = Float(target)
        enqueueRouterWork { model in
            let generation = model.routerWorkGeneration
            let target = Double(model.requestedOutputVolumes[uid] ?? Float(target))
            let status = await model.startRouterGuarded(config: draft, fadeIn: true, targetVolume: target)
            guard !Task.isCancelled, generation == model.routerWorkGeneration else { return }
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
        if !guardedOutputs.isEmpty {
            let available = Set(await engine.outputDevices().map(\.uid))
            uids.formUnion(available.intersection(guardedOutputs.keys))
        }
        let requested = Self.hardwareOutputUID(in: draft)
        let overrides: [String: Float]
        if let requested, let target = targetVolume.map(Float.init) ?? (!bamVolumeApplied ? requestedOutputVolumes[requested] : nil) {
            overrides = [requested: target]
        }
        else { overrides = [:] }
        guard await protectOutputs(uids, overriding: overrides) else {
            return outputProtectionFailed()
        }
        guard !Task.isCancelled, generation == routerWorkGeneration else { return outputProtectionFailed() }

        let status = await engine.startRouter(config: draft)
        guard !status.isFailure else { return status }
        guard !Task.isCancelled, generation == routerWorkGeneration else { return outputProtectionFailed() }
        let bound = await engine.boundOutputUID()
        func transferReboundTarget() {
            guard let bound, let requested, bound != requested,
                  let original = overrides[requested] else { return }
            let intentUID = systemOutputUID == bound ? bound : requested
            guardedOutputs[bound]?.volume = requestedOutputVolumes[intentUID] ?? original
        }
        transferReboundTarget()
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
            transferReboundTarget()
            let muted = config.masterMuted || (guardedOutputs[uid]?.muted ?? saved.muted)
            if fadeIn, uid == bound, !muted {
                guard await engine.setOutputVolumeChecked(uid: uid, 0) == .applied,
                      !Task.isCancelled, generation == routerWorkGeneration else {
                    return outputProtectionFailed()
                }
                if !config.masterMuted, guardedOutputs[uid]?.muted != true {
                    let state = guardedOutputs[uid]?.state ?? saved.state
                    guard await engine.restoreOutputDeviceState(state, restoreVolume: false, restoreMute: true) == .applied else {
                        return outputProtectionFailed()
                    }
                }
                guard await rampOutputVolume(uid: uid, from: 0, to: Double(saved.volume),
                                             intentUID: uid == requested ? nil : requested) else {
                    _ = await engine.setOutputMutedChecked(uid: uid, true)
                    return outputProtectionFailed()
                }
            } else {
                var state: OutputDeviceState
                repeat {
                    transferReboundTarget()
                    state = guardedOutputs[uid]?.state ?? saved.state
                    guard await engine.restoreOutputDeviceState(state, restoreVolume: true, restoreMute: false) == .applied,
                          !Task.isCancelled, generation == routerWorkGeneration else {
                        return outputProtectionFailed()
                    }
                    transferReboundTarget()
                } while (guardedOutputs[uid]?.state.volumes ?? state.volumes) != state.volumes
                if !config.masterMuted, !(guardedOutputs[uid]?.muted ?? saved.muted) {
                    let state = guardedOutputs[uid]?.state ?? saved.state
                    guard await engine.restoreOutputDeviceState(state, restoreVolume: false, restoreMute: true) == .applied else {
                        return outputProtectionFailed()
                    }
                }
            }
            if uid == systemOutputUID { outputVolume = Double(guardedOutputs[uid]?.volume ?? saved.volume) }
            await engine.acknowledgeOutputRestore(uids: [uid])
            guardedOutputs[uid] = nil
        }
        error = nil
        bamVolumeApplied = true
        return status
    }

    private func protectOutputs(_ uids: Set<String>, overriding volumes: [String: Float] = [:]) async -> Bool {
        // Snapshot every device before the first mute, preserving intent from failures.
        for uid in uids.sorted() {
            if guardedOutputs[uid] == nil {
                let previousTarget = requestedOutputVolumes[uid]
                guard let state = await captureOutputState(uid: uid) else { return false }
                guardedOutputs[uid] = GuardedOutput(state: state, calibration: outputCalibrations[uid] ?? state)
                if requestedOutputVolumes[uid] != previousTarget, let target = requestedOutputVolumes[uid] {
                    guardedOutputs[uid]?.volume = target
                }
            }
            if let volume = volumes[uid] { guardedOutputs[uid]?.volume = requestedOutputVolumes[uid] ?? volume }
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
                  await engine.restoreOutputDeviceState(saved.state, restoreVolume: true, restoreMute: false) == .applied else {
                _ = outputProtectionFailed()
                return false
            }
        }
        for uid in uids.sorted() {
            guard let saved = guardedOutputs[uid] else { continue }
            if !config.masterMuted, !saved.muted {
                guard await engine.restoreOutputDeviceState(saved.state, restoreVolume: false, restoreMute: true) == .applied else {
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

    func refreshOutputVolume() async {
        guard !restoringVolume else { return }
        guard let uid = systemOutputUID else { return }
        guard guardedOutputs[uid] == nil else { return }
        let requested = requestedOutputVolumes[uid]
        guard let v = await engine.outputVolume(uid: uid),
              systemOutputUID == uid, !restoringVolume, guardedOutputs[uid] == nil,
              requestedOutputVolumes[uid] == requested else { return }
        outputVolume = Double(v)
    }

    func dimOutputForExit() {
        guard let uid = systemOutputUID else { return }
        guard let currentState = CoreAudioEngine.deviceState(uid: uid) else {
            _ = CoreAudioEngine.setDeviceMutedChecked(uid: uid, true)
            return
        }
        rememberOutputState(currentState)
        let stock = defaults.object(forKey: Self.stockVolumeKey) != nil
            ? defaults.double(forKey: Self.stockVolumeKey) : nil
        let current = Double(currentState.volume)

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
        let savedStates = stockOutputStates
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            defer { sem.signal() }
            _ = await Self.restoreOutputsForExit(engine: engine, config: draft, savedStates: savedStates)
        }
        _ = sem.wait(timeout: .now() + 1.0)
    }

    nonisolated static func restoreOutputsForExit(engine: any AudioEngineProtocol, config: BamConfig,
                                                 savedStates: [String: OutputDeviceState]) async -> Bool {
        await engine.setRouterRecoverySuspended(true)
        var uids = await engine.routerOutputUIDs(config: config)
        let available = Set(await engine.outputDevices().map(\.uid))
        uids.formUnion(available.intersection(savedStates.keys))
        var states: [OutputDeviceState] = []
        for uid in uids.sorted() {
            if let state = savedStates[uid] { states.append(state) }
            else if let state = await engine.outputDeviceState(uid: uid) { states.append(state) }
            else { return false }
        }
        for uid in uids {
            guard await engine.setOutputMutedChecked(uid: uid, true) == .applied else { return false }
        }
        guard await engine.stopRouterChecked() else { return false }
        for state in states {
            guard await engine.restoreOutputDeviceState(state, restoreVolume: true, restoreMute: false) == .applied else { return false }
        }
        for state in states {
            guard await engine.restoreOutputDeviceState(state, restoreVolume: false, restoreMute: true) == .applied else { return false }
        }
        await engine.acknowledgeOutputRestore(uids: uids)
        return true
    }

    func stageSavedOutputVolume() {
        guard driverEnabled, let uid = systemOutputUID, requestedOutputVolumes[uid] == nil,
              defaults.object(forKey: Self.savedVolumeKey) != nil else { return }
        let saved = defaults.double(forKey: Self.savedVolumeKey)
        guard saved.isFinite else { return }
        requestedOutputVolumes[uid] = Float(max(0, min(1, saved)))
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
            guard !Task.isCancelled, generation == model.routerWorkGeneration else { return }
            model.applyRouterStatus(status)
        }.value
    }

    private func rampOutputVolume(uid: String, from: Double, to: Double, intentUID: String? = nil) async -> Bool {
        AppLog.router.notice("hardware volume ramp from=\(from, privacy: .public) target=\(to, privacy: .public) uid=\(uid, privacy: .private)")
        let generation = routerWorkGeneration
        let initialState: OutputDeviceState
        if let state = guardedOutputs[uid]?.state { initialState = state }
        else if let state = await captureOutputState(uid: uid) { initialState = state }
        else { return false }
        rampOutputTargets[uid] = Float(to)
        defer { rampOutputTargets[uid] = nil }
        func write(_ scalar: Float) async -> Bool {
            let calibration = guardedOutputs[uid]?.calibration ?? outputCalibrations[uid] ?? initialState
            let state = calibration.withVolume(scalar)
            guard await engine.restoreOutputDeviceState(state, restoreVolume: true, restoreMute: false) == .applied else { return false }
            outputVolume = Double(state.volume)
            return true
        }
        guard abs(to - from) > 0.01 else {
            guard await write(Float(to)) else { return false }
            return true
        }
        guard await write(Float(from)) else { return false }
        let steps = 24
        let stepDelay = Duration.milliseconds(50)
        for i in 1...steps {
            if Task.isCancelled || generation != routerWorkGeneration { return false }
            if let intentUID, let target = requestedOutputVolumes[systemOutputUID == uid ? uid : intentUID] {
                guardedOutputs[uid]?.volume = target
            }
            let target = Double(guardedOutputs[uid]?.volume ?? rampOutputTargets[uid] ?? Float(to))
            if config.masterMuted || guardedOutputs[uid]?.muted == true {
                guard await engine.setOutputMutedChecked(uid: uid, true) == .applied,
                      await write(Float(target)) else { return false }
                return true
            }
            let v = from + (target - from) * (Double(i) / Double(steps))
            guard await write(Float(v)) else { return false }
            do { try await outputRampSleep(stepDelay) } catch { return false }
        }
        guard !Task.isCancelled, generation == routerWorkGeneration else { return false }
        if let intentUID, let target = requestedOutputVolumes[systemOutputUID == uid ? uid : intentUID] {
            guardedOutputs[uid]?.volume = target
        }
        let target = Double(guardedOutputs[uid]?.volume ?? rampOutputTargets[uid] ?? Float(to))
        guard await write(Float(target)) else { return false }
        return true
    }

    func setOutputVolume(_ v: Double, origin: String = "ui") {
        guard v.isFinite else { return }
        let clamped = max(0, min(1, v))
        AppLog.router.notice("hardware volume requested origin=\(origin, privacy: .public) target=\(clamped, privacy: .public)")
        outputVolume = clamped
        guard let uid = systemOutputUID else { return }
        requestedOutputVolumes[uid] = Float(clamped)
        if rampOutputTargets[uid] != nil { rampOutputTargets[uid] = Float(clamped) }
        if guardedOutputs[uid] != nil {
            guardedOutputs[uid]?.volume = Float(clamped)
        }
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
        if guardedOutputs[uid] != nil { guardedOutputs[uid]?.muted = muted }
        // Muting is safe immediately, even while a queued switch is fading in.
        if muted {
            Task {
                if guardedOutputs[uid] == nil { _ = await captureOutputState(uid: uid) }
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
            for (uid, volume) in targets.volumes {
                guard !Task.isCancelled else { return }
                // Failed routes retain guard ownership; only a successful rebuild
                // or checked teardown may restore their hardware controls.
                guard model.guardedOutputs[uid] == nil else { continue }
                guard let current = await model.captureOutputState(uid: uid) else { continue }
                guard model.guardedOutputs[uid] == nil, !Task.isCancelled else { continue }
                let state = (model.outputCalibrations[uid] ?? current).withVolume(volume)
                AppLog.router.notice("hardware volume queued apply target=\(state.volume, privacy: .public) uid=\(uid, privacy: .private)")
                guard await model.engine.restoreOutputDeviceState(state, restoreVolume: true, restoreMute: false) == .applied else {
                    model.guardedOutputs[uid] = GuardedOutput(state: state, calibration: model.outputCalibrations[uid] ?? current)
                    if let latest = model.requestedOutputVolumes[uid] { model.guardedOutputs[uid]?.volume = latest }
                    _ = await model.engine.setOutputMutedChecked(uid: uid, true)
                    model.applyRouterStatus(model.outputProtectionFailed())
                    continue
                }
                if uid == model.systemOutputUID, model.requestedOutputVolumes[uid] == volume {
                    model.outputVolume = Double(state.volume)
                }
            }
            for uid in targets.muteUIDs {
                guard !Task.isCancelled else { return }
                guard model.guardedOutputs[uid] == nil else {
                    AppLog.router.notice("hardware unmute deferred; output protection retained uid=\(uid, privacy: .private)")
                    continue
                }
                if !model.config.masterMuted {
                    guard let current = await model.captureOutputState(uid: uid) else { continue }
                    guard model.guardedOutputs[uid] == nil else {
                        AppLog.router.notice("hardware unmute deferred; output protection retained uid=\(uid, privacy: .private)")
                        continue
                    }
                    guard !model.config.masterMuted, !Task.isCancelled else { continue }
                    let state = Self.outputStateWithMasterUnmuted(model.outputCalibrations[uid] ?? current)
                    guard await model.engine.restoreOutputDeviceState(state, restoreVolume: false, restoreMute: true) == .applied else {
                        AppLog.router.error("hardware unmute failed uid=\(uid, privacy: .private)")
                        model.applyRouterStatus(model.outputProtectionFailed())
                        continue
                    }
                }
            }
        }
        pendingOutputTargets = targets
        return targets
    }

    var masterMeter: Float { config.mixes.map { mixLevel($0.id) }.max() ?? RMSMeter.floorDB }
    var masterMeterLeft: Float { config.mixes.map { mixLevelLeft($0.id) }.max() ?? RMSMeter.floorDB }
    var masterMeterRight: Float { config.mixes.map { mixLevelRight($0.id) }.max() ?? RMSMeter.floorDB }
}
