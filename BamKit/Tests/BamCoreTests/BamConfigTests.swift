import Testing
@testable import BamCore

@Suite struct BamConfigTests {
    @Test func decodesRouterConfigWithDefaults() throws {
        let yaml = """
        sources:
          - id: music
            name: Music
            bundleIDs: ["com.apple.Music", "com.spotify.client"]
          - id: rest
            name: Everything Else
            kind: rest
        mixes:
          - id: monitor
            name: Monitor
            dest:
              hardwareUID: BuiltInSpeaker
            sends:
              - source: music
              - source: rest
        """
        let config = try BamConfig.load(yaml: yaml)
        #expect(config.master == 1.0)
        #expect(config.masterMuted == false)
        #expect(config.sources.count == 2)
        #expect(config.mixes.count == 1)
        #expect(config.pans.isEmpty)
    }

    @Test func yamlRoundTripsRouterConfig() throws {
        let config = BamConfig(
            master: 0.9,
            masterMuted: true,
            sources: [
                Source(id: "music", name: "Music", bundleIDs: ["com.apple.Music"]),
                Source(id: "rest", name: "Default", kind: .rest),
            ],
            mixes: [
                Mix(id: "monitor", name: "Monitor", dest: .hardware(uid: "BuiltInSpeaker"), sends: [
                    Send(source: "music", level: 0.5),
                    Send(source: "rest", muted: true),
                ]),
            ],
            solo: "music",
            pans: ["music": 0.4]
        )
        let yaml = try config.yaml()
        let decoded = try BamConfig.load(yaml: yaml)
        #expect(decoded == config)
    }

    @Test func rejectsMasterOutsideUnitRange() {
        #expect(throws: BamConfigError.masterOutOfRange(1.5)) { try BamConfig(master: 1.5).validate() }
        #expect(throws: BamConfigError.masterOutOfRange(-0.1)) { try BamConfig(master: -0.1).validate() }
        #expect(throws: BamConfigError.self) { try BamConfig(master: .nan).validate() }
        #expect(throws: BamConfigError.self) { try BamConfig(master: .infinity).validate() }
    }

    @Test func rejectsMixAndSendLevelsOutsideUnitRange() {
        let sources = [Source(id: "music", name: "Music", bundleIDs: ["com.apple.Music"])]
        let hotMix = BamConfig(sources: sources, mixes: [
            Mix(id: "m", name: "M", dest: .virtualSlot(0), level: 5, sends: [Send(source: "music")]),
        ])
        #expect(throws: BamConfigError.mixLevelOutOfRange(mix: "m", level: 5)) { try hotMix.validate() }

        let hotSend = BamConfig(sources: sources, mixes: [
            Mix(id: "m", name: "M", dest: .virtualSlot(0), sends: [Send(source: "music", level: -0.5)]),
        ])
        #expect(throws: BamConfigError.sendLevelOutOfRange(mix: "m", source: "music", level: -0.5)) {
            try hotSend.validate()
        }

        let nanSend = BamConfig(sources: sources, mixes: [
            Mix(id: "m", name: "M", dest: .virtualSlot(0), sends: [Send(source: "music", level: .nan)]),
        ])
        #expect(throws: BamConfigError.self) { try nanSend.validate() }
    }

    @Test func rejectsPansOutsideUnitRangeOrForUnknownSources() {
        let sources = [Source(id: "music", name: "Music", bundleIDs: ["com.apple.Music"])]
        #expect(throws: BamConfigError.panOutOfRange(source: "music", pan: 2)) {
            try BamConfig(sources: sources, pans: ["music": 2]).validate()
        }
        #expect(throws: BamConfigError.unknownPanSource("ghost")) {
            try BamConfig(sources: sources, pans: ["ghost": 0.5]).validate()
        }
        #expect(throws: Never.self) { try BamConfig(sources: sources, pans: ["music": 0.5]).validate() }
    }

    @Test func loadPrunesPansForRemovedSources() throws {
        let yaml = """
        master: 1
        sources:
          - id: music
            name: Music
            bundleIDs: [com.apple.Music]
        mixes: []
        pans:
          music: 0.25
          ghost: 0.5
        """
        let config = try BamConfig.load(yaml: yaml)
        #expect(config.pans == ["music": 0.25])
    }

    @Test func loadRejectsNonFiniteYAMLValues() {
        let yaml = """
        master: .nan
        sources:
          - id: music
            name: Music
        """
        #expect(throws: BamConfigError.self) { try BamConfig.load(yaml: yaml) }
    }
}
