import Testing
@testable import BAMStreamDeck

@MainActor
private final class RecordingElgato: ElgatoCommandSink {
    enum Event {
        case setTitle(String, String)
        case setState(Int, String)
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
    func setState(_ state: Int, context: String) { events.append(.setState(state, context)) }
    func showAlert(context: String) { events.append(.showAlert(context)) }
    func setImage(_ image: String?, context: String) { events.append(.setImage(image, context)) }
    func setGlobalSettings(_ payload: [String: Any]) { events.append(.setGlobalSettings(payload)) }
    func sendToPropertyInspector(action: String, context: String, payload: [String: Any]) {
        events.append(.sendToPropertyInspector(action, context, payload))
    }
    func setFeedback(_ payload: [String: Any], context: String) { events.append(.setFeedback(payload, context)) }
    func setFeedbackLayout(_ layout: String, context: String) { events.append(.setFeedbackLayout(layout, context)) }
}

@MainActor
struct ActionRouterMessageTests {
    private let deviceAction = "me.harke.better-audio-mixer.streamdeck.device"
    private let masterAction = "me.harke.better-audio-mixer.streamdeck.master"
    private let outputAction = "me.harke.better-audio-mixer.streamdeck.output"

    @Test func keypadMeterFramesDoNotPushLivePNGs() {
        let elgato = RecordingElgato()
        let router = ActionRouter(elgato: elgato)
        bindDevice(router, context: "key", controller: "Keypad", settings: [
            "mix": "m-game",
            "keyStyle": "meter",
        ])
        router.ingestBAMFrame(stateFrame())
        elgato.removeAll()

        router.ingestBAMFrame(meterFrame(level: -12))

        #expect(!elgato.events.contains { event in
            if case .setImage = event { return true }
            return false
        })
    }

    @Test func dialMeterFeedbackAllowsAroundThirtyFramesPerSecondAndDropsBursts() async throws {
        let elgato = RecordingElgato()
        let router = ActionRouter(elgato: elgato)
        bindDevice(router, context: "dial", controller: "Encoder", settings: [
            "mix": "m-game",
            "style": "channel",
        ])
        router.ingestBAMFrame(stateFrame())
        elgato.removeAll()

        router.ingestBAMFrame(meterFrame(level: -20))
        router.ingestBAMFrame(meterFrame(level: -10))

        var feedbackCount = elgato.events.filter { event in
            if case .setFeedback = event { return true }
            return false
        }.count
        #expect(feedbackCount == 1)

        try await Task.sleep(for: .milliseconds(45))
        router.ingestBAMFrame(meterFrame(level: -5))
        feedbackCount = elgato.events.filter { event in
            if case .setFeedback = event { return true }
            return false
        }.count
        #expect(feedbackCount == 2)

        try await Task.sleep(for: .milliseconds(33))
        router.ingestBAMFrame(meterFrame(level: -15))
        try await Task.sleep(for: .milliseconds(33))
        router.ingestBAMFrame(meterFrame(level: -25))
        feedbackCount = elgato.events.filter { event in
            if case .setFeedback = event { return true }
            return false
        }.count
        #expect(feedbackCount == 4)
    }

    @Test func deviceKeyDownEmitsConfiguredCommand() {
        let elgato = RecordingElgato()
        let router = ActionRouter(elgato: elgato)
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

    @Test func dialRotateEmitsSignedMasterNudge() {
        let elgato = RecordingElgato()
        let router = ActionRouter(elgato: elgato)
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

    @Test func propertyInspectorMixListUsesCacheAndRequestsLiveRefresh() {
        let elgato = RecordingElgato()
        let router = ActionRouter(elgato: elgato)
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

    @Test func outputToggleChoosesInactivePresentTarget() {
        let elgato = RecordingElgato()
        let router = ActionRouter(elgato: elgato)
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

    private func stateFrame() -> [String: Any] {
        [
            "t": "state",
            "mixes": [[
                "id": "m-game",
                "name": "Game",
                "emoji": "G",
                "pct": 50,
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
