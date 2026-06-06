import BamCore
import Foundation

extension ConsoleViewModel {
    // MARK: live meters

    func sourceLevel(_ id: String) -> Float {
        snapshot.sources.first { $0.id == id }?.level ?? RMSMeter.floorDB
    }

    func mixLevel(_ id: String) -> Float {
        snapshot.mixes.first { $0.id == id }?.level ?? RMSMeter.floorDB
    }

    func mixLevelLeft(_ id: String) -> Float {
        snapshot.mixes.first { $0.id == id }?.levelLeft ?? mixLevel(id)
    }

    func mixLevelRight(_ id: String) -> Float {
        snapshot.mixes.first { $0.id == id }?.levelRight ?? mixLevel(id)
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
                for mi in cfg.mixes.indices {
                    cfg.mixes[mi].sends.removeAll { $0.source == sourceID }
                }
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
            for si in cfg.sources.indices where cfg.sources[si].kind == .app {
                cfg.sources[si].bundleIDs.removeAll { $0 == app.bundleID }
            }
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

    /// Set (or clear, with nil -> auto hue) the device's chip color, stored as a 0...1 hue.
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

    /// Remove an app from a device -> it falls back into the Default remainder.
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
}
