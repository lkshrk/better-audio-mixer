import Foundation

/// Bridges the Elgato WebSocket and BAM's UDS control socket.
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
        uds.onDisconnect = { [weak self] in self?.router.markOffline() }
        elgato.onEvent = { [weak self] event, obj in self?.handleElgatoEvent(event, obj) }
        elgato.connect()
    }

    private func handleElgatoEvent(_ event: String, _ obj: [String: Any]) {
        Log.info("Elgato event: \(event)")
        switch event {
        case "willAppear":
            if !udsConnectStarted {
                udsConnectStarted = true
                uds.connect()
            }
        case "applicationDidLaunch":
            udsConnectStarted = true
            uds.reconnectNow()
        case "applicationDidTerminate":
            router.markOffline()
        case "keyDown", "dialDown", "touchTap":
            uds.launchBAMIfNeeded()
        default:
            break
        }
        router.handleEvent(event, obj)
    }
}
