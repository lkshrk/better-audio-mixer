import Foundation

public struct Group: Sendable, Equatable, Codable {
    public var name: String
    /// Not enforced in v1 (no routing yet).
    public var volume: Double
    public var muted: Bool
    public var bundleIDs: [String]
    /// Singleton "All Audio" bucket: captures every process not in any group.
    public var includesUnassigned: Bool

    public init(
        name: String,
        volume: Double = 1.0,
        muted: Bool = false,
        bundleIDs: [String] = [],
        includesUnassigned: Bool = false
    ) {
        self.name = name
        self.volume = volume
        self.muted = muted
        self.bundleIDs = bundleIDs
        self.includesUnassigned = includesUnassigned
    }

    private enum CodingKeys: String, CodingKey {
        case name, volume, muted, bundleIDs, includesUnassigned
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decode(String.self, forKey: .name)
        self.volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 1.0
        self.muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        self.bundleIDs = try c.decodeIfPresent([String].self, forKey: .bundleIDs) ?? []
        self.includesUnassigned = try c.decodeIfPresent(Bool.self, forKey: .includesUnassigned) ?? false
    }
}
