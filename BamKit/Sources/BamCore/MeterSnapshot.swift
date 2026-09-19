import Foundation

/// dBFS level with per-channel detail; mono callers pass `level` only.
public struct LevelMeter: Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let level: Float
    public let levelLeft: Float
    public let levelRight: Float

    public init(id: String, name: String, level: Float, levelLeft: Float? = nil, levelRight: Float? = nil) {
        self.id = id
        self.name = name
        self.level = level
        self.levelLeft = levelLeft ?? level
        self.levelRight = levelRight ?? level
    }
}

/// Pre-fader level of one source's tap.
public typealias RouterSourceMeter = LevelMeter
/// Post-sum, post-master level of one mix.
public typealias MixMeter = LevelMeter

public struct RouterSnapshot: Sendable, Equatable {
    public let sources: [RouterSourceMeter]
    public let mixes: [MixMeter]

    public init(sources: [RouterSourceMeter], mixes: [MixMeter]) {
        self.sources = sources
        self.mixes = mixes
    }

    public static let silent = RouterSnapshot(sources: [], mixes: [])
}
