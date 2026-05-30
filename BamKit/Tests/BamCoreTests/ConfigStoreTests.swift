import XCTest
@testable import BamCore

final class ConfigStoreTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("bam-\(UUID().uuidString).yaml")
    }

    private func sampleConfig() -> BamConfig {
        BamConfig(
            sources: [
                Source(id: "game", name: "Game", bundleIDs: ["com.valve.steam"]),
                Source(id: "rest", name: "Everything Else", kind: .rest),
            ],
            mixes: [
                Mix(id: "stream", name: "Stream", dest: .virtualSlot(0), level: 0.9, sends: [
                    Send(source: "game", level: 0.8),
                ]),
            ],
            pans: ["game": 0.4]
        )
    }

    func testSaveThenLoadRoundTrips() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let cfg = sampleConfig()
        try ConfigStore.save(cfg, to: url)
        let loaded = try BamConfig.load(url: url)
        XCTAssertEqual(loaded, cfg)
    }

    func testSaveRejectsInvalidConfigAndWritesNothing() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        // Send references a source that does not exist → validation must fail.
        let bad = BamConfig(
            sources: [Source(id: "a", name: "A")],
            mixes: [Mix(id: "m", name: "M", dest: .virtualSlot(0),
                        sends: [Send(source: "ghost")])]
        )
        XCTAssertThrowsError(try ConfigStore.save(bad, to: url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "an invalid config must not leave a partial file on disk")
    }
}
