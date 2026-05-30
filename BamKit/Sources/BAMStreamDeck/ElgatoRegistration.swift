import Foundation

/// The four launch arguments the Stream Deck app passes to every plugin process.
/// See https://docs.elgato.com/streamdeck/sdk/references/registration-procedure/
struct ElgatoRegistration {
    let port: Int
    let pluginUUID: String
    let registerEvent: String
    let info: String?

    init?(args: [String]) {
        var port: Int?
        var uuid: String?
        var event: String?
        var info: String?

        var i = 0
        while i < args.count {
            switch args[i] {
            case "-port":          i += 1; port = i < args.count ? Int(args[i]) : nil
            case "-pluginUUID":    i += 1; uuid = i < args.count ? args[i] : nil
            case "-registerEvent": i += 1; event = i < args.count ? args[i] : nil
            case "-info":          i += 1; info = i < args.count ? args[i] : nil
            default: break
            }
            i += 1
        }

        guard let port, let uuid, let event else { return nil }
        self.port = port
        self.pluginUUID = uuid
        self.registerEvent = event
        self.info = info
    }
}
