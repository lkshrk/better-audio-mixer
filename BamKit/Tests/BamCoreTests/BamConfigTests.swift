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
}
