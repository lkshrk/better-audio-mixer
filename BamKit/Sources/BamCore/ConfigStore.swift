import Foundation

/// Resolves and persists the user's editable bam.yaml under Application Support,
/// seeding it from a bundled default the first time the app runs.
public enum ConfigStore {
    public static func defaultURL() throws -> URL {
        try BamPaths.configDirectory().appendingPathComponent("bam.yaml")
    }

    public static func loadOrSeed(seed: String) throws -> (url: URL, config: BamConfig) {
        try loadOrSeed(seed: seed, url: defaultURL())
    }

    /// Seeds `url` only when no file exists there; an existing but corrupt file is left untouched and the error propagates.
    public static func loadOrSeed(seed: String, url: URL) throws -> (url: URL, config: BamConfig) {
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
    /// CoreAudio kAudioDevicePropertyDataSource FourCC for the output scope (0 = none).
    public let dataSource: UInt32
    public var id: String { uid }

    public init(uid: String, name: String, transportType: UInt32 = 0, dataSource: UInt32 = 0) {
        self.uid = uid
        self.name = name
        self.transportType = transportType
        self.dataSource = dataSource
    }

    public var kind: OutputDeviceKind {
        OutputDeviceKind.classify(name: name, transportType: transportType, dataSource: dataSource)
    }

    public var outputIcon: String { kind.symbolName }
}

public enum OutputDeviceKind: Sendable, Equatable {
    case earbuds
    case headphones
    case displaySpeakers
    case television
    case desktopSpeakers
    case builtInLaptop
    case airPlay
    case virtual
    case unknown

    public var symbolName: String {
        switch self {
        case .earbuds: return "earbuds"
        case .headphones: return "headphones"
        case .displaySpeakers: return "display"
        case .television: return "tv"
        case .desktopSpeakers: return "hifispeaker.2.fill"
        case .builtInLaptop: return "laptopcomputer"
        case .airPlay: return "airplayaudio"
        case .virtual: return "waveform"
        case .unknown: return "hifispeaker.fill"
        }
    }

    static func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }

    private static let earbudWords = ["airpod", "earbud", "buds", "wf-", "powerbeats", "beats fit", "beats studio buds"]
    private static let headphoneWords = [
        "headphone", "headset", "blackshark", "arctis", "hyperx", "kraken", "barracuda", "wh-", "wh1000",
        "xm4", "xm5", "quietcomfort", "qc35", "qc45", "momentum", "airpods max", "beats", "jabra", "astro",
        "logitech g", "g pro x", "g733", "g935", "corsair", "void", "virtuoso", "cloud", "nova", "sennheiser",
        "bose 700", "px7", "px8", "wireless headset",
    ]
    private static let televisionWords = ["tv", "television", "bravia", "oled", "qled", "apple tv", "homepod"]
    private static let displayWords = [
        "odyssey", "monitor", "display", "lg ", "dell ", "u28", "u32", "samsung", "benq", "asus", "acer", "aoc",
        "viewsonic", "philips", "msi", "gigabyte", "cinema", "hdmi", "displayport", "dp-", "thunderbolt",
    ]
    private static let speakerWords = [
        "speaker", "soundbar", "sonos", "edifier", "kef", "creative", "audioengine", "presonus", "yamaha",
        "krk", "adam ", "genelec", "jbl", "klipsch", "bose companion", "scarlett", "focusrite", "motu", "rme",
        "apogee", "dac", "amp", "receiver", "denon", "marantz", "onkyo", "pioneer",
    ]
    private static let virtualWords = ["virtual", "cable", "loopback", "blackhole", "soundflower", "aggregate", "multi-output", "bam-router"]

    public static func classify(name: String, transportType: UInt32, dataSource: UInt32) -> OutputDeviceKind {
        let n = " " + name.lowercased() + " "
        func has(_ words: [String]) -> Bool { words.contains { n.contains($0) } }
        switch dataSource {
        case fourCC("hdpn"): return has(earbudWords) ? .earbuds : .headphones
        case fourCC("ispk"): return builtInKind()
        case fourCC("espk"), fourCC("line"), fourCC("spdf"): return .desktopSpeakers
        case fourCC("hdmi"), fourCC("dprt"): return has(televisionWords) ? .television : .displaySpeakers
        default: break
        }
        if has(virtualWords) || transportType == fourCC("virt") { return .virtual }
        if has(earbudWords) { return .earbuds }
        if has(headphoneWords) { return .headphones }
        if has(televisionWords) { return .television }
        if has(displayWords) { return .displaySpeakers }
        if transportType == fourCC("bltn") { return builtInKind() }
        if has(speakerWords) { return .desktopSpeakers }
        switch transportType {
        case fourCC("blue"), fourCC("blea"): return .headphones
        case fourCC("hdmi"), fourCC("dprt"): return .displaySpeakers
        case fourCC("airp"): return .airPlay
        default: return .unknown
        }
    }

    private static func builtInKind() -> OutputDeviceKind {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buffer = [UInt8](repeating: 0, count: max(1, size))
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        let model = String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self).lowercased()
        if model.contains("book") { return .builtInLaptop }
        return model.contains("imac") ? .displaySpeakers : .desktopSpeakers
    }
}
