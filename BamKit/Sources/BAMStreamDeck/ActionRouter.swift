import AppKit
import Foundation

/// Owns all Stream Deck key state for the four keypad actions. Maps Elgato
/// events (willAppear / keyDown / settings / PI) to BAM commands, and maps
/// inbound BAM frames (state / delta / removed / mixes) back to key visuals
/// (setTitle / setState) and the PI device dropdown.
@MainActor
final class ActionRouter {

    private static let prefix = "me.harke.better-audio-mixer.streamdeck."

    enum Kind {
        case device, master, deviceDial, masterDial, output, unknown
        init(action: String) {
            switch action {
            case prefix + "device":      self = .device
            case prefix + "master":      self = .master
            case prefix + "device-dial": self = .deviceDial
            case prefix + "master-dial": self = .masterDial
            case prefix + "output":      self = .output
            default:                     self = .unknown
            }
        }
        var isDial: Bool { self == .deviceDial || self == .masterDial }
    }

    /// SF Symbol drawn when a device has no emoji configured (e.g. the Default
    /// catch-all). Keeps the key — and its mute slash — readable.
    private static let deviceFallbackSymbol = "speaker.wave.2.fill"

    /// Visual floor for the LCD meter bar. RMSMeter.floorDB (-120) is too low to
    /// read; -60 dBFS matches RMSMeter.fraction's default minDB.
    private static let meterFloorDB: Float = -60

    private struct Binding {
        let action: String
        let kind: Kind
        var settings: [String: Any]
        /// "Keypad" or "Encoder" — the Device/Master actions support both.
        var controller: String = "Keypad"
        var isEncoder: Bool { controller == "Encoder" }
    }

    private struct MixInfo { var name: String; var emoji: String; var pct: Int; var muted: Bool }
    private struct StereoLevel { var mono: Float; var left: Float; var right: Float }
    struct StereoPeak: Equatable { var left: Float; var right: Float }

    struct RollingPeakWindow {
        private struct Sample { var left: Float; var right: Float; var at: TimeInterval }

        private let seconds: TimeInterval
        private let floor: Float
        private var samples: [Sample] = []
        private var firstLiveSample = 0

        init(seconds: TimeInterval, floor: Float) {
            self.seconds = seconds
            self.floor = floor
        }

        mutating func append(left: Float, right: Float, at now: TimeInterval) -> StereoPeak {
            samples.append(Sample(left: left, right: right, at: now))
            let cutoff = now - seconds
            while firstLiveSample < samples.count, samples[firstLiveSample].at < cutoff {
                firstLiveSample += 1
            }
            if firstLiveSample > 64, firstLiveSample * 2 > samples.count {
                samples.removeFirst(firstLiveSample)
                firstLiveSample = 0
            }
            return peak
        }

        var peak: StereoPeak {
            samples.dropFirst(firstLiveSample).reduce(StereoPeak(left: floor, right: floor)) { peak, sample in
                StereoPeak(left: max(peak.left, sample.left),
                           right: max(peak.right, sample.right))
            }
        }
    }

    private static let silentStereo = StereoLevel(mono: meterFloorDB, left: meterFloorDB, right: meterFloorDB)
    private static let peakWindowSeconds: TimeInterval = 5
    private static let dialFeedbackInterval: TimeInterval = 1.0 / 40.0

    private let elgato: ElgatoCommandSink
    /// Sink for frames headed to BAM (cmd / listMixes).
    var sendToBAM: (([String: Any]) -> Void)?

    private var contexts: [String: Binding] = [:]
    private var mixes: [String: MixInfo] = [:]
    private var levels: [String: StereoLevel] = [:]
    private var peakWindows: [String: RollingPeakWindow] = [:]
    private var masterPct = 0
    private var masterMuted = false
    private var masterLevel = StereoLevel(mono: meterFloorDB, left: meterFloorDB, right: meterFloorDB)
    private var masterPeakWindow = RollingPeakWindow(seconds: peakWindowSeconds, floor: meterFloorDB)
    private var masterIcon = "hifispeaker.fill"
    /// Last icon signature pushed to each dial's LCD, so the (expensive) base64
    /// pixmap is only re-sent when the glyph or mute state actually changes —
    /// meter/value updates stay tiny and can run at full frame rate.
    private var dialIconSig: [String: String] = [:]
    private var lcdStaticSig: [String: String] = [:]
    private var lcdMeterSig: [String: String] = [:]
    private var retroNeedleSig: [String: String] = [:]
    private var keyImageSig: [String: String] = [:]
    private var lastDialFeedback: [String: TimeInterval] = [:]
    private var dialFeedbackSig: [String: String] = [:]
    private var keyMeterSig: [String: String] = [:]
    private var keyStateSig: [String: Int] = [:]
    private var titleSig: [String: String] = [:]
    private var colorSigCache: [String: String] = [:]
    private var piAction: String?
    private var piContext: String?

    private struct OutputInfo { var uid: String; var name: String; var icon: String }
    /// Ordered hardware outputs from the last `outputs` frame (PI list + toggle targets).
    private var outputs: [OutputInfo] = []
    private var activeOutputUID: String?
    /// Context whose press issued the pending setOutputDevice.
    private var pendingOutputContext: String?

