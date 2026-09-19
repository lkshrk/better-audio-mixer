import Foundation
import Testing
@testable import BAMStreamDeck

@MainActor
private final class RecordingElgato: ElgatoCommandSink {
    enum Event {
        case setTitle(String, String)
        case showAlert(String)
        case setImage(String?, String)
        case setGlobalSettings([String: Any])
        case sendToPropertyInspector(String, String, [String: Any])
        case setFeedback([String: Any], String)
        case setFeedbackLayout(String, String)
    }

    private(set) var events: [Event] = []

    func removeAll() { events.removeAll() }
    func setTitle(_ title: String, context: String) { events.append(.setTitle(title, context)) }
    func showAlert(context: String) { events.append(.showAlert(context)) }
    func setImage(_ image: String?, context: String) { events.append(.setImage(image, context)) }
    func setGlobalSettings(_ payload: [String: Any]) { events.append(.setGlobalSettings(payload)) }
    func sendToPropertyInspector(action: String, context: String, payload: [String: Any]) {
        events.append(.sendToPropertyInspector(action, context, payload))
    }
    func setFeedback(_ payload: [String: Any], context: String) { events.append(.setFeedback(payload, context)) }
    func setFeedbackLayout(_ layout: String, context: String) { events.append(.setFeedbackLayout(layout, context)) }

    var feedbackCount: Int {
        events.filter { if case .setFeedback = $0 { return true } else { return false } }.count
    }

    func imageCount(context: String) -> Int {
        events.filter {
            if case .setImage(_, let ctx) = $0 { return ctx == context } else { return false }
        }.count
    }

    var layouts: [String] {
        events.compactMap { if case .setFeedbackLayout(let layout, _) = $0 { return layout } else { return nil } }
    }
}

@MainActor
private final class FakeClock {
    var now: TimeInterval = 0
}

@MainActor
struct ActionRouterMessageTests {
    private let deviceAction = "me.harke.better-audio-mixer.streamdeck.device"
    private let masterAction = "me.harke.better-audio-mixer.streamdeck.master"
    private let outputAction = "me.harke.better-audio-mixer.streamdeck.output"

    private func makeRouter(_ elgato: RecordingElgato = RecordingElgato(),
                            clock: FakeClock = FakeClock()) -> ActionRouter {
        ActionRouter(elgato: elgato, now: { clock.now })
    }

    @Test(arguments: [false, true]) func removedMixMetersCannotSurviveOrReturn(explicitRemoval: Bool) {
        let router = makeRouter()
        router.ingestBAMFrame(stateFrame())
        router.ingestBAMFrame(meterFrame(level: -5))
        #expect(router.levels["m-game"] != nil)
        #expect(router.peakWindows["m-game"] != nil)
        if explicitRemoval {
            router.ingestBAMFrame(["t": "removed", "mix": "m-game"])
        } else {
            router.ingestBAMFrame(["t": "state", "mixes": [[String: Any]]()])
        }
        #expect(router.levels.isEmpty)
        #expect(router.peakWindows.isEmpty)
        router.ingestBAMFrame(meterFrame(level: -1))
        #expect(router.levels.isEmpty)
        #expect(router.peakWindows.isEmpty)
        router.ingestBAMFrame(stateFrame())
        #expect(router.levels.isEmpty)
        #expect(router.peakWindows.isEmpty)
        router.ingestBAMFrame(meterFrame(level: -30))
        #expect(router.levels["m-game"]?.mono == -60 + 30 * 0.82)
        #expect(router.peakWindows["m-game"]?.peak.left == -60 + 30 * 0.82)
    }

    @Test func replacementStatePreservesSurvivingMeterAndPeakHistory() {
        let router = makeRouter()
        router.ingestBAMFrame(stateFrame())
        router.ingestBAMFrame(meterFrame(level: -5))
        let level = router.levels["m-game"]
        let peak = router.peakWindows["m-game"]?.peak
        router.ingestBAMFrame(stateFrame())
        #expect(router.levels["m-game"] == level)
        #expect(router.peakWindows["m-game"]?.peak == peak)
        router.ingestBAMFrame(meterFrame(level: -30))
        #expect(router.peakWindows["m-game"]?.peak == peak)
    }

