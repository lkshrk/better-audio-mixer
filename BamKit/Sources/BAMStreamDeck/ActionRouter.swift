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

    private let elgato: ElgatoConnection
    /// Sink for frames headed to BAM (cmd / listMixes).
    var sendToBAM: (([String: Any]) -> Void)?

    private var contexts: [String: Binding] = [:]
    private var mixes: [String: MixInfo] = [:]
    private var levels: [String: Float] = [:]
    private var masterPct = 0
    private var masterMuted = false
    private var masterLevel: Float = meterFloorDB
    private var masterIcon = "hifispeaker.fill"
    /// Last icon signature pushed to each dial's LCD, so the (expensive) base64
    /// pixmap is only re-sent when the glyph or mute state actually changes —
    /// meter/value updates stay tiny and can run at full frame rate.
    private var dialIconSig: [String: String] = [:]
    /// Last wall-clock time the (full-PNG) styled keys were refreshed from a meter
    /// frame. Encoders run unthrottled, but each styled key ships a fresh ~5KB base64
    /// image per refresh, so keys are capped to ~10fps.
    private var lastKeyMeter: TimeInterval = 0
    private var piAction: String?
    private var piContext: String?

    private struct OutputInfo { var uid: String; var name: String; var icon: String }
    /// Ordered hardware outputs from the last `outputs` frame (PI list + toggle targets).
    private var outputs: [OutputInfo] = []
    private var activeOutputUID: String?
    /// Context whose press issued the pending setOutputDevice — receives the v2 alert.
    private var pendingOutputContext: String?

    init(elgato: ElgatoConnection) { self.elgato = elgato }

    // MARK: - Elgato events

    func handleEvent(_ event: String, _ obj: [String: Any]) {
        switch event {
        case "willAppear":          bind(obj)
        case "didReceiveSettings":  bind(obj)
        case "willDisappear":       if let ctx = obj["context"] as? String { contexts[ctx] = nil; dialIconSig[ctx] = nil }
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
        if controller == "Encoder" {
            let style = (settings["style"] as? String) ?? "combined"
            elgato.setFeedbackLayout(layoutID(style), context: ctx)
            dialIconSig[ctx] = nil // layout reset clears the LCD; force icon re-push
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
        case "slider": return "layouts/slider.json"
        case "meter":  return "layouts/meter.json"
        default:       return "layouts/band.json"
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

    static func accent(forID id: String) -> NSColor {
        var h: UInt64 = 1469598103934665603 // FNV-1a
        for byte in id.utf8 { h = (h ^ UInt64(byte)) &* 1099511628211 }
        return accentPalette[Int(h % UInt64(accentPalette.count))]
    }

    private func keyStyle(_ b: Binding) -> KeyStyleImage.KeyStyle {
        KeyStyleImage.KeyStyle(rawValue: (b.settings["keyStyle"] as? String) ?? "meter") ?? .meter
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
    /// the switch. v2: the server replies `error{unsupported}` and we flash an alert.
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
        case "removed": if let id = obj["mix"] as? String { mixes[id] = nil; levels[id] = nil; refreshAll(); cacheMixes() }
        case "meter":   ingestMeter(obj)
        case "mixes":   forwardMixesReply(obj)
        case "outputs": ingestOutputs(obj)
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

    /// v2: setOutputDevice is unsupported; flash an alert on the key that pressed it.
    private func ingestError(_ obj: [String: Any]) {
        guard (obj["op"] as? String) == "setOutputDevice" else { return }
        if let ctx = pendingOutputContext { elgato.showAlert(context: ctx) }
        pendingOutputContext = nil
    }

    /// Level-only frame (~12fps). Drives the LCD meter bars on dials at the full
    /// source rate — the base64 icon is cached in `dialIconSig`, so each meter
    /// frame only ships tiny value/bar numbers. Keys ignore meters.
    private func ingestMeter(_ obj: [String: Any]) {
        for m in obj["mixes"] as? [[String: Any]] ?? [] {
            if let id = m["id"] as? String, let lvl = m["level"] as? Double {
                levels[id] = smoothLevel(levels[id] ?? Self.meterFloorDB, Float(lvl))
            }
        }
        if let master = obj["master"] as? [String: Any], let lvl = master["level"] as? Double {
            masterLevel = smoothLevel(masterLevel, Float(lvl))
        }
        for (ctx, b) in contexts where b.kind.isDial || b.isEncoder { refresh(ctx) }
        // Styled keys carry a live level too, but each refresh ships a full PNG —
        // cap them to ~10fps.
        let now = Date().timeIntervalSinceReferenceDate
        if now - lastKeyMeter >= 0.1 {
            lastKeyMeter = now
            for (ctx, b) in contexts where (b.kind == .device || b.kind == .master) && !b.isEncoder {
                refresh(ctx)
            }
        }
    }

    /// Ballistics for the LCD level meter: instant attack on a rising level,
    /// eased decay on the way down. Without this the gbar flickers frame-to-frame
    /// and reads as noise rather than a meter.
    private func smoothLevel(_ old: Float, _ new: Float) -> Float {
        new >= old ? new : old + (new - old) * 0.35
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

    private func refresh(_ ctx: String) {
        guard let b = contexts[ctx] else { return }
        switch b.kind {
        case .device:
            // One action on key OR dial, three modes (mute / adjust / set).
            // On a dial: LCD band feedback. On a key: centered emoji glyph, no
            // background, speaker-symbol fallback, red slash in mute mode while
            // muted; label is user-chosen (none / name / custom / volume).
            let info = (b.settings["mix"] as? String).flatMap { mixes[$0] }
            if b.isEncoder {
                let level = (b.settings["mix"] as? String).flatMap { levels[$0] } ?? Self.meterFloorDB
                pushDialFeedback(ctx, b, glyph: deviceGlyph(info), name: info?.name ?? "",
                                 pct: info?.pct ?? 0, muted: info?.muted ?? false, level: level)
                return
            }
            guard let info, let mixID = b.settings["mix"] as? String else {
                elgato.setImage(nil, context: ctx); elgato.setTitle("", context: ctx); return
            }
            if ((b.settings["mode"] as? String) ?? "mute") == "mute" {
                elgato.setState(info.muted ? 1 : 0, context: ctx)
            }
            let img = KeyStyleImage.render(
                style: keyStyle(b), monogram: initials(info.name), accent: Self.accent(forID: mixID),
                name: info.name, pct: info.pct, level: Self.levelFraction(levels[mixID] ?? Self.meterFloorDB),
                muted: info.muted)
            elgato.setImage(img, context: ctx)
            elgato.setTitle("", context: ctx) // name/% are baked into the image
        case .master:
            // Same key/dial split as .device, but always the app's output-device
            // icon (no emoji) and no device picker.
            if b.isEncoder {
                pushDialFeedback(ctx, b, glyph: .symbol(masterIcon), name: "Master",
                                 pct: masterPct, muted: masterMuted, level: masterLevel)
                return
            }
            if ((b.settings["mode"] as? String) ?? "mute") == "mute" {
                elgato.setState(masterMuted ? 1 : 0, context: ctx)
            }
            let img = KeyStyleImage.render(
                style: keyStyle(b), monogram: "M", accent: Self.masterAccent,
                name: "Master", pct: masterPct, level: Self.levelFraction(masterLevel), muted: masterMuted)
            elgato.setImage(img, context: ctx)
            elgato.setTitle("", context: ctx)
        case .deviceDial:
            let info = (b.settings["mix"] as? String).flatMap { mixes[$0] }
            let level = (b.settings["mix"] as? String).flatMap { levels[$0] } ?? Self.meterFloorDB
            pushDialFeedback(ctx, b, glyph: deviceGlyph(info), name: info?.name ?? "",
                             pct: info?.pct ?? 0, muted: info?.muted ?? false, level: level)
        case .masterDial:
            pushDialFeedback(ctx, b, glyph: .symbol(masterIcon), name: "Master",
                             pct: masterPct, muted: masterMuted, level: masterLevel)
        case .output:
            refreshOutput(ctx, b)
        case .unknown:
            break
        }
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
        elgato.setTitle(showName ? name : "", context: ctx)
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

    /// Pushes one LCD frame. Every layout (band / slider / meter) carries the same
    /// keys — title, value, slider, meter, icon — and renders whichever it defines,
    /// so we always send the full set. The icon pixmap (device emoji / master icon,
    /// red slash while muted) is base64 and costs ~5KB, so it's only re-sent when
    /// its signature changes; numeric bars ship every frame.
    private func pushDialFeedback(_ ctx: String, _ b: Binding, glyph: KeyImage.Glyph,
                                  name: String, pct: Int, muted: Bool, level: Float) {
        let meterVal = muted ? 0 : Self.levelPercent(level)
        var p: [String: Any] = [
            "title": name,
            "value": muted ? "MUTED" : "\(pct)%",
            "slider": pct,
            "meter": meterVal,
        ]
        let sig = glyphSignature(glyph) + (muted ? "|m" : "")
        if dialIconSig[ctx] != sig {
            dialIconSig[ctx] = sig
            let img = KeyImage.render(glyph, muted: muted, tint: true)
            p["icon"] = img ?? ""        // LCD pixmap
            elgato.setImage(img, context: ctx) // dial's canvas/preview square
        }
        elgato.setFeedback(p, context: ctx)
    }

    private func glyphSignature(_ glyph: KeyImage.Glyph) -> String {
        switch glyph {
        case .emoji(let s):  return "e:" + s
        case .symbol(let s): return "s:" + s
        }
    }
}