    init(elgato: ElgatoCommandSink) { self.elgato = elgato }

    // MARK: - Elgato events

    func handleEvent(_ event: String, _ obj: [String: Any]) {
        switch event {
        case "willAppear":          bind(obj)
        case "didReceiveSettings":  bind(obj)
        case "willDisappear":
            if let ctx = obj["context"] as? String {
                contexts[ctx] = nil
                dialIconSig[ctx] = nil
                lcdStaticSig[ctx] = nil
                lcdMeterSig[ctx] = nil
                retroNeedleSig[ctx] = nil
                keyImageSig[ctx] = nil
                lastDialFeedback[ctx] = nil
                dialFeedbackSig[ctx] = nil
                keyMeterSig[ctx] = nil
                keyStateSig[ctx] = nil
                titleSig[ctx] = nil
                colorSigCache[ctx] = nil
            }
        case "keyDown":             keyDown(obj)
        case "dialRotate":          dialRotate(obj)
        case "dialDown":            dialPress(obj)
        case "propertyInspectorDidAppear": piAppeared(obj)
        case "sendToPlugin":        sendToPlugin(obj)
        default:                    break
        }
    }

    private func bind(_ obj: [String: Any]) {
        guard let ctx = obj["context"] as? String,
              let action = obj["action"] as? String else { return }
        let payload = obj["payload"] as? [String: Any]
        let settings = payload?["settings"] as? [String: Any] ?? [:]
        let controller = (payload?["controller"] as? String) ?? "Keypad"
        let kind = Kind(action: action)
        contexts[ctx] = Binding(action: action, kind: kind, settings: settings, controller: controller)
        dialIconSig[ctx] = nil
        lcdStaticSig[ctx] = nil
        lcdMeterSig[ctx] = nil
        retroNeedleSig[ctx] = nil
        keyImageSig[ctx] = nil
        lastDialFeedback[ctx] = nil
        dialFeedbackSig[ctx] = nil
        keyMeterSig[ctx] = nil
        keyStateSig[ctx] = nil
        titleSig[ctx] = nil
        colorSigCache[ctx] = nil
        if controller == "Encoder" {
            let style = (settings["style"] as? String) ?? "channel"
            elgato.setFeedbackLayout(layoutID(style), context: ctx)
        }
        if kind == .output { sendToBAM?(["t": "listOutputs"]) }
        refresh(ctx)
    }

    private func dialRotate(_ obj: [String: Any]) {
        guard let ctx = obj["context"] as? String, let b = contexts[ctx] else { return }
        let ticks = ((obj["payload"] as? [String: Any])?["ticks"] as? Int) ?? 0
        // Dial step is a positive sensitivity; rotate sign comes from ticks.
        let step = abs((b.settings["step"] as? Double) ?? 0.05)
        let delta = Double(ticks) * step
        switch b.kind {
        case .device, .deviceDial:
            guard let mix = b.settings["mix"] as? String else { return }
            sendToBAM?(["t": "cmd", "op": "nudgePos", "mix": mix, "delta": delta])
        case .master, .masterDial:
            sendToBAM?(["t": "cmd", "op": "nudgeMasterPos", "delta": delta])
        default:
            break
        }
    }

    private func dialPress(_ obj: [String: Any]) {
        guard let ctx = obj["context"] as? String, let b = contexts[ctx] else { return }
        switch b.kind {
        case .device, .deviceDial:
            guard let mix = b.settings["mix"] as? String else { return }
            sendToBAM?(["t": "cmd", "op": "toggleMuted", "mix": mix])
        case .master, .masterDial:
            sendMasterMute()
        default:
            break
        }
    }

    /// Master mute/pos changes are not echoed as `delta` frames (the server only
    /// diffs mixes), so flip the local flag optimistically and refresh master keys.
    private func sendMasterMute() {
        masterMuted.toggle()
        sendToBAM?(["t": "cmd", "op": "setMasterMuted", "muted": masterMuted])
        for (ctx, b) in contexts where b.kind == .master || b.kind == .masterDial { refresh(ctx) }
    }

    private func layoutID(_ style: String) -> String {
        switch style {
        case "channel", "combined", "slider": return "layouts/channel.json"
        case "meter", "bars": return "layouts/meter-focus.json"
        case "retro":  return "layouts/retro.json"
        case "radial": return "layouts/retro.json"
        default:       return "layouts/channel.json"
        }
    }

    static func levelPercent(_ db: Float) -> Int {
        guard db > meterFloorDB else { return 0 }
        let clamped = min(db, 0)
        return Int(((clamped - meterFloorDB) / (0 - meterFloorDB)) * 100)
    }

    /// Same mapping as `levelPercent` but as a 0…1 fraction for the styled-key meters.
    static func levelFraction(_ db: Float) -> Float {
        guard db > meterFloorDB else { return 0 }
        let clamped = min(db, 0)
        return (clamped - meterFloorDB) / (0 - meterFloorDB)
    }

