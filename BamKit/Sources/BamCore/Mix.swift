import Foundation

/// One source routed into one mix, with inline level + mute (Q12). Absence of a
/// `Send` for a source = mix-minus (that source is not in this mix).
public struct Send: Sendable, Equatable, Codable {
    public var source: String       // Source.id
    public var level: Double        // 0…1
    public var muted: Bool

    public init(source: String, level: Double = 1.0, muted: Bool = false) {
        self.source = source
        self.level = level
        self.muted = muted
    }

    private enum CodingKeys: String, CodingKey { case source, level, muted }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.source = try c.decode(String.self, forKey: .source)
        self.level = try c.decodeIfPresent(Double.self, forKey: .level) ?? 1.0
        self.muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
    }
}

/// A mix's destination: a BAM virtual device (by pool slot) or a hardware output
/// (the Monitor mix). Exactly one kind per mix.
public enum MixDestination: Sendable, Equatable, Codable {
    case virtualSlot(Int)
    case hardware(uid: String)

    private enum CodingKeys: String, CodingKey { case virtualSlot, hardwareUID }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let slot = try c.decodeIfPresent(Int.self, forKey: .virtualSlot) {
            self = .virtualSlot(slot)
        } else if let uid = try c.decodeIfPresent(String.self, forKey: .hardwareUID) {
            self = .hardware(uid: uid)
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .virtualSlot, in: c,
                debugDescription: "MixDestination needs virtualSlot or hardwareUID")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .virtualSlot(let s): try c.encode(s, forKey: .virtualSlot)
        case .hardware(let uid): try c.encode(uid, forKey: .hardwareUID)
        }
    }

    /// Device UID the engine opens. Virtual slots follow the driver's UID scheme.
    public var deviceUID: String {
        switch self {
        case .virtualSlot(let s): return "BAM_UID_\(s)"
        case .hardware(let uid): return uid
        }
    }
}

/// A destination mix: its sends (routing), per-mix master fader (Q20), and
/// destination device.
public struct Mix: Sendable, Equatable, Codable, Identifiable {
    public var id: String
    public var name: String
    public var dest: MixDestination
    public var level: Double        // per-mix master, post-sum
    public var sends: [Send]
    public var tone: Double?        // optional Console accent
    public var emoji: String?       // optional icon glyph; replaces the initials chip

    public init(
        id: String,
        name: String,
        dest: MixDestination,
        level: Double = 1.0,
        sends: [Send] = [],
        tone: Double? = nil,
        emoji: String? = nil
    ) {
        self.id = id
        self.name = name
        self.dest = dest
        self.level = level
        self.sends = sends
        self.tone = tone
        self.emoji = emoji
    }

    private enum CodingKeys: String, CodingKey { case id, name, dest, level, sends, tone, emoji }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.dest = try c.decode(MixDestination.self, forKey: .dest)
        self.level = try c.decodeIfPresent(Double.self, forKey: .level) ?? 1.0
        self.sends = try c.decodeIfPresent([Send].self, forKey: .sends) ?? []
        self.tone = try c.decodeIfPresent(Double.self, forKey: .tone)
        self.emoji = try c.decodeIfPresent(String.self, forKey: .emoji)
    }
}
