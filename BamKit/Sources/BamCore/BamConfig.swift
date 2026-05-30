import Foundation
import Yams

public struct BamConfig: Sendable, Equatable, Codable {
    public var master: Double
    public var masterMuted: Bool
    public var outputDeviceUID: String?
    public var groups: [Group]
    // v3 router model (additive; v1/v2 ignore these).
    public var sources: [Source]
    public var mixes: [Mix]
    public var solo: String?                // Source.id, global single solo (Q14)
    public var pans: [String: Double]       // Source.id → 0…1, global per source (Q11)

    public init(
        master: Double = 1.0,
        masterMuted: Bool = false,
        outputDeviceUID: String? = nil,
        groups: [Group] = [],
        sources: [Source] = [],
        mixes: [Mix] = [],
        solo: String? = nil,
        pans: [String: Double] = [:]
    ) {
        self.master = master
        self.masterMuted = masterMuted
        self.outputDeviceUID = outputDeviceUID
        self.groups = groups
        self.sources = sources
        self.mixes = mixes
        self.solo = solo
        self.pans = pans
    }

    private enum CodingKeys: String, CodingKey {
        case master, masterMuted, outputDeviceUID, groups, sources, mixes, solo, pans
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.master = try c.decodeIfPresent(Double.self, forKey: .master) ?? 1.0
        self.masterMuted = try c.decodeIfPresent(Bool.self, forKey: .masterMuted) ?? false
        self.outputDeviceUID = try c.decodeIfPresent(String.self, forKey: .outputDeviceUID)
        self.groups = try c.decodeIfPresent([Group].self, forKey: .groups) ?? []
        self.sources = try c.decodeIfPresent([Source].self, forKey: .sources) ?? []
        self.mixes = try c.decodeIfPresent([Mix].self, forKey: .mixes) ?? []
        self.solo = try c.decodeIfPresent(String.self, forKey: .solo)
        self.pans = try c.decodeIfPresent([String: Double].self, forKey: .pans) ?? [:]
    }

    public static func load(yaml: String) throws -> BamConfig {
        let config = try YAMLDecoder().decode(BamConfig.self, from: yaml)
        try config.validate()
        return config
    }

    public static func load(url: URL) throws -> BamConfig {
        try load(yaml: String(contentsOf: url, encoding: .utf8))
    }

    public func yaml() throws -> String {
        try YAMLEncoder().encode(self)
    }

    public func validate() throws {
        let unassigned = groups.filter(\.includesUnassigned).map(\.name)
        if unassigned.count > 1 {
            throw BamConfigError.multipleUnassignedGroups(unassigned)
        }
        let names = groups.map(\.name)
        let dupes = Dictionary(grouping: names, by: { $0 }).filter { $0.value.count > 1 }.keys
        if !dupes.isEmpty {
            throw BamConfigError.duplicateGroupNames(Array(dupes))
        }
        try validateRouting()
    }

    /// v3 router validation. No-op when no sources/mixes are present (v1/v2).
    public func validateRouting() throws {
        guard !sources.isEmpty || !mixes.isEmpty else { return }

        let sourceIDs = sources.map(\.id)
        let dupSources = Dictionary(grouping: sourceIDs, by: { $0 }).filter { $0.value.count > 1 }.keys
        if !dupSources.isEmpty { throw BamConfigError.duplicateSourceIDs(Array(dupSources)) }

        let mixIDs = mixes.map(\.id)
        let dupMixes = Dictionary(grouping: mixIDs, by: { $0 }).filter { $0.value.count > 1 }.keys
        if !dupMixes.isEmpty { throw BamConfigError.duplicateMixIDs(Array(dupMixes)) }

        let idSet = Set(sourceIDs)
        for mix in mixes {
            for send in mix.sends where !idSet.contains(send.source) {
                throw BamConfigError.unknownSendSource(mix: mix.id, source: send.source)
            }
        }
        if let solo, !idSet.contains(solo) {
            throw BamConfigError.unknownSoloSource(solo)
        }
        let rest = sources.filter(\.isRemainder).map(\.id)
        if rest.count > 1 { throw BamConfigError.multipleRemainderSources(rest) }
    }

    /// Bundle IDs claimed by any explicit group. The "All Audio" remainder tap
    /// excludes these so grouped audio is not double-counted.
    public var explicitlyGroupedBundleIDs: Set<String> {
        Set(groups.flatMap(\.bundleIDs))
    }

    public var unassignedGroup: Group? {
        groups.first(where: \.includesUnassigned)
    }
}

public enum BamConfigError: Error, Equatable, CustomStringConvertible {
    case multipleUnassignedGroups([String])
    case duplicateGroupNames([String])
    case duplicateSourceIDs([String])
    case duplicateMixIDs([String])
    case unknownSendSource(mix: String, source: String)
    case unknownSoloSource(String)
    case multipleRemainderSources([String])

    public var description: String {
        switch self {
        case .multipleUnassignedGroups(let names):
            return "Only one group may set includesUnassigned; found: \(names.joined(separator: ", "))"
        case .duplicateGroupNames(let names):
            return "Duplicate group names: \(names.joined(separator: ", "))"
        case .duplicateSourceIDs(let ids):
            return "Duplicate source ids: \(ids.joined(separator: ", "))"
        case .duplicateMixIDs(let ids):
            return "Duplicate mix ids: \(ids.joined(separator: ", "))"
        case .unknownSendSource(let mix, let source):
            return "Mix \(mix) sends from unknown source: \(source)"
        case .unknownSoloSource(let id):
            return "Solo references unknown source: \(id)"
        case .multipleRemainderSources(let ids):
            return "Only one remainder source allowed; found: \(ids.joined(separator: ", "))"
        }
    }
}