    /// Accent palette for styled keys. Devices pick by a stable hash of their mix id;
    /// master is fixed purple.
    static let accentPalette: [NSColor] = [
        NSColor(calibratedRed: 0.36, green: 0.62, blue: 1.00, alpha: 1), // blue
        NSColor(calibratedRed: 0.30, green: 0.80, blue: 0.45, alpha: 1), // green
        NSColor(calibratedRed: 1.00, green: 0.55, blue: 0.30, alpha: 1), // orange
        NSColor(calibratedRed: 0.95, green: 0.40, blue: 0.55, alpha: 1), // pink
        NSColor(calibratedRed: 0.30, green: 0.78, blue: 0.82, alpha: 1), // teal
    ]
    static let masterAccent = NSColor(calibratedRed: 0.70, green: 0.45, blue: 0.95, alpha: 1)

    nonisolated static func accent(forID id: String) -> NSColor {
        var h: UInt64 = 1469598103934665603 // FNV-1a
        for byte in id.utf8 { h = (h ^ UInt64(byte)) &* 1099511628211 }
        switch h % 5 {
        case 0: return NSColor(calibratedRed: 0.36, green: 0.62, blue: 1.00, alpha: 1)
        case 1: return NSColor(calibratedRed: 0.30, green: 0.80, blue: 0.45, alpha: 1)
        case 2: return NSColor(calibratedRed: 1.00, green: 0.55, blue: 0.30, alpha: 1)
        case 3: return NSColor(calibratedRed: 0.95, green: 0.40, blue: 0.55, alpha: 1)
        default: return NSColor(calibratedRed: 0.30, green: 0.78, blue: 0.82, alpha: 1)
        }
    }

    static func normalizedVisualStyle(_ rawValue: String?) -> KeyStyleImage.KeyStyle {
        switch rawValue ?? "channel" {
        case "bars":   return .meter
        case "radial": return .retro
        default:
            return KeyStyleImage.KeyStyle(rawValue: rawValue ?? "channel") ?? .channel
        }
    }

    static func keyLevelSignature(style: KeyStyleImage.KeyStyle, level: Float, muted: Bool) -> Int {
        guard !muted else { return 0 }
        let clamped = max(0, min(1, level))
        let steps: Float
        switch style {
        case .channel: steps = 12
        case .meter: steps = 18
        case .retro: steps = 100
        }
        return Int((clamped * steps).rounded())
    }

    private static func keyMeterSignature(style: KeyStyleImage.KeyStyle, level: StereoLevel, muted: Bool) -> String {
        switch style {
        case .meter:
            let leftStep = keyLevelSignature(style: style, level: levelFraction(level.left), muted: muted)
            let rightStep = keyLevelSignature(style: style, level: levelFraction(level.right), muted: muted)
            return "\(Self.styleSignature(style))|\(leftStep)|\(rightStep)|\(muted ? "m" : "u")"
        case .channel, .retro:
            let step = keyLevelSignature(style: style, level: levelFraction(level.mono), muted: muted)
            return "\(Self.styleSignature(style))|\(step)|\(muted ? "m" : "u")"
        }
    }

    private func keyStyle(_ b: Binding) -> KeyStyleImage.KeyStyle {
        Self.normalizedVisualStyle(b.settings["keyStyle"] as? String)
    }

    private func dialStyle(_ b: Binding) -> KeyStyleImage.KeyStyle {
        Self.normalizedVisualStyle(b.settings["style"] as? String)
    }

    private func keyDown(_ obj: [String: Any]) {
        guard let ctx = obj["context"] as? String, let b = contexts[ctx] else { return }
        let s = (obj["payload"] as? [String: Any])?["settings"] as? [String: Any] ?? b.settings
        let step = (s["step"] as? Double) ?? 0.05 // signed: + raises, − lowers
        let pos = (s["pos"] as? Double) ?? 0

        switch b.kind {
        case .device:
            guard let mix = s["mix"] as? String else { return }
            switch (s["mode"] as? String) ?? "mute" {
            case "set":    sendToBAM?(["t": "cmd", "op": "setPos", "mix": mix, "pos": pos])
            case "adjust":
                if let wrap = Self.wrapPos(pct: mixes[mix]?.pct ?? 0, step: step) {
                    sendToBAM?(["t": "cmd", "op": "setPos", "mix": mix, "pos": wrap])
                } else {
                    sendToBAM?(["t": "cmd", "op": "nudgePos", "mix": mix, "delta": step])
                }
            default:       sendToBAM?(["t": "cmd", "op": "toggleMuted", "mix": mix])
            }
        case .master:
            switch (s["mode"] as? String) ?? "mute" {
            case "set":    sendToBAM?(["t": "cmd", "op": "setMasterPos", "pos": pos])
            case "adjust":
                if let wrap = Self.wrapPos(pct: masterPct, step: step) {
                    sendToBAM?(["t": "cmd", "op": "setMasterPos", "pos": wrap])
                } else {
                    sendToBAM?(["t": "cmd", "op": "nudgeMasterPos", "delta": step])
                }
            default:       sendMasterMute()
            }
        case .output:
            outputKeyDown(ctx, s)
        default:
            break
        }
    }

