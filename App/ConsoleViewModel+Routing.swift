import BamCore
import Foundation

extension ConsoleViewModel {
    // MARK: live meters

    func mixLevel(_ id: String) -> Float {
        snapshot.mixes.first { $0.id == id }?.level ?? RMSMeter.floorDB
    }

    func mixLevelLeft(_ id: String) -> Float {
        snapshot.mixes.first { $0.id == id }?.levelLeft ?? mixLevel(id)
    }

    func mixLevelRight(_ id: String) -> Float {
        snapshot.mixes.first { $0.id == id }?.levelRight ?? mixLevel(id)
    }

    func mixPeakLeft(_ id: String) -> Float { mixPeaks[id]?.left.peak ?? RMSMeter.floorDB }
    func mixPeakRight(_ id: String) -> Float { mixPeaks[id]?.right.peak ?? RMSMeter.floorDB }
    var masterPeakLeft: Float { masterPeak.left.peak }
    var masterPeakRight: Float { masterPeak.right.peak }

    // MARK: sends (routing within a mix)

    func send(_ sourceID: String, in mixID: String) -> Send? {
        config.mixes.first { $0.id == mixID }?.sends.first { $0.source == sourceID }
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

    // MARK: source app membership (group panel)

    func apps(for source: Source) -> [SourceApp] {
        source.bundleIDs.map { bid in
            let live = runningApps.first { $0.bundleID == bid }
            return SourceApp(bundleID: bid,
                             name: live?.displayName ?? Self.prettyName(bid),
                             playing: playing.contains(bid))
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

    var devices: [Mix] { config.mixes }

    func isDefaultDevice(_ mixID: String) -> Bool { mixID == Self.defaultMixID }

    func deviceSourceID(_ mixID: String) -> String? {
        config.mixes.first { $0.id == mixID }?.sends.first?.source
    }

    func deviceApps(_ mixID: String) -> [SourceApp] {
        if isDefaultDevice(mixID) {
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

    /// Set (or clear, with nil -> auto hue) the device's chip color, stored as a 0...1 hue.
    func setDeviceColor(_ mixID: String, _ hue: Double?) {
        guard !isDefaultDevice(mixID) else { return }
        applyGains { cfg in
            if let i = cfg.mixes.firstIndex(where: { $0.id == mixID }) { cfg.mixes[i].tone = hue }
        }
    }

    /// Moves an app to a device; the Default catch-all just leaves it stripped so the remainder routes it.
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

    /// Remove an app from a device -> it falls back into the Default remainder.
    func removeApp(_ bundleID: String, fromDevice mixID: String) {
        guard !isDefaultDevice(mixID), let sid = deviceSourceID(mixID) else { return }
        removeApp(bundleID, from: sid)
    }

    func deviceLevel(_ mixID: String) -> Double {
        config.mixes.first { $0.id == mixID }?.level ?? 1.0
    }

    func setDeviceLevel(_ mixID: String, _ level: Double) {
        applyGains { cfg in
            if let i = cfg.mixes.firstIndex(where: { $0.id == mixID }) { cfg.mixes[i].level = level }
        }
    }

    func deviceMuted(_ mixID: String) -> Bool {
        guard let sid = deviceSourceID(mixID) else { return false }
        return send(sid, in: mixID)?.muted ?? false
    }
    func setDeviceMuted(_ mixID: String, _ muted: Bool) {
        guard let sid = deviceSourceID(mixID) else { return }
        setSendMuted(sid, in: mixID, muted)
    }
}
