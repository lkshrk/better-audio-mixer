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

        // Hardware-mute both devices before the break-before-make aggregate swap.
        if let previous, previous != uid { CoreAudioEngine.setDeviceMuted(uid: previous, true) }
        CoreAudioEngine.setDeviceMuted(uid: uid, true)

        var draft = config
        if let i = draft.mixes.firstIndex(where: { $0.id == Self.defaultMixID }) {
            draft.mixes[i].dest = .hardware(uid: uid)
        }
        do { try draft.validate() } catch {
            self.error = String(describing: error)
            AppLog.config.error("system output draft invalid: \(String(describing: error), privacy: .public)")
            if let previous, previous != uid { CoreAudioEngine.setDeviceMuted(uid: previous, false) }
            CoreAudioEngine.setDeviceMuted(uid: uid, false)
            return
        }
        error = nil
        config = draft
        persist(draft)
        guard driverEnabled else {
            if let previous, previous != uid { CoreAudioEngine.setDeviceMuted(uid: previous, false) }
            CoreAudioEngine.setDeviceMuted(uid: uid, false)
            return
        }

        let muted = draft.masterMuted
        enqueueRouterWork { model in
            model.restoringVolume = true
            defer { model.restoringVolume = false }
            model.applyRouterStatus(await model.engine.startRouter(config: draft))
            guard !Task.isCancelled else { return }

            // Re-assert silence after the aggregate rebuild, then restore/fade.
            CoreAudioEngine.setDeviceMuted(uid: uid, true)
            await model.engine.setOutputVolume(uid: uid, 0)
            model.outputVolume = 0

            if muted {
                await model.engine.setOutputVolume(uid: uid, Float(target))
                model.outputVolume = target
            } else {
                CoreAudioEngine.setDeviceMuted(uid: uid, false)
                await model.rampOutputVolume(uid: uid, from: 0, to: target)
            }

            // Unmute the previous device LAST — only after the new output has faded
            // in. It is the macOS default where apps still emit; unmuting it at its
            // (user-max) volume mid-swap briefly plays that audio un-attenuated.
            if let previous, previous != uid {
                await model.engine.setOutputVolume(uid: previous, Float(target))
                await model.engine.setOutputMuted(uid: previous, false)
            }
        }
    }

    func startRouterGuarded(config draft: BamConfig) async -> RouterStatus {
        guard driverEnabled, let uid = Self.hardwareOutputUID(in: draft) else {
            return await engine.startRouter(config: draft)
        }
        let target = await engine.outputVolume(uid: uid).map(Double.init) ?? outputVolume
        let muted = draft.masterMuted

        restoringVolume = true
        await engine.setOutputMuted(uid: uid, true)
        defer { restoringVolume = false }

        let status = await engine.startRouter(config: draft)

        await engine.setOutputMuted(uid: uid, true)
        await engine.setOutputVolume(uid: uid, Float(target))
        if !muted {
            await engine.setOutputMuted(uid: uid, false)
        }
        return status
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
        if let v = await engine.outputVolume(uid: uid) { outputVolume = Double(v) }
    }

    func dimOutputForExit() {
        guard let uid = systemOutputUID else { return }
        let stock = defaults.object(forKey: Self.stockVolumeKey) != nil
            ? defaults.double(forKey: Self.stockVolumeKey) : nil
        let current = CoreAudioEngine.deviceVolume(uid: uid).map(Double.init) ?? outputVolume

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

        if let stock { CoreAudioEngine.setDeviceVolume(uid: uid, Float(stock)) }
        CoreAudioEngine.setDeviceMuted(uid: uid, false)
    }

    func restoreOutputVolume() async {
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
                    held = captureConfirmed ? held + 1 : 0
                    try? await Task.sleep(for: .milliseconds(50))
                }
                if Task.isCancelled { return }
            }
            await rampOutputVolume(uid: uid, from: 0, to: v)
            bamVolumeApplied = true
        }
    }

    private func rampOutputVolume(uid: String, from: Double, to: Double) async {
        guard abs(to - from) > 0.01 else {
            await engine.setOutputVolume(uid: uid, Float(to)); outputVolume = to; return
        }
        await engine.setOutputVolume(uid: uid, Float(from)); outputVolume = from
        let steps = 24
        let stepDelay = Duration.milliseconds(50)
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
        applyGains { $0.masterMuted = muted }
        pushMasterMuteToHardware()
    }

    private func pushMasterMuteToHardware() {
        guard let uid = systemOutputUID else { return }
        let muted = config.masterMuted
        Task { await engine.setOutputMuted(uid: uid, muted) }
    }

    var masterMeter: Float { config.mixes.map { mixLevel($0.id) }.max() ?? RMSMeter.floorDB }
    var masterMeterLeft: Float { config.mixes.map { mixLevelLeft($0.id) }.max() ?? RMSMeter.floorDB }
    var masterMeterRight: Float { config.mixes.map { mixLevelRight($0.id) }.max() ?? RMSMeter.floorDB }
}
