import Foundation

@MainActor
protocol ElgatoCommandSink: AnyObject {
    func setTitle(_ title: String, context: String)
    func setState(_ state: Int, context: String)
    func showAlert(context: String)
    func setImage(_ image: String?, context: String)
    func setGlobalSettings(_ payload: [String: Any])
    func sendToPropertyInspector(action: String, context: String, payload: [String: Any])
    func setFeedback(_ payload: [String: Any], context: String)
    func setFeedbackLayout(_ layout: String, context: String)
}

/// Speaks the Elgato Stream Deck WebSocket protocol: connects to the local
/// `ws://127.0.0.1:<port>`, registers the plugin, and forwards inbound events
/// (`willAppear`, `keyDown`, …) to `onEvent`. Hand-rolled over
/// `URLSessionWebSocketTask` — there is no official Swift SDK.
@MainActor
final class ElgatoConnection: ElgatoCommandSink {
    private let registration: ElgatoRegistration
    private let session = URLSession(configuration: .default)
    private var task: URLSessionWebSocketTask?

    /// (event name, full decoded envelope). Called on the main actor.
    var onEvent: ((String, [String: Any]) -> Void)?

    var pluginUUID: String { registration.pluginUUID }

    init(registration: ElgatoRegistration) {
        self.registration = registration
    }

    func connect() {
        guard let url = URL(string: "ws://127.0.0.1:\(registration.port)") else {
            Log.error("bad WS url for port \(registration.port)")
            return
        }
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        register()
        receive()
        Log.info("Elgato WS connecting on port \(registration.port)")
    }

    /// Send an arbitrary JSON envelope to the Stream Deck app.
    func send(_ obj: [String: Any]) {
        guard let task,
              let data = try? JSONSerialization.data(withJSONObject: obj),
              let str = String(data: data, encoding: .utf8) else { return }
        task.send(.string(str)) { error in
            if let error { Log.error("WS send: \(error.localizedDescription)") }
        }
    }

    private func register() {
        send(["event": registration.registerEvent, "uuid": registration.pluginUUID])
    }

    // MARK: - Stream Deck command helpers

    func setTitle(_ title: String, context: String) {
        send(["event": "setTitle", "context": context,
              "payload": ["title": title, "target": 0]])
    }

    func setState(_ state: Int, context: String) {
        send(["event": "setState", "context": context, "payload": ["state": state]])
    }

    func showAlert(context: String) {
        send(["event": "showAlert", "context": context])
    }

    /// `image` is a full data URI ("data:image/png;base64,…") or nil to clear back
    /// to the manifest icon.
    func setImage(_ image: String?, context: String) {
        send(["event": "setImage", "context": context,
              "payload": ["image": image as Any, "target": 0]])
    }

    func setGlobalSettings(_ payload: [String: Any]) {
        send(["event": "setGlobalSettings", "context": pluginUUID, "payload": payload])
    }

    func sendToPropertyInspector(action: String, context: String, payload: [String: Any]) {
        send(["event": "sendToPropertyInspector", "action": action,
              "context": context, "payload": payload])
    }

    func setFeedback(_ payload: [String: Any], context: String) {
        send(["event": "setFeedback", "context": context, "payload": payload])
    }

    func setFeedbackLayout(_ layout: String, context: String) {
        send(["event": "setFeedbackLayout", "context": context, "payload": ["layout": layout]])
    }

    /// One-shot receive that re-arms itself. The completion runs off-actor, so we
    /// extract the (Sendable) String there and hop back to the main actor to decode.
    private func receive() {
        task?.receive { [weak self] result in
            let text: String?
            switch result {
            case .success(.string(let s)): text = s
            case .success(.data(let d)):   text = String(data: d, encoding: .utf8)
            case .success:                 text = nil
            case .failure(let error):
                Log.error("WS receive: \(error.localizedDescription)")
                return
            }
            Task { @MainActor in
                guard let self else { return }
                if let text { self.handleText(text) }
                self.receive()
            }
        }
    }

    private func handleText(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = obj["event"] as? String else { return }
        onEvent?(event, obj)
    }
}
