import AppKit
import Testing
@testable import BamCore

struct OutputDeviceKindTests {
    private func kind(_ name: String, transport: String = "", source: String = "") -> OutputDeviceKind {
        OutputDeviceKind.classify(name: name,
                                  transportType: transport.isEmpty ? 0 : OutputDeviceKind.fourCC(transport),
                                  dataSource: source.isEmpty ? 0 : OutputDeviceKind.fourCC(source))
    }

    @Test func dataSourceWinsOverName() {
        #expect(kind("Mac mini Speakers", transport: "bltn", source: "hdpn") == .headphones)
        #expect(kind("External Headphones", transport: "bltn", source: "espk") == .desktopSpeakers)
        #expect(kind("Sony TV", transport: "hdmi", source: "hdmi") == .television)
        #expect(kind("LG Ultrafine", transport: "hdmi", source: "dprt") == .displaySpeakers)
    }

    @Test func nameKeywordsClassifyUSBAndUnknownTransports() {
        #expect(kind("Razer BlackShark V2 Pro 2.4", transport: "usb ") == .headphones)
        #expect(kind("WH-1000XM5", transport: "blue") == .headphones)
        #expect(kind("AirPods Pro", transport: "blea") == .earbuds)
        #expect(kind("Odyssey G60SD", transport: "dprt") == .displaySpeakers)
        #expect(kind("Edifier R1280DB", transport: "usb ") == .desktopSpeakers)
        #expect(kind("Scarlett 2i2 USB", transport: "usb ") == .desktopSpeakers)
        #expect(kind("SoundDesk Virtual Cable", transport: "virt") == .virtual)
        #expect(kind("bam-router", transport: "grup") == .virtual)
        #expect(kind("Living Room", transport: "airp") == .airPlay)
        #expect(kind("Mystery Device", transport: "usb ") == .unknown)
    }

    @Test func builtInFollowsHostModel() {
        let builtIn = kind("Mac mini Speakers", transport: "bltn")
        #expect([.builtInLaptop, .displaySpeakers, .desktopSpeakers].contains(builtIn))
    }

    @Test func everySymbolResolves() {
        let kinds: [OutputDeviceKind] = [.earbuds, .headphones, .displaySpeakers, .television, .desktopSpeakers,
                                         .builtInLaptop, .airPlay, .virtual, .unknown]
        for k in kinds {
            #expect(NSImage(systemSymbolName: k.symbolName, accessibilityDescription: nil) != nil, "\(k.symbolName)")
        }
    }

    @Test func audioDeviceExposesIcon() {
        let device = AudioDevice(uid: "u", name: "HyperX Cloud II", transportType: OutputDeviceKind.fourCC("usb "))
        #expect(device.outputIcon == "headphones")
    }
}
