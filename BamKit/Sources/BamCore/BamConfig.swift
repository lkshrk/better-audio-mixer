import Foundation
import Yams

public struct BamConfig: Sendable, Equatable, Codable {
    public var master: Double
    public var masterMuted: Bool
    public var sources: [Source]
    public var mixes: [Mix]
    public var solo: String?                // Source.id, global single solo
    public var pans: [String: Double]       // Source.id → 0…1, global per source

    public init(
        master: Double = 1.0,
        masterMuted: Bool = false,
        sources: [Source] = [],
        mixes: [Mix] = [],
        solo: String? = nil,
        pans: [String: Double] = [:]
    ) {
        self.master = master
        self.masterMuted = masterMuted
        self.sources = sources
        self.mixes = mixes
        self.solo = solo
        self.pans = pans
    }

    private enum CodingKeys: String, CodingKey {
        case master, masterMuted, sources, mixes, solo, pans
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.master = try c.decodeIfPresent(Double.self, forKey: .master) ?? 1.0
        self.masterMuted = try c.decodeIfPresent(Bool.self, forKey: .masterMuted) ?? false
        self.sources = try c.decodeIfPresent([Source].self, forKey: .sources) ?? []
        self.mixes = try c.decodeIfPresent([Mix].self, forKey: .mixes) ?? []
        self.solo = try c.decodeIfPresent(String.self, forKey: .solo)
        self.pans = try c.decodeIfPresent([String: Double].self, forKey: .pans) ?? [:]
    }

    public static func load(yaml: String) throws -> BamConfig {
        var config = try YAMLDecoder().decode(BamConfig.self, from: yaml)
        config.pruneStalePans()
        try config.validate()
        return config
    }

    public mutating func pruneStalePans() {
        let ids = Set(sources.map(\.id))
        pans = pans.filter { ids.contains($0.key) }
    }

    public static func load(url: URL) throws -> BamConfig {
        try load(yaml: String(contentsOf: url, encoding: .utf8))
    }

    public func yaml() throws -> String {
        try YAMLEncoder().encode(self)
    }

    public func validate() throws {
        try validateRanges()
        try validateRouting()
    }

    public func validateRanges() throws {
        func inUnit(_ v: Double) -> Bool { v.isFinite && v >= 0 && v <= 1 }
        guard inUnit(master) else { throw BamConfigError.masterOutOfRange(master) }
        for mix in mixes {
            guard inUnit(mix.level) else { throw BamConfigError.mixLevelOutOfRange(mix: mix.id, level: mix.level) }
            for send in mix.sends where !inUnit(send.level) {
                throw BamConfigError.sendLevelOutOfRange(mix: mix.id, source: send.source, level: send.level)
            }
        }
        let idSet = Set(sources.map(\.id))
        for (source, pan) in pans.sorted(by: { $0.key < $1.key }) {
            guard idSet.contains(source) else { throw BamConfigError.unknownPanSource(source) }
            guard inUnit(pan) else { throw BamConfigError.panOutOfRange(source: source, pan: pan) }
        }
    }

