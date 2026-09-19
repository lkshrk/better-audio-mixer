import AppKit
import Foundation

/// Maps Elgato events to BAM commands and BAM frames back to key/dial visuals.
@MainActor
final class ActionRouter {

    private static let prefix = "me.harke.better-audio-mixer.streamdeck."

    enum Kind {
        case device, master, output, unknown
        init(action: String) {
            switch action {
            case prefix + "device": self = .device
            case prefix + "master": self = .master
            case prefix + "output": self = .output
            default:                self = .unknown
            }
        }
    }

    /// Everything a key or dial reads from its Elgato settings, decoded once per bind.
    struct KeySettings: Equatable {
        var mix: String?
        var mode: String
        var step: Double
        var pos: Double
        var keyStyle: KeyStyleImage.KeyStyle
        var dialStyle: KeyStyleImage.KeyStyle
        var outputA: String?
        var outputB: String?
        var showName: Bool

        init(_ raw: [String: Any], kind: Kind) {
            mix = (raw["mix"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            mode = (raw["mode"] as? String) ?? (kind == .output ? "set" : "mute")
            step = (raw["step"] as? Double) ?? 0.05
            pos = (raw["pos"] as? Double) ?? 0
            keyStyle = ActionRouter.normalizedVisualStyle(raw["keyStyle"] as? String)
            dialStyle = ActionRouter.normalizedVisualStyle(raw["style"] as? String)
            outputA = (raw["a"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            outputB = (raw["b"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            showName = (raw["showName"] as? Bool) ?? false
        }
    }

    private static let deviceFallbackSymbol = "speaker.wave.2.fill"
    static let defaultMixID = "mix-default"

    /// -60 dBFS reads better than RMSMeter.floorDB (-120) and matches RMSMeter.fraction's default minDB.
    static let meterFloorDB: Float = -60

    struct RenderCache {
        var layout: String?
        var keyImageSig: String?
        var keyMeterSig: String?
        var title: String?
        var lastKeyImageAt: TimeInterval?
        var lcdStaticSig: String?
        var lcdMeterSig: String?
        var lastDialFeedbackAt: TimeInterval?
    }

    private struct Binding {
        let action: String
        let kind: Kind
        var settings: KeySettings
        var controller: String
        var cache = RenderCache()
        var isEncoder: Bool { controller == "Encoder" }
    }

    private struct MixInfo { var name: String; var emoji: String; var pct: Int; var muted: Bool }
    struct StereoLevel: Equatable { var mono: Float; var left: Float; var right: Float }
    struct StereoPeak: Equatable { var left: Float; var right: Float }

    struct RollingPeakWindow {
        private struct Sample { var left: Float; var right: Float; var at: TimeInterval }

        private let seconds: TimeInterval
        private let floor: Float
        private var samples: [Sample] = []
        private var firstLiveSample = 0
        private(set) var peak: StereoPeak

        init(seconds: TimeInterval, floor: Float) {
            self.seconds = seconds
            self.floor = floor
            self.peak = StereoPeak(left: floor, right: floor)
        }

        mutating func append(left: Float, right: Float, at now: TimeInterval) -> StereoPeak {
            samples.append(Sample(left: left, right: right, at: now))
            let cutoff = now - seconds
            var expired = false
            while firstLiveSample < samples.count, samples[firstLiveSample].at < cutoff {
                firstLiveSample += 1
                expired = true
            }
            if expired {
                peak = samples.dropFirst(firstLiveSample).reduce(StereoPeak(left: floor, right: floor)) { peak, sample in
                    StereoPeak(left: max(peak.left, sample.left), right: max(peak.right, sample.right))
                }
            } else {
                peak = StereoPeak(left: max(peak.left, left), right: max(peak.right, right))
            }
            if firstLiveSample > 64, firstLiveSample * 2 > samples.count {
                samples.removeFirst(firstLiveSample)
                firstLiveSample = 0
            }
            return peak
        }
    }

    private static let silentStereo = StereoLevel(mono: meterFloorDB, left: meterFloorDB, right: meterFloorDB)
    private static let peakWindowSeconds: TimeInterval = 5
    static let dialFeedbackInterval: TimeInterval = 1.0 / 30.0
    static let retroKeyInterval: TimeInterval = 1.0 / 30.0

    private let elgato: ElgatoCommandSink
    private let now: () -> TimeInterval
    /// Sink for frames headed to BAM (cmd / listMixes / listOutputs).
    var sendToBAM: (([String: Any]) -> Void)?

    private var contexts: [String: Binding] = [:]
    private var mixes: [String: MixInfo] = [:]
    /// Server order from the last `state` frame; drives the PI list and the unbound-key default.
    private var mixOrder: [String] = []
    private(set) var levels: [String: StereoLevel] = [:]
    private(set) var peakWindows: [String: RollingPeakWindow] = [:]
    private var masterPct = 0
    private var masterMuted = false
    private var masterLevel = silentStereo
    private var masterPeakWindow = RollingPeakWindow(seconds: peakWindowSeconds, floor: meterFloorDB)
    private var masterIcon = "hifispeaker.fill"
    private var piAction: String?
    private var piContext: String?

    private struct OutputInfo { var uid: String; var name: String; var icon: String }
    private var outputs: [OutputInfo] = []
    private var activeOutputUID: String?
    /// Context whose press issued the pending setOutputDevice.
    private var pendingOutputContext: String?
    private var outputsRequestPending = false

    init(elgato: ElgatoCommandSink,
         now: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }) {
        self.elgato = elgato
        self.now = now
    }

    // MARK: - Elgato events

    func handleEvent(_ event: String, _ obj: [String: Any]) {
        switch event {
        case "willAppear", "didReceiveSettings": bind(obj)
        case "willDisappear":
            if let ctx = obj["context"] as? String { contexts[ctx] = nil }
        case "keyDown":                 keyDown(obj)
        case "dialRotate":              dialRotate(obj)
        case "dialDown", "touchTap":    dialPress(obj)
        case "propertyInspectorDidAppear": piAppeared(obj)
        case "propertyInspectorDidDisappear":
            piAction = nil
            piContext = nil
        case "sendToPlugin":            sendToPlugin(obj)
        default:                        break
        }
    }

    private func bind(_ obj: [String: Any]) {
        guard let ctx = obj["context"] as? String,
              let action = obj["action"] as? String else { return }
        let payload = obj["payload"] as? [String: Any]
        let kind = Kind(action: action)
        let settings = KeySettings(payload?["settings"] as? [String: Any] ?? [:], kind: kind)
        let controller = (payload?["controller"] as? String) ?? contexts[ctx]?.controller ?? "Keypad"
        var binding = Binding(action: action, kind: kind, settings: settings, controller: controller)
        if binding.isEncoder {
            let layout = Self.layoutID(settings.dialStyle)
            if contexts[ctx]?.cache.layout != layout { elgato.setFeedbackLayout(layout, context: ctx) }
            binding.cache.layout = layout
        }
        contexts[ctx] = binding
        if kind == .output { requestOutputs() }
        refresh(ctx)
    }

    private func dialRotate(_ obj: [String: Any]) {
        guard let ctx = obj["context"] as? String, let b = contexts[ctx] else { return }
        let ticks = ((obj["payload"] as? [String: Any])?["ticks"] as? Int) ?? 0
        // Dial step is a positive sensitivity; rotate sign comes from ticks.
        let delta = Double(ticks) * abs(b.settings.step)
        switch b.kind {
        case .device:
            guard let mix = mixID(b.settings) else { return }
            sendToBAM?(["t": "cmd", "op": "nudgePos", "mix": mix, "delta": delta])
        case .master:
            sendToBAM?(["t": "cmd", "op": "nudgeMasterPos", "delta": delta])
        default:
            break
        }
    }

    private func dialPress(_ obj: [String: Any]) {
        guard let ctx = obj["context"] as? String, let b = contexts[ctx] else { return }
        switch b.kind {
        case .device:
            guard let mix = mixID(b.settings) else { return }
            sendToBAM?(["t": "cmd", "op": "toggleMuted", "mix": mix])
        case .master:
            sendMasterMute()
        default:
            break
        }
    }

    /// Master mute is not echoed until the next diff tick, so flip locally first.
    private func sendMasterMute() {
        masterMuted.toggle()
        sendToBAM?(["t": "cmd", "op": "setMasterMuted", "muted": masterMuted])
        for (ctx, b) in contexts where b.kind == .master { refresh(ctx) }
    }

    private static func layoutID(_ style: KeyStyleImage.KeyStyle) -> String {
        switch style {
        case .channel: return "layouts/channel.json"
        case .meter:   return "layouts/meter-focus.json"
        case .retro:   return "layouts/retro.json"
        }
    }

    static func levelFraction(_ db: Float) -> Float {
        guard db > meterFloorDB else { return 0 }
        let clamped = min(db, 0)
        return (clamped - meterFloorDB) / (0 - meterFloorDB)
    }

    nonisolated static func normalizedVisualStyle(_ rawValue: String?) -> KeyStyleImage.KeyStyle {
        switch rawValue ?? "channel" {
        case "bars":   return .meter
        case "radial": return .retro
        default:
            return KeyStyleImage.KeyStyle(rawValue: rawValue ?? "channel") ?? .channel
        }
    }

    static func keyLevelSignature(style: KeyStyleImage.KeyStyle, level: Float, muted: Bool) -> Int {
        MeterScale.quantize(level, steps: MeterScale.segmentCount(for: style), muted: muted)
    }

    private static func keyMeterSignature(style: KeyStyleImage.KeyStyle, level: StereoLevel,
                                          muted: Bool) -> String {
        let flags = muted ? "m" : "u"
        switch style {
        case .meter:
            let leftStep = keyLevelSignature(style: style, level: levelFraction(level.left), muted: muted)
            let rightStep = keyLevelSignature(style: style, level: levelFraction(level.right), muted: muted)
            return "\(styleSignature(style))|\(leftStep)|\(rightStep)|\(flags)"
        case .channel, .retro:
            let step = keyLevelSignature(style: style, level: levelFraction(level.mono), muted: muted)
            return "\(styleSignature(style))|\(step)|\(flags)"
        }
    }

    /// Bound mix, else the first listed mix so an unconfigured key still shows something.
    private func mixID(_ settings: KeySettings) -> String? {
        settings.mix ?? orderedMixIDs.first
    }

    private var orderedMixIDs: [String] {
        let known = mixOrder.filter { mixes[$0] != nil }
        return known.filter { $0 != Self.defaultMixID } + known.filter { $0 == Self.defaultMixID }
    }

    private func keyDown(_ obj: [String: Any]) {
        guard let ctx = obj["context"] as? String, let b = contexts[ctx] else { return }
        let s = b.settings
        switch b.kind {
        case .device:
            guard let mix = mixID(s) else { return }
            switch s.mode {
            case "set":
                sendToBAM?(["t": "cmd", "op": "setPos", "mix": mix, "pos": s.pos])
            case "adjust":
                if let pct = mixes[mix]?.pct, let wrap = Self.wrapPos(pct: pct, step: s.step) {
                    sendToBAM?(["t": "cmd", "op": "setPos", "mix": mix, "pos": wrap])
                } else {
                    sendToBAM?(["t": "cmd", "op": "nudgePos", "mix": mix, "delta": s.step])
                }
            default:
                sendToBAM?(["t": "cmd", "op": "toggleMuted", "mix": mix])
            }
        case .master:
            switch s.mode {
            case "set":    sendToBAM?(["t": "cmd", "op": "setMasterPos", "pos": s.pos])
            case "adjust": sendToBAM?(["t": "cmd", "op": "nudgeMasterPos", "delta": s.step])
            default:       sendMasterMute()
            }
        case .output:
            outputKeyDown(ctx, s)
        case .unknown:
            break
        }
    }

    /// Adjust keys wrap at the rails (100% + step → 0, 0% − step → 1); nil means a normal nudge.
    static func wrapPos(pct: Int, step: Double) -> Double? {
        if step > 0 && pct >= 100 { return 0 }
        if step < 0 && pct <= 0 { return 1 }
        return nil
    }

    private func outputKeyDown(_ ctx: String, _ s: KeySettings) {
        let a = s.outputA
        let b = s.outputB
        func present(_ uid: String?) -> Bool { uid.map { u in outputs.contains { $0.uid == u } } ?? false }

        let target: String?
        switch s.mode {
        case "toggle":
            // Flip A↔B; pin to whichever side is still present.
            let next = (activeOutputUID == a) ? b : a
            if present(next) { target = next }
            else if present(a) { target = a }
            else if present(b) { target = b }
            else { target = nil }
        default:
            target = present(a) ? a : nil
        }

        guard let uid = target else {
            elgato.showAlert(context: ctx)
            return
        }
        pendingOutputContext = ctx
        sendToBAM?(["t": "setOutputDevice", "uid": uid])
    }

    private func requestOutputs() {
        guard !outputsRequestPending else { return }
        outputsRequestPending = true
        sendToBAM?(["t": "listOutputs"])
    }

    // MARK: - Property Inspector

    private func piAppeared(_ obj: [String: Any]) {
        piAction = obj["action"] as? String
        piContext = obj["context"] as? String
        if Kind(action: piAction ?? "") == .output {
            sendOutputsToPI()
            requestOutputs()
        } else {
            sendMixesToPI()
            sendToBAM?(["t": "listMixes"])
        }
    }

    private func sendToPlugin(_ obj: [String: Any]) {
        piAction = obj["action"] as? String
        piContext = obj["context"] as? String
        guard let payload = obj["payload"] as? [String: Any] else { return }
        switch payload["t"] as? String {
        case "listMixes":   sendMixesToPI(); sendToBAM?(["t": "listMixes"])
        case "listOutputs": sendOutputsToPI(); requestOutputs()
        default:            break
        }
    }

    private func mixList() -> [[String: Any]] {
        orderedMixIDs.compactMap { id in
            mixes[id].map { ["id": id, "name": $0.name, "emoji": $0.emoji] }
        }
    }

    private func sendMixesToPI() {
        guard let action = piAction, let context = piContext else { return }
        elgato.sendToPropertyInspector(action: action, context: context,
                                       payload: ["t": "mixes", "mixes": mixList()])
    }

    private func sendOutputsToPI() {
        guard let action = piAction, let context = piContext else { return }
        let list = outputs.map { o -> [String: Any] in
            ["uid": o.uid, "name": o.name, "active": o.uid == activeOutputUID, "icon": o.icon]
        }
        elgato.sendToPropertyInspector(action: action, context: context,
                                       payload: ["t": "outputs", "outputs": list])
    }

    // MARK: - BAM frames

    func ingestBAMFrame(_ obj: [String: Any]) {
        switch obj["t"] as? String {
        case "state":       ingestState(obj); cacheMixes(); refreshAll(); sendMixesToPI()
        case "delta":       ingestDelta(obj)
        case "masterDelta": ingestMasterDelta(obj)
        case "removed":
            if let id = obj["mix"] as? String {
                mixes[id] = nil
                levels[id] = nil
                peakWindows[id] = nil
                mixOrder.removeAll { $0 == id }
                refreshAll()
                cacheMixes()
            }
        case "meter":       ingestMeter(obj)
        case "mixes":       forwardMixesReply(obj)
        case "outputs":     ingestOutputs(obj)
        case "outputs-ack": ingestOutputsAck(obj)
        case "error":       ingestError(obj)
        default:            break
        }
    }

    /// BAM went away: floor every meter so nothing shows a frozen level.
    func markOffline() {
        outputsRequestPending = false
        pendingOutputContext = nil
        for id in levels.keys { levels[id] = Self.silentStereo }
        peakWindows.removeAll()
        masterLevel = Self.silentStereo
        masterPeakWindow = RollingPeakWindow(seconds: Self.peakWindowSeconds, floor: Self.meterFloorDB)
        refreshAll()
    }

    private func ingestOutputs(_ obj: [String: Any]) {
        outputsRequestPending = false
        outputs.removeAll()
        activeOutputUID = nil
        for o in obj["outputs"] as? [[String: Any]] ?? [] {
            guard let uid = o["uid"] as? String else { continue }
            outputs.append(OutputInfo(uid: uid, name: o["name"] as? String ?? uid,
                                      icon: o["icon"] as? String ?? Self.deviceFallbackSymbol))
            if (o["active"] as? Bool) == true { activeOutputUID = uid }
        }
        for (ctx, b) in contexts where b.kind == .output { refresh(ctx) }
        sendOutputsToPI()
    }

    /// setOutputDevice succeeded: flip the active output now, then confirm with the live list.
    private func ingestOutputsAck(_ obj: [String: Any]) {
        pendingOutputContext = nil
        if let uid = obj["uid"] as? String { activeOutputUID = uid }
        for (ctx, b) in contexts where b.kind == .output { refresh(ctx) }
        sendOutputsToPI()
        requestOutputs()
    }

    private func ingestError(_ obj: [String: Any]) {
        guard (obj["op"] as? String) == "setOutputDevice" else { return }
        if let ctx = pendingOutputContext { elgato.showAlert(context: ctx) }
        pendingOutputContext = nil
    }

    private func ingestMeter(_ obj: [String: Any]) {
        let now = now()
        for m in obj["mixes"] as? [[String: Any]] ?? [] {
            // State owns membership; delayed meters must not resurrect deleted mixes.
            guard let id = m["id"] as? String, mixes[id] != nil, let lvl = m["level"] as? Double else { continue }
            let stereo = Self.smoothStereo(levels[id], mono: Float(lvl),
                                           left: (m["levelLeft"] as? Double).map(Float.init),
                                           right: (m["levelRight"] as? Double).map(Float.init))
            levels[id] = stereo
            _ = peakWindows[id, default: RollingPeakWindow(seconds: Self.peakWindowSeconds, floor: Self.meterFloorDB)]
                .append(left: stereo.left, right: stereo.right, at: now)
        }
        if let master = obj["master"] as? [String: Any], let lvl = master["level"] as? Double {
            masterLevel = Self.smoothStereo(masterLevel, mono: Float(lvl),
                                            left: (master["levelLeft"] as? Double).map(Float.init),
                                            right: (master["levelRight"] as? Double).map(Float.init))
            _ = masterPeakWindow.append(left: masterLevel.left, right: masterLevel.right, at: now)
        }
        for (ctx, b) in contexts where b.isEncoder { refresh(ctx, meterFrameAt: now) }
        for (ctx, b) in contexts where shouldRefreshKeyMeter(ctx, b, at: now) { refresh(ctx, meterFrameAt: now) }
    }

    /// Fast attack, moderately damped decay: the dial needle exposes latency more than bars do.
    private static func smoothLevel(_ old: Float, _ new: Float) -> Float {
        let coeff: Float = new >= old ? 0.82 : 0.42
        return old + (new - old) * coeff
    }

    private static func smoothStereo(_ old: StereoLevel?, mono: Float, left: Float?, right: Float?) -> StereoLevel {
        let old = old ?? silentStereo
        return StereoLevel(
            mono: smoothLevel(old.mono, mono),
            left: smoothLevel(old.left, left ?? mono),
            right: smoothLevel(old.right, right ?? mono)
        )
    }

    private func ingestState(_ obj: [String: Any]) {
        mixes.removeAll()
        mixOrder.removeAll()
        for m in obj["mixes"] as? [[String: Any]] ?? [] {
            guard let id = m["id"] as? String else { continue }
            mixes[id] = MixInfo(name: m["name"] as? String ?? id,
                                emoji: m["emoji"] as? String ?? "",
                                pct: m["pct"] as? Int ?? 0,
                                muted: m["muted"] as? Bool ?? false)
            mixOrder.append(id)
        }
        levels = levels.filter { mixes[$0.key] != nil }
        peakWindows = peakWindows.filter { mixes[$0.key] != nil }
        if let master = obj["master"] as? [String: Any] {
            masterPct = master["pct"] as? Int ?? 0
            masterMuted = master["muted"] as? Bool ?? false
            if let icon = master["icon"] as? String, !icon.isEmpty { masterIcon = icon }
        }
        // A state frame opens every connection; an output request dropped while offline is retried here.
        outputsRequestPending = false
        if contexts.values.contains(where: { $0.kind == .output }) { requestOutputs() }
    }

    private func ingestDelta(_ obj: [String: Any]) {
        guard let id = obj["mix"] as? String, var info = mixes[id] else { return }
        if let pct = obj["pct"] as? Int { info.pct = pct }
        if let muted = obj["muted"] as? Bool { info.muted = muted }
        if let name = obj["name"] as? String { info.name = name }
        if let emoji = obj["emoji"] as? String { info.emoji = emoji }
        mixes[id] = info
        if obj["name"] != nil || obj["emoji"] != nil { cacheMixes() }
        for (ctx, b) in contexts where b.kind == .device && mixID(b.settings) == id { refresh(ctx) }
    }

    private func ingestMasterDelta(_ obj: [String: Any]) {
        if let pct = obj["pct"] as? Int { masterPct = pct }
        if let muted = obj["muted"] as? Bool { masterMuted = muted }
        for (ctx, b) in contexts where b.kind == .master { refresh(ctx) }
    }

    private func forwardMixesReply(_ obj: [String: Any]) {
        guard let action = piAction, let context = piContext else { return }
        elgato.sendToPropertyInspector(action: action, context: context, payload: obj)
    }

    private func cacheMixes() {
        elgato.setGlobalSettings(["mixes": mixList()])
    }

    // MARK: - Visuals

    private func refreshAll() { for ctx in contexts.keys { refresh(ctx) } }

    private func refresh(_ ctx: String, meterFrameAt: TimeInterval? = nil) {
        guard let b = contexts[ctx] else { return }
        let now = meterFrameAt ?? now()
        switch b.kind {
        case .device:
            let id = mixID(b.settings)
            let info = id.flatMap { mixes[$0] }
            if b.isEncoder {
                pushKnobImage(ctx, glyph: deviceGlyph(info), muted: info?.muted ?? false, at: now)
                if shouldSkipDialFeedback(ctx, at: meterFrameAt) { return }
                pushDialFeedback(ctx, DialRenderInput(
                    style: b.settings.dialStyle, glyph: deviceGlyph(info), name: info?.name ?? "",
                    pct: info?.pct ?? 0, muted: info?.muted ?? false,
                    level: id.flatMap { levels[$0] } ?? Self.silentStereo,
                    peak: id.flatMap { peakWindows[$0]?.peak },
                    monogram: KeyHeader.initials(info?.name ?? ""),
                    accent: id.map(Palette.accent(forID:)) ?? Palette.accents[0]))
                return
            }
            guard let id, let info else {
                pushRawKeyImage({ nil }, sig: "", context: ctx, at: now)
                setTitleIfChanged("", context: ctx)
                return
            }
            pushKeyImage(ctx, KeyStyleImage.Input(
                style: b.settings.keyStyle, glyph: deviceGlyph(info), monogram: KeyHeader.initials(info.name),
                accent: Palette.accent(forID: id), name: info.name, pct: info.pct,
                level: Self.levelFraction(levels[id]?.mono ?? Self.meterFloorDB),
                leftLevel: Self.levelFraction(levels[id]?.left ?? Self.meterFloorDB),
                rightLevel: Self.levelFraction(levels[id]?.right ?? Self.meterFloorDB),
                muted: info.muted), stereo: levels[id] ?? Self.silentStereo, at: now)
            setTitleIfChanged("", context: ctx)
        case .master:
            if b.isEncoder {
                pushKnobImage(ctx, glyph: .symbol(masterIcon), muted: masterMuted, at: now)
                if shouldSkipDialFeedback(ctx, at: meterFrameAt) { return }
                pushDialFeedback(ctx, DialRenderInput(
                    style: b.settings.dialStyle, glyph: .symbol(masterIcon), name: "Master",
                    pct: masterPct, muted: masterMuted, level: masterLevel,
                    peak: masterPeakWindow.peak, monogram: "M", accent: Palette.masterAccent))
                return
            }
            pushKeyImage(ctx, KeyStyleImage.Input(
                style: b.settings.keyStyle, glyph: .symbol(masterIcon), monogram: "M",
                accent: Palette.masterAccent, name: "Master", pct: masterPct,
                level: Self.levelFraction(masterLevel.mono),
                leftLevel: Self.levelFraction(masterLevel.left),
                rightLevel: Self.levelFraction(masterLevel.right),
                muted: masterMuted), stereo: masterLevel, at: now)
            setTitleIfChanged("", context: ctx)
        case .output:
            refreshOutput(ctx, b, at: now)
        case .unknown:
            break
        }
    }

    private func shouldSkipDialFeedback(_ ctx: String, at now: TimeInterval?) -> Bool {
        guard let now else { return false }
        if let last = contexts[ctx]?.cache.lastDialFeedbackAt, now - last < Self.dialFeedbackInterval {
            return true
        }
        contexts[ctx]?.cache.lastDialFeedbackAt = now
        return false
    }

    private func boundLevel(_ b: Binding) -> StereoLevel? {
        switch b.kind {
        case .device: return mixID(b.settings).map { levels[$0] ?? Self.silentStereo }
        case .master: return masterLevel
        default:      return nil
        }
    }

    private func shouldRefreshKeyMeter(_ ctx: String, _ b: Binding, at now: TimeInterval) -> Bool {
        guard !b.isEncoder, let level = boundLevel(b) else { return false }
        let muted: Bool
        switch b.kind {
        case .device:
            guard let id = mixID(b.settings), let info = mixes[id] else { return false }
            muted = info.muted
        case .master:
            muted = masterMuted
        default:
            return false
        }
        let style = b.settings.keyStyle
        let sig = Self.keyMeterSignature(style: style, level: level, muted: muted)
        guard b.cache.keyMeterSig != sig else { return false }
        if style == .retro, let last = b.cache.lastKeyImageAt, now - last < Self.retroKeyInterval {
            return false
        }
        return true
    }

    private func setTitleIfChanged(_ title: String, context ctx: String) {
        guard contexts[ctx]?.cache.title != title else { return }
        contexts[ctx]?.cache.title = title
        elgato.setTitle(title, context: ctx)
    }

    /// Renders only when the signature moved, so the cost of an unchanged frame is a string compare.
    /// The Stream Deck app draws a dial's setImage as its knob in the configuration canvas.
    private func pushKnobImage(_ ctx: String, glyph: KeyImage.Glyph, muted: Bool, at now: TimeInterval) {
        pushRawKeyImage({ KeyImage.render(glyph, muted: muted, mono: true) },
                        sig: Self.glyphSignature(glyph) + (muted ? "|m" : "|u"), context: ctx, at: now)
    }

    private func pushRawKeyImage(_ render: () -> String?, sig: String, context ctx: String, at now: TimeInterval) {
        guard contexts[ctx]?.cache.keyImageSig != sig else { return }
        contexts[ctx]?.cache.keyImageSig = sig
        contexts[ctx]?.cache.lastKeyImageAt = now
        elgato.setImage(render(), context: ctx)
    }

    /// Glyph mirrors the app: the SF Symbol the console derives for the hardware output.
    private func refreshOutput(_ ctx: String, _ b: Binding, at now: TimeInterval) {
        let s = b.settings
        // Show the active output if it is one of the key's targets, else the primary (A) target.
        let shownUID: String? = {
            if let active = activeOutputUID, active == s.outputA || active == s.outputB { return active }
            return s.outputA ?? s.outputB
        }()
        let shown = outputs.first { $0.uid == shownUID }
        let activeName = outputs.first { $0.uid == activeOutputUID }?.name
        let name = shown?.name ?? activeName ?? (s.mode == "toggle" ? "A/B" : "")
        let glyph: KeyImage.Glyph = .symbol(shown?.icon ?? Self.deviceFallbackSymbol)
        pushRawKeyImage({ KeyImage.render(glyph, muted: false) }, sig: Self.glyphSignature(glyph), context: ctx, at: now)
        setTitleIfChanged(s.showName ? name : "", context: ctx)
    }

    private func deviceGlyph(_ info: MixInfo?) -> KeyImage.Glyph {
        if let emoji = info?.emoji, !emoji.isEmpty { return .emoji(emoji) }
        return .symbol(Self.deviceFallbackSymbol)
    }

    private func pushKeyImage(_ ctx: String, _ input: KeyStyleImage.Input, stereo: StereoLevel, at now: TimeInterval) {
        let meterSig = Self.keyMeterSignature(style: input.style, level: stereo, muted: input.muted)
        contexts[ctx]?.cache.keyMeterSig = meterSig
        let sig = [
            Self.styleSignature(input.style), Self.glyphSignature(input.glyph), input.monogram,
            input.accent.hex, input.name, "\(input.pct)", meterSig,
        ].joined(separator: "|")
        pushRawKeyImage({ KeyStyleImage.render(input) }, sig: sig, context: ctx, at: now)
    }

    private struct DialRenderInput {
        let style: KeyStyleImage.KeyStyle
        let glyph: KeyImage.Glyph
        let name: String
        let pct: Int
        let muted: Bool
        let level: StereoLevel
        let peak: StereoPeak?
        let monogram: String
        let accent: RGB
    }

    /// Pushes only the LCD layers whose signature changed; an empty payload is not sent.
    private func pushDialFeedback(_ ctx: String, _ input: DialRenderInput) {
        var p: [String: Any] = [:]
        let flags = input.muted ? "m" : "u"
        let styleKey = Self.styleSignature(input.style)

        let staticSig = [
            styleKey, input.name, input.monogram, "\(input.pct)", flags,
            Self.glyphSignature(input.glyph), input.accent.hex,
        ].joined(separator: "|")

        let meterSig: String
        var meterLayers: [String: () -> String] = [:]
        switch input.style {
        case .retro:
            let step = MeterScale.quantize(Self.levelFraction(input.level.mono), steps: MeterScale.lcdNeedleSteps, muted: input.muted)
            let peakDB = input.peak.map { max($0.left, $0.right) } ?? Self.meterFloorDB
            let peakStep = MeterScale.quantize(Self.levelFraction(peakDB), steps: MeterScale.lcdNeedleSteps, muted: input.muted)
            meterSig = "\(styleKey)|\(step)|\(peakStep)|\(flags)"
            meterLayers["levelNeedle"] = {
                RetroMeterDrawing.renderRetroLCDNeedleSVG(step: step, peakStep: peakStep, muted: input.muted)
            }
        case .channel, .meter:
            let bar = { (db: Float) in MeterScale.quantize(Self.levelFraction(db), steps: MeterScale.lcdBarSteps, muted: input.muted) }
            let left = bar(input.level.left), right = bar(input.level.right)
            let peakLeft = bar(input.peak?.left ?? input.level.left)
            let peakRight = bar(input.peak?.right ?? input.level.right)
            if input.style == .channel {
                let step = max(left, right), peak = max(peakLeft, peakRight)
                let rect = RetroMeterDrawing.lcdChannelBar
                meterSig = "\(styleKey)|\(step)|\(peak)|\(flags)"
                meterLayers["liveMeter"] = {
                    RetroMeterDrawing.renderLCDLevelBarSVG(width: Int(rect.width), height: Int(rect.height),
                                                           step: step, peakStep: peak, muted: input.muted)
                }
            } else {
                let rect = RetroMeterDrawing.lcdLeftBar
                meterSig = "\(styleKey)|\(left)|\(right)|\(peakLeft)|\(peakRight)|\(flags)"
                meterLayers["leftMeter"] = {
                    RetroMeterDrawing.renderLCDLevelBarSVG(width: Int(rect.width), height: Int(rect.height),
                                                           step: left, peakStep: peakLeft, muted: input.muted)
                }
                meterLayers["rightMeter"] = {
                    RetroMeterDrawing.renderLCDLevelBarSVG(width: Int(rect.width), height: Int(rect.height),
                                                           step: right, peakStep: peakRight, muted: input.muted)
                }
            }
        }

        if contexts[ctx]?.cache.lcdStaticSig != staticSig {
            contexts[ctx]?.cache.lcdStaticSig = staticSig
            p["canvas"] = RetroMeterDrawing.renderLCDStatic(RetroMeterDrawing.LCDInput(
                style: input.style, glyph: input.glyph, monogram: input.monogram, accent: input.accent,
                name: input.name, pct: input.pct, muted: input.muted)) ?? ""
        }
        if contexts[ctx]?.cache.lcdMeterSig != meterSig {
            contexts[ctx]?.cache.lcdMeterSig = meterSig
            for (key, layer) in meterLayers { p[key] = layer() }
        }

        guard !p.isEmpty else { return }
        elgato.setFeedback(p, context: ctx)
    }

    private static func styleSignature(_ style: KeyStyleImage.KeyStyle) -> String {
        switch style {
        case .channel: return "c"
        case .meter: return "m"
        case .retro: return "r"
        }
    }

    private static func glyphSignature(_ glyph: KeyImage.Glyph?) -> String {
        switch glyph {
        case .emoji(let s):  return "e:" + s
        case .symbol(let s): return "s:" + s
        case nil:            return "-"
        }
    }
}
