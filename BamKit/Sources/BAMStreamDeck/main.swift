import Foundation

guard let registration = ElgatoRegistration(args: CommandLine.arguments) else {
    FileHandle.standardError.write(Data("BAMStreamDeck: missing Elgato registration arguments\n".utf8))
    exit(1)
}

let plugin = Plugin(registration: registration)
plugin.run()
RunLoop.main.run()