    public func validateRouting() throws {
        guard !sources.isEmpty || !mixes.isEmpty else { return }

        let sourceIDs = sources.map(\.id)
        let dupSources = Dictionary(grouping: sourceIDs, by: { $0 }).filter { $0.value.count > 1 }.keys
        if !dupSources.isEmpty { throw BamConfigError.duplicateSourceIDs(Array(dupSources)) }

        let mixIDs = mixes.map(\.id)
        let dupMixes = Dictionary(grouping: mixIDs, by: { $0 }).filter { $0.value.count > 1 }.keys
        if !dupMixes.isEmpty { throw BamConfigError.duplicateMixIDs(Array(dupMixes)) }

        let idSet = Set(sourceIDs)
        var routedSources: [String: [String]] = [:]
        for mix in mixes {
            for send in mix.sends where !idSet.contains(send.source) {
                throw BamConfigError.unknownSendSource(mix: mix.id, source: send.source)
            }
            for send in mix.sends {
                routedSources[send.source, default: []].append(mix.id)
            }
        }
        let duplicateRoutes = routedSources
            .filter { $0.value.count > 1 }
            .sorted { $0.key < $1.key }
            .map { source, mixes in SourceRouteConflict(source: source, mixes: mixes) }
        if !duplicateRoutes.isEmpty {
            throw BamConfigError.duplicateSourceRoutes(duplicateRoutes)
        }

        var appOwners: [String: [String]] = [:]
        for source in sources where source.kind == .app {
            for bundleID in source.bundleIDs {
                appOwners[bundleID, default: []].append(source.id)
            }
        }
        let duplicateApps = appOwners
            .filter { $0.value.count > 1 }
            .sorted { $0.key < $1.key }
            .map { bundleID, sources in AppAssignmentConflict(bundleID: bundleID, sources: sources) }
        if !duplicateApps.isEmpty {
            throw BamConfigError.duplicateAppAssignments(duplicateApps)
        }
        if let solo, !idSet.contains(solo) {
            throw BamConfigError.unknownSoloSource(solo)
        }
        let rest = sources.filter(\.isRemainder).map(\.id)
        if rest.count > 1 { throw BamConfigError.multipleRemainderSources(rest) }
    }
}

public struct SourceRouteConflict: Sendable, Equatable {
    public var source: String
    public var mixes: [String]

    public init(source: String, mixes: [String]) {
        self.source = source
        self.mixes = mixes
    }
}

public struct AppAssignmentConflict: Sendable, Equatable {
    public var bundleID: String
    public var sources: [String]

    public init(bundleID: String, sources: [String]) {
        self.bundleID = bundleID
        self.sources = sources
    }
}

public enum BamConfigError: Error, Equatable, CustomStringConvertible {
    case duplicateSourceIDs([String])
    case duplicateMixIDs([String])
    case unknownSendSource(mix: String, source: String)
    case duplicateSourceRoutes([SourceRouteConflict])
    case duplicateAppAssignments([AppAssignmentConflict])
    case unknownSoloSource(String)
    case multipleRemainderSources([String])
    case masterOutOfRange(Double)
    case mixLevelOutOfRange(mix: String, level: Double)
    case sendLevelOutOfRange(mix: String, source: String, level: Double)
    case unknownPanSource(String)
    case panOutOfRange(source: String, pan: Double)

    public var description: String {
        switch self {
        case .masterOutOfRange(let v):
            return "Master must be a number in 0…1; found: \(v)"
        case .mixLevelOutOfRange(let mix, let level):
            return "Mix \(mix) level must be a number in 0…1; found: \(level)"
        case .sendLevelOutOfRange(let mix, let source, let level):
            return "Mix \(mix) send \(source) level must be a number in 0…1; found: \(level)"
        case .unknownPanSource(let id):
            return "Pan references unknown source: \(id)"
        case .panOutOfRange(let source, let pan):
            return "Pan for \(source) must be a number in 0…1; found: \(pan)"
        case .duplicateSourceIDs(let ids):
            return "Duplicate source ids: \(ids.joined(separator: ", "))"
        case .duplicateMixIDs(let ids):
            return "Duplicate mix ids: \(ids.joined(separator: ", "))"
        case .unknownSendSource(let mix, let source):
            return "Mix \(mix) sends from unknown source: \(source)"
        case .duplicateSourceRoutes(let conflicts):
            return "Sources may be routed to only one group: " + conflicts
                .map { "\($0.source) in \($0.mixes.joined(separator: ", "))" }
                .joined(separator: "; ")
        case .duplicateAppAssignments(let conflicts):
            return "Apps may belong to only one source group: " + conflicts
                .map { "\($0.bundleID) in \($0.sources.joined(separator: ", "))" }
                .joined(separator: "; ")
        case .unknownSoloSource(let id):
            return "Solo references unknown source: \(id)"
        case .multipleRemainderSources(let ids):
            return "Only one remainder source allowed; found: \(ids.joined(separator: ", "))"
        }
    }
}
