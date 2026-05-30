import Foundation

/// Bridges the Elgato WebSocket and BAM's UDS control socket. Phase 2 proves the
/// bridge end-to-end: connect to BAM on the first `willAppear`, run the hello
/// handshake, and log every inbound frame. No key/dial actions yet.
@MainActor
final class Plugin {
    private let elgato: ElgatoConnection
    private let uds = UDSClient()
    private let router: ActionRouter
    private var udsConnectStarted = false

    init(registration: ElgatoRegistration) {
        let elgato = ElgatoConnection(registration: registration)
        self.elgato = elgato
        self.router = ActionRouter(elgato: elgato)
    }

    func run() {
        router.sendToBAM = { [weak self] frame in self?.uds.send(frame) }
        uds.onFrame = { [weak self] frame in self?.router.ingestBAMFrame(frame) }
        elgato.onEvent = { [weak self] event, obj in self?.handleElgatoEvent(event, obj) }
        elgato.connect()
    }

    private func handleElgatoEvent(_ event: String, _ obj: [String: Any]) {
        Log.info("Elgato event: \(event)")
        // Connect eagerly the first time any action surfaces.
        if event == "willAppear", !udsConnectStarted {
            udsConnectStarted = true
            uds.connect()
        }
        router.handleEvent(event, obj)
    }
}