    /// Wrap-around at the rails for Adjust keys: a positive step at 100% returns
    /// 0.0, a negative step at 0% returns 1.0. Returns nil when a normal nudge
    /// applies.
    static func wrapPos(pct: Int, step: Double) -> Double? {
        if step > 0 && pct >= 100 { return 0 }
        if step < 0 && pct <= 0 { return 1 }
        return nil
    }

    /// Computes the target device from the action's mode/A/B settings and issues
    /// the switch.
    private func outputKeyDown(_ ctx: String, _ s: [String: Any]) {
        let mode = (s["mode"] as? String) ?? "set"
        let a = s["a"] as? String
        let b = s["b"] as? String
        func present(_ uid: String?) -> Bool { uid.map { u in outputs.contains { $0.uid == u } } ?? false }

        let target: String?
        switch mode {
        case "toggle":
            // Flip A↔B; pin to whichever side is still present.
            let next = (activeOutputUID == a) ? b : a
            if present(next) { target = next }
            else if present(a) { target = a }
            else if present(b) { target = b }
            else { target = nil }
        default: // "set"
            target = present(a) ? a : nil
        }

        guard let uid = target else {
            elgato.showAlert(context: ctx) // both targets gone / unconfigured
            return
        }
        pendingOutputContext = ctx
        sendToBAM?(["t": "setOutputDevice", "uid": uid])
    }

    // MARK: - Property Inspector

    private func piAppeared(_ obj: [String: Any]) {
        piAction = obj["action"] as? String
        piContext = obj["context"] as? String
        if Kind(action: piAction ?? "") == .output {
            sendOutputsToPI()                 // serve cache immediately
            sendToBAM?(["t": "listOutputs"])  // then refresh live
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
        case "listMixes":   sendMixesToPI();   sendToBAM?(["t": "listMixes"])
        case "listOutputs": sendOutputsToPI(); sendToBAM?(["t": "listOutputs"])
        default:            break
        }
    }

