import Foundation

/// A routable input: a group of ≥1 app (by bundle id), or the singleton
/// "Everything Else" remainder. Identity is canonical at top level; mixes
/// reference a source by stable `id` (rename-safe).
public struct Source: Sendable, Equatable, Codable, Identifiable {
    public enum Kind: String, Sendable, Codable {
        case app        // one or more app bundle ids
        case rest       // singleton remainder ("Everything Else"), non-deletable
    }

    public var id: String
    public var name: String
    public var kind: Kind
    public var bundleIDs: [String]
    /// Optional display affordances (Console).
    public var monogram: String?
    public var hue: Double?

    public init(
        id: String,
        name: String,
        kind: Kind = .app,
        bundleIDs: [String] = [],
        monogram: String? = nil,
        hue: Double? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.bundleIDs = bundleIDs
        self.monogram = monogram
        self.hue = hue
    }

    private enum CodingKeys: String, CodingKey { case id, name, kind, bundleIDs, monogram, hue }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .app
        self.bundleIDs = try c.decodeIfPresent([String].self, forKey: .bundleIDs) ?? []
        self.monogram = try c.decodeIfPresent(String.self, forKey: .monogram)
        self.hue = try c.decodeIfPresent(Double.self, forKey: .hue)
    }

    public var isRemainder: Bool { kind == .rest }
}
