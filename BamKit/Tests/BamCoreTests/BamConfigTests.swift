import Testing
import Foundation
@testable import BamCore

@Suite struct BamConfigTests {
    @Test func decodesGroupsWithDefaults() throws {
        let yaml = """
        groups:
          - name: Music
            bundleIDs: ["com.apple.Music", "com.spotify.client"]
          - name: Everything Else
            volume: 0.8
            muted: true
            includesUnassigned: true
        """
        let config = try BamConfig.load(yaml: yaml)
        #expect(config.groups.count == 2)
        let music = config.groups[0]
        #expect(music.name == "Music")
        #expect(music.volume == 1.0)
        #expect(music.muted == false)
        #expect(music.bundleIDs == ["com.apple.Music", "com.spotify.client"])
        #expect(music.includesUnassigned == false)
        let rest = config.groups[1]
        #expect(rest.volume == 0.8)
        #expect(rest.muted == true)
        #expect(rest.includesUnassigned == true)
    }

    @Test func rejectsTwoUnassignedGroups() {
        let yaml = """
        groups:
          - name: A
            includesUnassigned: true
          - name: B
            includesUnassigned: true
        """
        #expect(throws: BamConfigError.self) {
            try BamConfig.load(yaml: yaml)
        }
    }

    @Test func rejectsDuplicateNames() {
        let yaml = """
        groups:
          - name: Dup
          - name: Dup
        """
        #expect(throws: BamConfigError.self) {
            try BamConfig.load(yaml: yaml)
        }
    }

    @Test func yamlRoundTrips() throws {
        let config = BamConfig(groups: [
            Group(name: "Music", volume: 0.5, muted: true, bundleIDs: ["com.apple.Music"], includesUnassigned: false),
            Group(name: "Rest", volume: 1.0, muted: false, bundleIDs: [], includesUnassigned: true),
        ])
        let yaml = try config.yaml()
        let decoded = try BamConfig.load(yaml: yaml)
        #expect(decoded == config)
    }

    @Test func explicitlyGroupedExcludesNothingForUnassignedOnly() throws {
        let yaml = """
        groups:
          - name: Music
            bundleIDs: ["com.apple.Music"]
          - name: Rest
            includesUnassigned: true
        """
        let config = try BamConfig.load(yaml: yaml)
        #expect(config.explicitlyGroupedBundleIDs == ["com.apple.Music"])
        #expect(config.unassignedGroup?.name == "Rest")
    }
}
