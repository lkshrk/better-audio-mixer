import Foundation

/// Raw level of one source (mix-independent, pre-fader): what the source's tap is
/// producing right now.
public struct RouterSourceMeter: Sendable, Identifiable, Equatable {
    public let id: String          // Source.id
    public let name: String
    public let level: Float        // dBFS
    public let levelLeft: Float    // dBFS
    public let levelRight: Float   // dBFS

    public init(id: String, name: String, level: Float, levelLeft: Float? = nil, levelRight: Float? = nil) {
        self.id = id
        self.name = name
        self.level = level
        self.levelLeft = levelLeft ?? level
        self.levelRight = levelRight ?? level
    }
}

/// Post-sum, post-master output level of one mix's destination.
public struct MixMeter: Sendable, Identifiable, Equatable {
    public let id: String          // Mix.id
    public let name: String
    public let level: Float        // dBFS
    public let levelLeft: Float    // dBFS
    public let levelRight: Float   // dBFS

    public init(id: String, name: String, level: Float, levelLeft: Float? = nil, levelRight: Float? = nil) {
        self.id = id
        self.name = name
        self.level = level
        self.levelLeft = levelLeft ?? level
        self.levelRight = levelRight ?? level
    }
}

public struct RouterSnapshot: Sendable, Equatable {
    public let sources: [RouterSourceMeter]
    public let mixes: [MixMeter]

    public init(sources: [RouterSourceMeter], mixes: [MixMeter]) {
        self.sources = sources
        self.mixes = mixes
    }

    public static let silent = RouterSnapshot(sources: [], mixes: [])
}