    private func sendMixesToPI() {
        guard let action = piAction, let context = piContext else { return }
        let list = mixes.map { id, m in ["id": id, "name": m.name, "emoji": m.emoji] }
        elgato.sendToPropertyInspector(action: action, context: context,
                                       payload: ["t": "mixes", "mixes": list])
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
        case "state":   ingestState(obj); cacheMixes(); refreshAll(); sendMixesToPI()
        case "delta":   ingestDelta(obj); cacheMixes()
        case "masterDelta": ingestMasterDelta(obj)
        case "removed":
            if let id = obj["mix"] as? String {
                mixes[id] = nil
                levels[id] = nil
                peakWindows[id] = nil
                refreshAll()
                cacheMixes()
            }
        case "meter":   ingestMeter(obj)
        case "mixes":   forwardMixesReply(obj)
        case "outputs": ingestOutputs(obj)
        case "outputs-ack": ingestOutputsAck(obj)
        case "error":   ingestError(obj)
        default:        break
        }
    }

    private func ingestOutputs(_ obj: [String: Any]) {
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

    /// setOutputDevice succeeded: optimistically flip the active output so the key
    /// glyph updates immediately, then re-request the live list to confirm.
    private func ingestOutputsAck(_ obj: [String: Any]) {
        pendingOutputContext = nil
        if let uid = obj["uid"] as? String { activeOutputUID = uid }
        for (ctx, b) in contexts where b.kind == .output { refresh(ctx) }
        sendOutputsToPI()
        sendToBAM?(["t": "listOutputs"])
    }

    /// setOutputDevice failed (unknown/virtual UID): flash an alert on the pressing key.
    private func ingestError(_ obj: [String: Any]) {
        guard (obj["op"] as? String) == "setOutputDevice" else { return }
        if let ctx = pendingOutputContext { elgato.showAlert(context: ctx) }
        pendingOutputContext = nil
    }

    /// Level-only frame (~30fps). Drives dial LCD meters at the full source rate,
    /// and refreshes styled key meters when their visible level step changes.
    /// Dial feedback mostly ships tiny value/bar numbers; keys are guarded by
    /// `keyImageSig`, with segmented styles quantized to their drawn state count.
    private func ingestMeter(_ obj: [String: Any]) {
        let now = Date().timeIntervalSinceReferenceDate
        for m in obj["mixes"] as? [[String: Any]] ?? [] {
            if let id = m["id"] as? String, let lvl = m["level"] as? Double {
                let left = (m["levelLeft"] as? Double).map(Float.init)
                let right = (m["levelRight"] as? Double).map(Float.init)
                let stereo = smoothStereo(levels[id], mono: Float(lvl), left: left, right: right)
                levels[id] = stereo
                var window = peakWindows[id]
                    ?? RollingPeakWindow(seconds: Self.peakWindowSeconds, floor: Self.meterFloorDB)
                _ = window.append(left: stereo.left, right: stereo.right, at: now)
                peakWindows[id] = window
            }
        }
        if let master = obj["master"] as? [String: Any], let lvl = master["level"] as? Double {
            let left = (master["levelLeft"] as? Double).map(Float.init)
            let right = (master["levelRight"] as? Double).map(Float.init)
            masterLevel = smoothStereo(masterLevel, mono: Float(lvl), left: left, right: right)
            _ = masterPeakWindow.append(left: masterLevel.left, right: masterLevel.right, at: now)
        }
        for (ctx, b) in contexts where b.kind.isDial || b.isEncoder { refresh(ctx, meterFrameAt: now) }
        for (ctx, b) in contexts where shouldRefreshKeyMeter(context: ctx, binding: b) { refresh(ctx) }
    }

    /// Ballistics for the LCD level meter. The dial needle exposes latency more
    /// than bars do, so keep attack fast and decay only moderately damped.
    private func smoothLevel(_ old: Float, _ new: Float) -> Float {
        let coeff: Float = new >= old ? 0.82 : 0.42
        return old + (new - old) * coeff
    }

    private func smoothStereo(_ old: StereoLevel?, mono: Float, left: Float?, right: Float?) -> StereoLevel {
        let old = old ?? StereoLevel(mono: Self.meterFloorDB, left: Self.meterFloorDB, right: Self.meterFloorDB)
        let l = left ?? mono
        let r = right ?? mono
        return StereoLevel(
            mono: smoothLevel(old.mono, mono),
            left: smoothLevel(old.left, l),
            right: smoothLevel(old.right, r)
        )
    }

    private func ingestState(_ obj: [String: Any]) {
        mixes.removeAll()
        for m in obj["mixes"] as? [[String: Any]] ?? [] {
            guard let id = m["id"] as? String else { continue }
            mixes[id] = MixInfo(name: m["name"] as? String ?? id,
                                emoji: m["emoji"] as? String ?? "",
                                pct: m["pct"] as? Int ?? 0,
                                muted: m["muted"] as? Bool ?? false)
        }
        if let master = obj["master"] as? [String: Any] {
            masterPct = master["pct"] as? Int ?? 0
            masterMuted = master["muted"] as? Bool ?? false
            if let icon = master["icon"] as? String, !icon.isEmpty { masterIcon = icon }
        }
    }

    private func ingestDelta(_ obj: [String: Any]) {
        guard let id = obj["mix"] as? String else { return }
        guard var info = mixes[id] else { return }
        if let pct = obj["pct"] as? Int { info.pct = pct }
        if let muted = obj["muted"] as? Bool { info.muted = muted }
        if let name = obj["name"] as? String { info.name = name }
        if let emoji = obj["emoji"] as? String { info.emoji = emoji }
        mixes[id] = info
        refreshMix(id)
    }

    private func ingestMasterDelta(_ obj: [String: Any]) {
        if let pct = obj["pct"] as? Int { masterPct = pct }
        if let muted = obj["muted"] as? Bool { masterMuted = muted }
        for (ctx, b) in contexts where b.kind == .master || b.kind == .masterDial { refresh(ctx) }
    }

    private func forwardMixesReply(_ obj: [String: Any]) {
        guard let action = piAction, let context = piContext else { return }
        elgato.sendToPropertyInspector(action: action, context: context, payload: obj)
    }

    private func cacheMixes() {
        let list = mixes.map { id, m in ["id": id, "name": m.name, "emoji": m.emoji] }
        elgato.setGlobalSettings(["mixes": list])
    }

    // MARK: - Key visuals

    private func refreshAll() { for ctx in contexts.keys { refresh(ctx) } }

    private func refreshMix(_ id: String) {
        for (ctx, b) in contexts where (b.settings["mix"] as? String) == id { refresh(ctx) }
    }

    private func refresh(_ ctx: String, meterFrameAt: TimeInterval? = nil) {
        guard let b = contexts[ctx] else { return }
        switch b.kind {
        case .device:
            // One action on key OR dial, three modes (mute / adjust / set).
            // On a dial: LCD band feedback. On a key: centered emoji glyph, no
            // background, speaker-symbol fallback, red slash in mute mode while
            // muted; label is user-chosen (none / name / custom / volume).
            let info = (b.settings["mix"] as? String).flatMap { mixes[$0] }
            if b.isEncoder {
                if shouldSkipDialFeedback(ctx: ctx, at: meterFrameAt) { return }
                let mixID = b.settings["mix"] as? String
                let level = mixID.flatMap { levels[$0] } ?? Self.silentStereo
                let peak = mixID.flatMap { peakWindows[$0]?.peak }
                let groupName = info?.name ?? ""
                let accent = mixID.map(Self.accent(forID:)) ?? Self.accentPalette[0]
                pushDialFeedback(ctx, b, glyph: deviceGlyph(info), name: info?.name ?? "",
                                 pct: info?.pct ?? 0, muted: info?.muted ?? false, level: level,
                                 peak: peak,
                                 monogram: initials(groupName),
                                 accent: accent, colorSig: colorSignature(forContext: ctx, accent: accent))
                return
            }
            guard let info, let mixID = b.settings["mix"] as? String else {
                keyImageSig[ctx] = nil
                elgato.setImage(nil, context: ctx); setTitleIfChanged("", context: ctx); return
            }
            if ((b.settings["mode"] as? String) ?? "mute") == "mute" {
                setStateIfChanged(info.muted ? 1 : 0, context: ctx)
            }
            let accent = Self.accent(forID: mixID)
            let level = levels[mixID] ?? Self.silentStereo
            pushKeyImage(ctx, style: keyStyle(b), glyph: deviceGlyph(info),
                         monogram: initials(info.name), accent: accent,
                         colorSig: colorSignature(forContext: ctx, accent: accent),
                         name: info.name, pct: info.pct,
                         level: level,
                         muted: info.muted)
            setTitleIfChanged("", context: ctx) // name/% are baked into the image
        case .master:
            // Same key/dial split as .device, but always the app's output-device
            // icon (no emoji) and no device picker.
            if b.isEncoder {
                if shouldSkipDialFeedback(ctx: ctx, at: meterFrameAt) { return }
                pushDialFeedback(ctx, b, glyph: .symbol(masterIcon), name: "Master",
                                 pct: masterPct, muted: masterMuted, level: masterLevel,
                                 peak: masterPeakWindow.peak,
                                 monogram: "M", accent: Self.masterAccent,
                                 colorSig: colorSignature(forContext: ctx, accent: Self.masterAccent))
                return
            }
            if ((b.settings["mode"] as? String) ?? "mute") == "mute" {
                setStateIfChanged(masterMuted ? 1 : 0, context: ctx)
            }
            pushKeyImage(ctx, style: keyStyle(b), glyph: .symbol(masterIcon),
                         monogram: "M", accent: Self.masterAccent,
                         colorSig: colorSignature(forContext: ctx, accent: Self.masterAccent),
                         name: "Master", pct: masterPct, level: masterLevel,
                         muted: masterMuted)
            setTitleIfChanged("", context: ctx)
        case .deviceDial:
            if shouldSkipDialFeedback(ctx: ctx, at: meterFrameAt) { return }
            let info = (b.settings["mix"] as? String).flatMap { mixes[$0] }
            let mixID = b.settings["mix"] as? String
            let level = mixID.flatMap { levels[$0] } ?? Self.silentStereo
            let peak = mixID.flatMap { peakWindows[$0]?.peak }
            let groupName = info?.name ?? ""
            let accent = mixID.map(Self.accent(forID:)) ?? Self.accentPalette[0]
            pushDialFeedback(ctx, b, glyph: deviceGlyph(info), name: info?.name ?? "",
                             pct: info?.pct ?? 0, muted: info?.muted ?? false, level: level,
                             peak: peak,
                             monogram: initials(groupName),
                             accent: accent, colorSig: colorSignature(forContext: ctx, accent: accent))
        case .masterDial:
            if shouldSkipDialFeedback(ctx: ctx, at: meterFrameAt) { return }
            pushDialFeedback(ctx, b, glyph: .symbol(masterIcon), name: "Master",
                             pct: masterPct, muted: masterMuted, level: masterLevel,
                             peak: masterPeakWindow.peak,
                             monogram: "M", accent: Self.masterAccent,
                             colorSig: colorSignature(forContext: ctx, accent: Self.masterAccent))
        case .output:
            refreshOutput(ctx, b)
        case .unknown:
            break
        }
    }

    private func shouldSkipDialFeedback(ctx: String, at now: TimeInterval?) -> Bool {
        guard let now else { return false }
        if let last = lastDialFeedback[ctx], now - last < Self.dialFeedbackInterval {
            return true
        }
        lastDialFeedback[ctx] = now
        return false
    }

    private func shouldRefreshKeyMeter(context ctx: String, binding b: Binding) -> Bool {
        guard !b.isEncoder else { return false }
        let style = keyStyle(b)
        let level: StereoLevel
        let muted: Bool
        switch b.kind {
        case .device:
            guard let mixID = b.settings["mix"] as? String, let info = mixes[mixID] else { return false }
            muted = info.muted
            level = levels[mixID] ?? Self.silentStereo
        case .master:
            muted = masterMuted
            level = masterLevel
        default:
            return false
        }
        let sig = Self.keyMeterSignature(style: style, level: level, muted: muted)
        guard keyMeterSig[ctx] != sig else { return false }
        keyMeterSig[ctx] = sig
        return true
    }

    private func setStateIfChanged(_ state: Int, context ctx: String) {
        guard keyStateSig[ctx] != state else { return }
        keyStateSig[ctx] = state
        elgato.setState(state, context: ctx)
    }

    /// Title = the user's emoji for the shown device (centered, no background), with
    /// the device name optionally on a second line when `showName` is set. Falls back
    /// to initials when no emoji is configured.
    private func refreshOutput(_ ctx: String, _ b: Binding) {
        let activeName = outputs.first { $0.uid == activeOutputUID }?.name
        let mode = (b.settings["mode"] as? String) ?? "set"
        // Resolve which uid this key would show as "current": active if it's one of
        // the key's targets, else the key's primary (A) target.
        let a = b.settings["a"] as? String
        let bUID = b.settings["b"] as? String
        let shownUID: String? = {
            if let active = activeOutputUID, active == a || active == bUID { return active }
            return a ?? bUID
        }()
        let shown = outputs.first { $0.uid == shownUID }
        let emojis = b.settings["emoji"] as? [String: String] ?? [:]
        let name = shown?.name ?? activeName ?? (mode == "toggle" ? "A/B" : "")
        let showName = (b.settings["showName"] as? Bool) ?? false
        // Icon mirrors the app: the user's per-device emoji if set, else the same
        // SF Symbol the console derives for the hardware (sent over the wire).
        let glyph: KeyImage.Glyph = shownUID.flatMap { emojis[$0] }.map { .emoji($0) }
            ?? .symbol(shown?.icon ?? Self.deviceFallbackSymbol)
        elgato.setImage(KeyImage.render(glyph, muted: false), context: ctx)
        setTitleIfChanged(showName ? name : "", context: ctx)
    }

    private func setTitleIfChanged(_ title: String, context ctx: String) {
        guard titleSig[ctx] != title else { return }
        titleSig[ctx] = title
        elgato.setTitle(title, context: ctx)
    }

    /// Device glyph for keys and dial LCDs: the user's emoji, or the speaker
    /// fallback symbol when none is set (e.g. the Default catch-all).
    private func deviceGlyph(_ info: MixInfo?) -> KeyImage.Glyph {
        if let emoji = info?.emoji, !emoji.isEmpty { return .emoji(emoji) }
        return .symbol(Self.deviceFallbackSymbol)
    }

    private func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" })
        let chars = words.prefix(2).compactMap { $0.first }
        return chars.isEmpty ? "?" : String(chars).uppercased()
    }

    private struct KeyRenderInput {
        let style: KeyStyleImage.KeyStyle
        let glyph: KeyImage.Glyph
        let monogram: String
        let accent: NSColor
        let colorSig: String
        let name: String
        let pct: Int
        let level: StereoLevel
        let muted: Bool
    }

    private func pushKeyImage(_ ctx: String, style: KeyStyleImage.KeyStyle,
                              glyph: KeyImage.Glyph, monogram: String, accent: NSColor,
                              colorSig: String, name: String, pct: Int, level: StereoLevel, muted: Bool) {
        let input = KeyRenderInput(style: style, glyph: glyph, monogram: monogram,
                                   accent: accent, colorSig: colorSig, name: name,
                                   pct: pct, level: level, muted: muted)
        let levelStep = Self.keyMeterSignature(style: input.style, level: input.level, muted: input.muted)
        keyMeterSig[ctx] = levelStep
        let sig = keyImageSignature(input, levelStep: levelStep)
        guard keyImageSig[ctx] != sig else { return }
        keyImageSig[ctx] = sig
        let img = KeyStyleImage.renderOptimized(
            style: input.style, glyph: input.glyph, monogram: input.monogram, accent: input.accent,
            name: input.name, pct: input.pct, level: Self.levelFraction(input.level.mono),
            leftLevel: Self.levelFraction(input.level.left),
            rightLevel: Self.levelFraction(input.level.right), muted: input.muted)
        elgato.setImage(img, context: ctx)
    }

    private func keyImageSignature(_ input: KeyRenderInput, levelStep: String) -> String {
        [
            Self.styleSignature(input.style), glyphSignature(input.glyph), input.monogram,
            input.colorSig, input.name, "\(input.pct)", levelStep, input.muted ? "m" : "u"
        ].joined(separator: "|")
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
        let accent: NSColor
        let colorSig: String
        let styleKey: String

        var valueText: String { muted ? "MUTED" : "\(pct)%" }
    }

    /// Pushes one LCD frame. All three encoder LCD styles use a full-canvas pixmap
    /// so Stream Deck's native text/bar widgets cannot clip or reject the layout.
    private func pushDialFeedback(_ ctx: String, _ b: Binding, glyph: KeyImage.Glyph,
                                  name: String, pct: Int, muted: Bool, level: StereoLevel,
                                  peak: StereoPeak?,
                                  monogram: String, accent: NSColor, colorSig: String) {
        let style = dialStyle(b)
        let input = DialRenderInput(style: style, glyph: glyph, name: name,
                                    pct: pct, muted: muted, level: level, peak: peak,
                                    monogram: monogram, accent: accent, colorSig: colorSig,
                                    styleKey: Self.styleSignature(style))
        var p: [String: Any] = [
            "title": input.name,
            "value": input.valueText,
            "slider": input.pct,
            "meter": input.muted ? 0 : Self.levelPercent(input.level.mono),
        ]
        let iconSig = dialIconSignature(input)
        var staticSig = ""
        var meterSig = ""
        var feedbackChanged = false
        switch input.style {
        case .retro:
            lcdMeterSig[ctx] = nil
            staticSig = dialStaticSignature(input)
            if lcdStaticSig[ctx] != staticSig {
                lcdStaticSig[ctx] = staticSig
                feedbackChanged = true
                p["canvas"] = RetroMeterDrawing.renderRetroLCDStatic(
                    name: input.name, glyph: input.glyph, monogram: input.monogram,
                    accent: input.accent, pct: input.pct, muted: input.muted) ?? ""
            }
            let needleStep = RetroMeterDrawing.retroLCDLevelNeedleStep(
                level: Self.levelFraction(input.level.mono), muted: input.muted)
            let needleSig = "\(needleStep)|\(input.muted ? "m" : "u")"
            if retroNeedleSig[ctx] != needleSig {
                retroNeedleSig[ctx] = needleSig
                meterSig = needleSig
                feedbackChanged = true
                p["levelNeedle"] = RetroMeterDrawing.renderRetroLCDLevelNeedleSVG(
                    step: needleStep, muted: input.muted)
            } else {
                meterSig = needleSig
            }
        case .channel, .meter:
            retroNeedleSig[ctx] = nil
            p["levelNeedle"] = ["enabled": false]
            staticSig = dialStaticSignature(input)
            if lcdStaticSig[ctx] != staticSig {
                lcdStaticSig[ctx] = staticSig
                feedbackChanged = true
                p["canvas"] = RetroMeterDrawing.renderLCDStatic(
                    style: input.style, name: input.name, glyph: input.glyph, monogram: input.monogram,
                    accent: input.accent, pct: input.pct, muted: input.muted) ?? ""
            }

            let leftStep = RetroMeterDrawing.lcdLevelBarStep(
                level: Self.levelFraction(input.level.left), muted: input.muted)
            let rightStep = RetroMeterDrawing.lcdLevelBarStep(
                level: Self.levelFraction(input.level.right), muted: input.muted)
            let peakLeftStep = RetroMeterDrawing.lcdLevelBarStep(
                level: Self.levelFraction(input.peak?.left ?? input.level.left), muted: input.muted)
            let peakRightStep = RetroMeterDrawing.lcdLevelBarStep(
                level: Self.levelFraction(input.peak?.right ?? input.level.right), muted: input.muted)
            meterSig = dialMeterSignature(input, leftStep: leftStep, rightStep: rightStep,
                                          peakLeftStep: peakLeftStep, peakRightStep: peakRightStep)
            if lcdMeterSig[ctx] != meterSig {
                lcdMeterSig[ctx] = meterSig
                feedbackChanged = true
                if input.style == .channel {
                    p["liveMeter"] = RetroMeterDrawing.renderLCDLevelBarSVG(
                        width: 128, height: 17, step: max(leftStep, rightStep),
                        peakStep: max(peakLeftStep, peakRightStep), muted: input.muted)
                } else {
                    p["leftMeter"] = RetroMeterDrawing.renderLCDLevelBarSVG(
                        width: 113, height: 13, step: leftStep,
                        peakStep: peakLeftStep, muted: input.muted)
                    p["rightMeter"] = RetroMeterDrawing.renderLCDLevelBarSVG(
                        width: 113, height: 13, step: rightStep,
                        peakStep: peakRightStep, muted: input.muted)
                }
            }
        }
        if dialIconSig[ctx] != iconSig {
            dialIconSig[ctx] = iconSig
            feedbackChanged = true
            let img = KeyImage.render(input.glyph, muted: input.muted, tint: true)
            elgato.setImage(img, context: ctx)
            p["icon"] = img ?? ""
        }
        let feedbackSig = dialFeedbackSignature(input, staticSig: staticSig,
                                                meterSig: meterSig, iconSig: iconSig)
        guard feedbackChanged || dialFeedbackSig[ctx] != feedbackSig else { return }
        dialFeedbackSig[ctx] = feedbackSig
        elgato.setFeedback(p, context: ctx)
    }

    private func dialStaticSignature(_ input: DialRenderInput) -> String {
        [
            input.styleKey, input.name, input.monogram, "\(input.pct)",
            input.muted ? "m" : "u", glyphSignature(input.glyph), input.colorSig
        ].joined(separator: "|")
    }

    private func dialIconSignature(_ input: DialRenderInput) -> String {
        glyphSignature(input.glyph) + (input.muted ? "|m" : "")
    }

    private func dialMeterSignature(_ input: DialRenderInput, leftStep: Int, rightStep: Int,
                                    peakLeftStep: Int, peakRightStep: Int) -> String {
        [
            input.styleKey, "\(leftStep)", "\(rightStep)",
            "\(peakLeftStep)", "\(peakRightStep)", input.muted ? "m" : "u"
        ].joined(separator: "|")
    }

    private func dialFeedbackSignature(_ input: DialRenderInput, staticSig: String,
                                       meterSig: String, iconSig: String) -> String {
        [
            input.styleKey, input.name, input.valueText, "\(input.pct)",
            "\(Self.levelPercent(input.level.mono))", staticSig, meterSig, iconSig
        ].joined(separator: "|")
    }

    private static func styleSignature(_ style: KeyStyleImage.KeyStyle) -> String {
        switch style {
        case .channel: return "c"
        case .meter: return "m"
        case .retro: return "r"
        }
    }

    private func glyphSignature(_ glyph: KeyImage.Glyph) -> String {
        switch glyph {
        case .emoji(let s):  return "e:" + s
        case .symbol(let s): return "s:" + s
        }
    }

    private func colorSignature(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.deviceRGB) ?? color
        return String(format: "%.3f,%.3f,%.3f,%.3f",
                      Double(c.redComponent), Double(c.greenComponent),
                      Double(c.blueComponent), Double(c.alphaComponent))
    }

    private func colorSignature(forContext ctx: String, accent: NSColor) -> String {
        if let cached = colorSigCache[ctx] { return cached }
        let sig = colorSignature(accent)
        colorSigCache[ctx] = sig
        return sig
    }
}
