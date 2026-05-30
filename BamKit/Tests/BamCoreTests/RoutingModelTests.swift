import XCTest
@testable import BamCore

final class RoutingModelTests: XCTestCase {
    private func sampleConfig() -> BamConfig {
        BamConfig(
            sources: [
                Source(id: "game", name: "Game", bundleIDs: ["com.valve.steam"]),
                Source(id: "chatapp", name: "Discord", bundleIDs: ["com.hnc.Discord"]),
                Source(id: "rest", name: "Everything Else", kind: .rest),
            ],
            mixes: [
                Mix(id: "stream", name: "Stream", dest: .virtualSlot(0), level: 1.0, sends: [
                    Send(source: "game", level: 0.8),
                    Send(source: "chatapp", level: 1.0),
                ]),
                Mix(id: "chat", name: "Chat", dest: .virtualSlot(1), sends: [
                    Send(source: "game", level: 0.5), // mix-minus: no chatapp
                ]),
                Mix(id: "monitor", name: "Monitor", dest: .hardware(uid: "BuiltInSpeaker"), sends: [
                    Send(source: "game"), Send(source: "chatapp"),
                ]),
            ],
            solo: nil,
            pans: ["game": 0.4, "chatapp": 0.6]
        )
    }

    func testYAMLRoundTrip() throws {
        let cfg = sampleConfig()
        let yaml = try cfg.yaml()
        let back = try BamConfig.load(yaml: yaml)
        XCTAssertEqual(back, cfg)
    }

    func testDestinationUIDMapping() {
        XCTAssertEqual(MixDestination.virtualSlot(3).deviceUID, "BAM_UID_3")
        XCTAssertEqual(MixDestination.hardware(uid: "AppleHDA").deviceUID, "AppleHDA")
    }

    func testValidateAcceptsGoodConfig() throws {
        try sampleConfig().validate()
    }

    func testRejectsUnknownSendSource() {
        let cfg = BamConfig(
            sources: [Source(id: "a", name: "A")],
            mixes: [Mix(id: "m", name: "M", dest: .virtualSlot(0),
                        sends: [Send(source: "ghost")])]
        )
        XCTAssertThrowsError(try cfg.validate()) {
            XCTAssertEqual($0 as? BamConfigError, .unknownSendSource(mix: "m", source: "ghost"))
        }
    }

    func testRejectsDuplicateSourceIDs() {
        let cfg = BamConfig(sources: [
            Source(id: "dup", name: "A"), Source(id: "dup", name: "B"),
        ])
        XCTAssertThrowsError(try cfg.validate()) {
            XCTAssertEqual($0 as? BamConfigError, .duplicateSourceIDs(["dup"]))
        }
    }

    func testRejectsDuplicateMixIDs() {
        let cfg = BamConfig(
            sources: [Source(id: "a", name: "A")],
            mixes: [
                Mix(id: "m", name: "M1", dest: .virtualSlot(0)),
                Mix(id: "m", name: "M2", dest: .virtualSlot(1)),
            ]
        )
        XCTAssertThrowsError(try cfg.validate()) {
            XCTAssertEqual($0 as? BamConfigError, .duplicateMixIDs(["m"]))
        }
    }

    func testRejectsUnknownSolo() {
        let cfg = BamConfig(sources: [Source(id: "a", name: "A")], solo: "nope")
        XCTAssertThrowsError(try cfg.validate()) {
            XCTAssertEqual($0 as? BamConfigError, .unknownSoloSource("nope"))
        }
    }

    func testRejectsMultipleRemainders() {
        let cfg = BamConfig(sources: [
            Source(id: "r1", name: "Rest1", kind: .rest),
            Source(id: "r2", name: "Rest2", kind: .rest),
        ])
        XCTAssertThrowsError(try cfg.validate())
    }

    func testLegacyConfigStillValidatesWithoutRouting() throws {
        // v1/v2 config: only groups, no sources/mixes → routing validation no-ops.
        let cfg = BamConfig(groups: [Group(name: "All", includesUnassigned: true)])
        try cfg.validate()
        XCTAssertTrue(cfg.sources.isEmpty)
        XCTAssertTrue(cfg.mixes.isEmpty)
    }
}
