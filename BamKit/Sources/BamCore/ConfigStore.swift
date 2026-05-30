import Foundation

/// Resolves and persists the user's editable bam.yaml under Application Support,
/// seeding it from a bundled default the first time the app runs.
public enum ConfigStore {
    public static func defaultURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appendingPathComponent("bam", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("bam.yaml")
    }

    public static func loadOrSeed(seed: String) throws -> (url: URL, config: BamConfig) {
        let url = try defaultURL()
        if !FileManager.default.fileExists(atPath: url.path) {
            try seed.write(to: url, atomically: true, encoding: .utf8)
        }
        return (url, try BamConfig.load(url: url))
    }

    public static func save(_ config: BamConfig, to url: URL) throws {
        try config.validate()
        try config.yaml().write(to: url, atomically: true, encoding: .utf8)
    }
}

public struct AudioApp: Sendable, Identifiable, Equatable {
    public let bundleID: String
    public let displayName: String
    public var id: String { bundleID }

    public init(bundleID: String, displayName: String) {
        self.bundleID = bundleID
        self.displayName = displayName
    }
}

public struct AudioDevice: Sendable, Identifiable, Equatable {
    public let uid: String
    public let name: String
    /// CoreAudio kAudioDevicePropertyTransportType FourCC (0 = unknown).
    public let transportType: UInt32
    public var id: String { uid }

    public init(uid: String, name: String, transportType: UInt32 = 0) {
        self.uid = uid
        self.name = name
        self.transportType = transportType
    }

    /// SF Symbol that best matches the hardware, by name keyword then transport.
    public var outputIcon: String {
        let n = name.lowercased()
        let headsetWords = ["headphone", "headset", "airpod", "buds", "blackshark",
                            "arctis", "hyperx", "kraken", "earbud", "wh-", "wf-"]
        let displayWords = ["odyssey", "monitor", "display", "lg ", "dell ", "u28", "u32", "samsung"]
        if headsetWords.contains(where: n.contains) { return "headphones" }
        if displayWords.contains(where: n.contains) { return "display" }
        switch transportType {
        case 0x626C7565, 0x626C6561: return "headphones"        // 'blue','blea' Bluetooth
        case 0x686D6469, 0x64707274: return "display"           // 'hdmi','dprt' → monitor
        case 0x61697270: return "airplayaudio"                  // 'airp'
        case 0x626C746E: return "speaker.wave.2.fill"           // 'bltn' built-in
        default: return "hifispeaker.fill"
        }
    }
}