    @Test func keypadMeterFramesPushLiveSVGsOnlyWhenTheSignatureMoves() {
        let elgato = RecordingElgato()
        let router = makeRouter(elgato)
        bindDevice(router, context: "key", controller: "Keypad", settings: [
            "mix": "m-game",
            "keyStyle": "channel",
        ])
        router.ingestBAMFrame(stateFrame())
        elgato.removeAll()

        router.ingestBAMFrame(meterFrame(level: -12))

        #expect(elgato.events.contains { event in
            if case .setImage(let image, _) = event {
                return image?.hasPrefix("data:image/svg+xml;charset=utf8,") == true
            }
            return false
        })

        for _ in 0..<12 { router.ingestBAMFrame(meterFrame(level: -12)) }
        elgato.removeAll()
        router.ingestBAMFrame(meterFrame(level: -12))

        #expect(elgato.imageCount(context: "key") == 0)
    }

    @Test func dialMeterFeedbackThrottlesToThirtyFramesPerSecond() {
        let elgato = RecordingElgato()
        let clock = FakeClock()
        let router = makeRouter(elgato, clock: clock)
        bindDevice(router, context: "dial", controller: "Encoder", settings: [
            "mix": "m-game",
            "style": "channel",
        ])
        router.ingestBAMFrame(stateFrame())
        elgato.removeAll()

        let script: [(TimeInterval, Double, Int)] = [
            (0.000, -20, 1), (0.010, -10, 1), (0.020, -5, 1),
            (0.034, -15, 2), (0.050, -25, 2), (0.070, -30, 3),
        ]
        for (at, level, expected) in script {
            clock.now = at
            router.ingestBAMFrame(meterFrame(level: level))
            #expect(elgato.feedbackCount == expected, "at \(at)s")
        }
    }

    @Test func dialFeedbackOnlyCarriesDeclaredLayoutKeys() {
        let elgato = RecordingElgato()
        let router = makeRouter(elgato)
        bindDevice(router, context: "dial", controller: "Encoder", settings: [
            "mix": "m-game",
            "style": "channel",
        ])
        router.ingestBAMFrame(stateFrame())
        router.ingestBAMFrame(meterFrame(level: -12))

        let keys = Set(elgato.events.flatMap { event -> [String] in
            if case .setFeedback(let payload, _) = event { return Array(payload.keys) }
            return []
        })
        #expect(keys == ["canvas", "liveMeter"])
    }

    @Test func retroKeyMeterFramesAreThrottledToThirtyPerSecond() {
        let elgato = RecordingElgato()
        let clock = FakeClock()
        let router = makeRouter(elgato, clock: clock)
        bindDevice(router, context: "key", controller: "Keypad", settings: [
            "mix": "m-game",
            "keyStyle": "retro",
        ])
        router.ingestBAMFrame(stateFrame())
        elgato.removeAll()

        // The willAppear/state renders at t=0 count as the last image.
        let script: [(TimeInterval, Double, Int)] = [
            (1.000, -20, 1), (1.010, -10, 1), (1.020, -5, 1),
            (1.034, -15, 2), (1.050, -25, 2), (1.070, -30, 3),
        ]
        for (at, level, expected) in script {
            clock.now = at
            router.ingestBAMFrame(meterFrame(level: level))
            #expect(elgato.imageCount(context: "key") == expected, "at \(at)s")
        }
        #expect(elgato.events.contains { event in
            if case .setImage(let image, _) = event {
                return image?.hasPrefix("data:image/svg+xml;charset=utf8,") == true
            }
            return false
        })
    }

    @Test func willDisappearStopsRenderingAndReappearRepushesLayout() {
        let elgato = RecordingElgato()
        let router = makeRouter(elgato)
        bindDevice(router, context: "dial", controller: "Encoder", settings: [
            "mix": "m-game",
            "style": "retro",
        ])
        router.ingestBAMFrame(stateFrame())
        #expect(elgato.layouts == ["layouts/retro.json"])

        router.handleEvent("willDisappear", ["context": "dial"])
        elgato.removeAll()
        router.ingestBAMFrame(meterFrame(level: -12))
        #expect(elgato.events.isEmpty)

        bindDevice(router, context: "dial", controller: "Encoder", settings: [
            "mix": "m-game",
            "style": "retro",
        ])
        #expect(elgato.layouts == ["layouts/retro.json"])
        #expect(elgato.feedbackCount == 1)
    }

    @Test func didReceiveSettingsRepushesLayoutOnlyWhenStyleChanges() {
        let elgato = RecordingElgato()
        let router = makeRouter(elgato)
        bindDevice(router, context: "dial", controller: "Encoder", settings: [
            "mix": "m-game",
            "style": "channel",
            "step": 0.05,
        ])
        #expect(elgato.layouts == ["layouts/channel.json"])
        elgato.removeAll()

        router.handleEvent("didReceiveSettings", [
            "context": "dial",
            "action": deviceAction,
            "payload": ["controller": "Encoder", "settings": ["mix": "m-game", "style": "channel", "step": 0.1]],
        ])
        #expect(elgato.layouts.isEmpty)

        router.handleEvent("didReceiveSettings", [
            "context": "dial",
            "action": deviceAction,
            "payload": ["controller": "Encoder", "settings": ["mix": "m-game", "style": "meter"]],
        ])
        #expect(elgato.layouts == ["layouts/meter-focus.json"])
    }

    @Test func didReceiveSettingsWithoutControllerKeepsTheEncoder() {
        let elgato = RecordingElgato()
        let router = makeRouter(elgato)
        bindDevice(router, context: "dial", controller: "Encoder", settings: ["mix": "m-game", "style": "channel"])
        elgato.removeAll()

        router.handleEvent("didReceiveSettings", [
            "context": "dial",
            "action": deviceAction,
            "payload": ["settings": ["mix": "m-game", "style": "retro"]],
        ])

        #expect(elgato.layouts == ["layouts/retro.json"])
        #expect(elgato.feedbackCount == 1)
    }

    @Test func propertyInspectorDisappearStopsForwarding() {
        let elgato = RecordingElgato()
        let router = makeRouter(elgato)
        router.handleEvent("propertyInspectorDidAppear", ["action": deviceAction, "context": "pi"])
        elgato.removeAll()
        router.ingestBAMFrame(["t": "mixes", "mixes": [[String: Any]]()])
        #expect(elgato.events.count == 1)

        router.handleEvent("propertyInspectorDidDisappear", ["action": deviceAction, "context": "pi"])
        elgato.removeAll()
        router.ingestBAMFrame(["t": "mixes", "mixes": [[String: Any]]()])
        router.ingestBAMFrame(stateFrame())
        #expect(!elgato.events.contains { if case .sendToPropertyInspector = $0 { return true } else { return false } })
    }

    @Test func settingsDecodeOnceWithKindSpecificModeDefault() {
        #expect(ActionRouter.KeySettings([:], kind: .device).mode == "mute")
        #expect(ActionRouter.KeySettings([:], kind: .master).mode == "mute")
        #expect(ActionRouter.KeySettings([:], kind: .output).mode == "set")
        let s = ActionRouter.KeySettings(["mix": "", "step": 0.1, "keyStyle": "bars", "style": "radial",
                                          "a": "", "showName": true], kind: .device)
        #expect(s.mix == nil)
        #expect(s.step == 0.1)
        #expect(s.keyStyle == .meter)
        #expect(s.dialStyle == .retro)
        #expect(s.outputA == nil)
        #expect(s.showName)
    }

    @Test func encoderSendsKnobImageOnlyWhenGlyphOrMuteChanges() {
        let elgato = RecordingElgato()
        let clock = FakeClock()
        let router = makeRouter(elgato, clock: clock)
        bindDevice(router, context: "dial", controller: "Encoder", settings: ["mix": "m-game", "style": "channel"])
        router.ingestBAMFrame(stateFrame())
        let afterState = elgato.imageCount(context: "dial")
        #expect(afterState >= 1)
        for i in 1...5 {
            clock.now = Double(i) * 0.1
            router.ingestBAMFrame(meterFrame(level: -20 + Double(i)))
        }
        #expect(elgato.imageCount(context: "dial") == afterState)
        router.ingestBAMFrame(["t": "delta", "mix": "m-game", "muted": true])
        #expect(elgato.imageCount(context: "dial") == afterState + 1)
    }

    @Test func markOfflineFloorsLevelsClearsPeaksAndRedrawsKeys() {
        let elgato = RecordingElgato()
        let router = makeRouter(elgato)
        bindDevice(router, context: "key", controller: "Keypad", settings: [
            "mix": "m-game",
            "keyStyle": "channel",
        ])
        router.ingestBAMFrame(stateFrame())
        router.ingestBAMFrame(meterFrame(level: -5))
        #expect(router.peakWindows["m-game"] != nil)
        elgato.removeAll()

        router.markOffline()

        #expect(router.levels["m-game"]?.mono == -60)
        #expect(router.peakWindows.isEmpty)
        #expect(elgato.imageCount(context: "key") == 1)
    }

    @Test func deviceKeyDownEmitsConfiguredCommand() {
        let router = makeRouter()
        var sent: [[String: Any]] = []
        router.sendToBAM = { sent.append($0) }
        bindDevice(router, context: "key", controller: "Keypad", settings: [
            "mix": "m-game",
            "mode": "adjust",
            "step": 0.05,
        ])
        router.ingestBAMFrame(stateFrame())

        router.handleEvent("keyDown", ["context": "key"])

        #expect(sent.last?["t"] as? String == "cmd")
        #expect(sent.last?["op"] as? String == "nudgePos")
        #expect(sent.last?["mix"] as? String == "m-game")
        #expect(sent.last?["delta"] as? Double == 0.05)
    }

    @Test func adjustKeyWithoutCachedPctNudgesInsteadOfWrapping() {
        let router = makeRouter()
        var sent: [[String: Any]] = []
        router.sendToBAM = { sent.append($0) }
        bindDevice(router, context: "key", controller: "Keypad", settings: [
            "mix": "m-game",
            "mode": "adjust",
            "step": -0.05,
        ])

        router.handleEvent("keyDown", ["context": "key"])

        #expect(sent.count == 1)
        #expect(sent.last?["op"] as? String == "nudgePos")
        #expect(sent.last?["delta"] as? Double == -0.05)
        #expect(sent.last?["pos"] == nil)
    }

    @Test func adjustKeyAtRailWraps() {
        let router = makeRouter()
        var sent: [[String: Any]] = []
        router.sendToBAM = { sent.append($0) }
        bindDevice(router, context: "key", controller: "Keypad", settings: [
            "mix": "m-game",
            "mode": "adjust",
            "step": 0.05,
        ])
        router.ingestBAMFrame(stateFrame(pct: 100))

        router.handleEvent("keyDown", ["context": "key"])

        #expect(sent.last?["op"] as? String == "setPos")
        #expect(sent.last?["pos"] as? Double == 0)
    }

    @Test(arguments: [nil, 0, 12, 100] as [Int?], [-0.05, 0.05])
    func masterAdjustAlwaysNudgesRegardlessOfCachedState(cachedPct: Int?, step: Double) {
        let router = makeRouter()
        var sent: [[String: Any]] = []
        router.sendToBAM = { sent.append($0) }
        bind(router, action: masterAction, context: "masterKey", controller: "Keypad", settings: [
            "mode": "adjust",
            "step": step,
        ])
        if let cachedPct {
            router.ingestBAMFrame(["t": "state", "master": ["pct": cachedPct]])
        }

        router.handleEvent("keyDown", ["context": "masterKey"])

        #expect(sent.count == 1)
        #expect(sent.last?["t"] as? String == "cmd")
        #expect(sent.last?["op"] as? String == "nudgeMasterPos")
        #expect(sent.last?["delta"] as? Double == step)
        #expect(sent.last?["pos"] == nil)
    }

    @Test func dialRotateEmitsSignedMasterNudge() {
        let router = makeRouter()
        var sent: [[String: Any]] = []
        router.sendToBAM = { sent.append($0) }
        bind(router, action: masterAction, context: "masterDial", controller: "Encoder", settings: [
            "step": 0.02,
        ])

        router.handleEvent("dialRotate", [
            "context": "masterDial",
            "payload": ["ticks": -3],
        ])

        #expect(sent.last?["t"] as? String == "cmd")
        #expect(sent.last?["op"] as? String == "nudgeMasterPos")
        #expect(sent.last?["delta"] as? Double == -0.06)
    }

    @Test func touchTapTogglesMuteLikeDialPress() {
        let router = makeRouter()
        var sent: [[String: Any]] = []
        router.sendToBAM = { sent.append($0) }
        bindDevice(router, context: "dial", controller: "Encoder", settings: ["mix": "m-game"])

        router.handleEvent("touchTap", ["context": "dial"])

        #expect(sent.last?["op"] as? String == "toggleMuted")
        #expect(sent.last?["mix"] as? String == "m-game")
    }

    @Test func unboundDeviceKeyFallsBackToFirstListedMix() {
        let router = makeRouter()
        var sent: [[String: Any]] = []
        router.sendToBAM = { sent.append($0) }
        bindDevice(router, context: "key", controller: "Keypad", settings: [:])
        router.ingestBAMFrame([
            "t": "state",
            "mixes": [
                ["id": "mix-default", "name": "Default", "emoji": "", "pct": 50, "muted": false],
                ["id": "m-game", "name": "Game", "emoji": "G", "pct": 50, "muted": false],
            ],
        ])

        router.handleEvent("keyDown", ["context": "key"])

        #expect(sent.last?["op"] as? String == "toggleMuted")
        #expect(sent.last?["mix"] as? String == "m-game")
    }

    @Test func propertyInspectorMixListUsesCacheAndRequestsLiveRefresh() {
        let elgato = RecordingElgato()
        let router = makeRouter(elgato)
        var sent: [[String: Any]] = []
        router.sendToBAM = { sent.append($0) }
        router.ingestBAMFrame(stateFrame())
        elgato.removeAll()
        sent.removeAll()

        router.handleEvent("propertyInspectorDidAppear", [
            "action": deviceAction,
            "context": "pi",
        ])

        #expect(sent.last?["t"] as? String == "listMixes")
        guard case .sendToPropertyInspector(let action, let context, let payload) = elgato.events.first else {
            Issue.record("expected cached mixes sent to PI")
            return
        }
        #expect(action == deviceAction)
        #expect(context == "pi")
        #expect(payload["t"] as? String == "mixes")
        let mixes = payload["mixes"] as? [[String: Any]]
        #expect(mixes?.first?["id"] as? String == "m-game")
    }

    @Test func outputKeysCoalesceListOutputsUntilAnswered() {
        let router = makeRouter()
        var sent: [[String: Any]] = []
        router.sendToBAM = { sent.append($0) }
        bind(router, action: outputAction, context: "out1", controller: "Keypad", settings: ["a": "A"])
        bind(router, action: outputAction, context: "out2", controller: "Keypad", settings: ["a": "B"])
        #expect(sent.filter { $0["t"] as? String == "listOutputs" }.count == 1)

        router.ingestBAMFrame(["t": "outputs", "outputs": [["uid": "A", "name": "Speakers", "active": true]]])
        bind(router, action: outputAction, context: "out3", controller: "Keypad", settings: ["a": "A"])
        #expect(sent.filter { $0["t"] as? String == "listOutputs" }.count == 2)
    }

    @Test func outputToggleChoosesInactivePresentTarget() {
        let router = makeRouter()
        var sent: [[String: Any]] = []
        router.sendToBAM = { sent.append($0) }
        bind(router, action: outputAction, context: "out", controller: "Keypad", settings: [
            "mode": "toggle",
            "a": "A",
            "b": "B",
        ])
        router.ingestBAMFrame([
            "t": "outputs",
            "outputs": [
                ["uid": "A", "name": "Speakers", "active": true, "icon": "hifispeaker.fill"],
                ["uid": "B", "name": "Headphones", "active": false, "icon": "headphones"],
            ],
        ])
        sent.removeAll()

        router.handleEvent("keyDown", ["context": "out"])

        #expect(sent.last?["t"] as? String == "setOutputDevice")
        #expect(sent.last?["uid"] as? String == "B")
    }

    @Test func outputKeyOnlyRedrawsWhenGlyphChanges() {
        let elgato = RecordingElgato()
        let router = makeRouter(elgato)
        bind(router, action: outputAction, context: "out", controller: "Keypad", settings: ["a": "A"])
        let outputs: [String: Any] = [
            "t": "outputs",
            "outputs": [["uid": "A", "name": "Speakers", "active": true, "icon": "hifispeaker.fill"]],
        ]
        router.ingestBAMFrame(outputs)
        elgato.removeAll()

        router.ingestBAMFrame(outputs)

        #expect(elgato.imageCount(context: "out") == 0)
    }

    private func bindDevice(_ router: ActionRouter, context: String, controller: String, settings: [String: Any]) {
        bind(router, action: deviceAction, context: context, controller: controller, settings: settings)
    }

    private func bind(_ router: ActionRouter, action: String, context: String, controller: String, settings: [String: Any]) {
        router.handleEvent("willAppear", [
            "context": context,
            "action": action,
            "payload": [
                "controller": controller,
                "settings": settings,
            ],
        ])
    }

    private func stateFrame(pct: Int = 50) -> [String: Any] {
        [
            "t": "state",
            "mixes": [[
                "id": "m-game",
                "name": "Game",
                "emoji": "G",
                "pct": pct,
                "muted": false,
            ]],
            "master": [
                "pct": 75,
                "muted": false,
                "icon": "hifispeaker.fill",
            ],
        ]
    }

    private func meterFrame(level: Double) -> [String: Any] {
        [
            "t": "meter",
            "mixes": [[
                "id": "m-game",
                "level": level,
                "levelLeft": level,
                "levelRight": level,
            ]],
            "master": [
                "level": level,
                "levelLeft": level,
                "levelRight": level,
            ],
        ]
    }
}
