import Foundation

public struct SourceMeter: Sendable, Identifiable, Equatable {
    public let id: String
    public let bundleID: String
    public let displayName: String
    public let deviceUID: String
    public let deviceName: String
    public let level: Float        // dBFS

    public init(
        bundleID: String,
        displayName: String,
        deviceUID: String,
        deviceName: String,
        level: Float
    ) {
        self.id = "\(bundleID)@\(deviceUID)"
        self.bundleID = bundleID
        self.displayName = displayName
        self.deviceUID = deviceUID
        self.deviceName = deviceName
        self.level = level
    }
}

public struct GroupMeter: Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let volume: Double
    public let muted: Bool
    public let level: Float        // dBFS
    public let sources: [SourceMeter]
    public let isUnassignedBucket: Bool

    public init(
        name: String,
        volume: Double,
        muted: Bool,
        level: Float,
        sources: [SourceMeter],
        isUnassignedBucket: Bool
    ) {
        self.id = name
        self.name = name
        self.volume = volume
        self.muted = muted
        self.level = level
        self.sources = sources
        self.isUnassignedBucket = isUnassignedBucket
    }
}

public struct MeterSnapshot: Sendable, Equatable {
    public let master: Float        // dBFS, total system audio
    public let groups: [GroupMeter]
    /// Remainder shown standalone when no group claims "All Audio".
    public let unassigned: GroupMeter?

    public init(master: Float, groups: [GroupMeter], unassigned: GroupMeter?) {
        self.master = master
        self.groups = groups
        self.unassigned = unassigned
    }

    public static let silent = MeterSnapshot(
        master: RMSMeter.floorDB, groups: [], unassigned: nil
    )
}

// MARK: - v3 router meters

/// Raw level of one source (mix-independent, pre-fader): what the source's tap is
/// producing right now.
public struct RouterSourceMeter: Sendable, Identifiable, Equatable {
    public let id: String          // Source.id
    public let name: String
    public let level: Float        // dBFS

    public init(id: String, name: String, level: Float) {
        self.id = id
        self.name = name
        self.level = level
    }
}

/// Post-sum, post-master output level of one mix's destination.
public struct MixMeter: Sendable, Identifiable, Equatable {
    public let id: String          // Mix.id
    public let name: String
    public let level: Float        // dBFS

    public init(id: String, name: String, level: Float) {
        self.id = id
        self.name = name
        self.level = level
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
