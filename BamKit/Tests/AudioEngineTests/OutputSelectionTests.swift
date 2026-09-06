import XCTest
@testable import AudioEngine

final class OutputSelectionTests: XCTestCase {
    func testUnsetSelectionCanSeedFromSystemDefault() {
        XCTAssertEqual(CoreAudioEngine.resolveOutputUID(stored: nil, liveUIDs: ["default"], defaultUID: "default"), "default")
        XCTAssertNil(CoreAudioEngine.resolveOutputUID(stored: nil, liveUIDs: [], defaultUID: nil))
    }

    func testSelectedOutputIgnoresSystemDefaultChanges() {
        for defaultUID in ["capture-a", "capture-b"] {
            XCTAssertEqual(CoreAudioEngine.resolveOutputUID(stored: "chosen", liveUIDs: ["chosen", defaultUID], defaultUID: defaultUID), "chosen")
        }
    }

    func testMissingSelectionNeverFallsBackToSystemDefault() {
        XCTAssertNil(CoreAudioEngine.resolveOutputUID(stored: "chosen", liveUIDs: ["default"], defaultUID: "default"))
    }

    func testUniqueStableUSBIdentityRebinds() {
        let prefix = "AppleUSBAudioEngine:Vendor:Device:Serial:"
        XCTAssertEqual(CoreAudioEngine.resolveOutputUID(stored: prefix + "1", liveUIDs: [prefix + "2", "default"], defaultUID: "default"), prefix + "2")
    }

    func testAmbiguousStableUSBIdentityStaysUnavailableButExactMatchWins() {
        let prefix = "AppleUSBAudioEngine:Vendor:Device:Serial:"
        let live = [prefix + "2", prefix + "3", "default"]
        XCTAssertNil(CoreAudioEngine.resolveOutputUID(stored: prefix + "1", liveUIDs: live, defaultUID: "default"))
        XCTAssertEqual(CoreAudioEngine.resolveOutputUID(stored: prefix + "2", liveUIDs: live, defaultUID: "default"), prefix + "2")
    }

    func testDistinctNonUSBEndpointsDoNotRebind() {
        XCTAssertNil(CoreAudioEngine.resolveOutputUID(stored: "display:1", liveUIDs: ["display:2"], defaultUID: "display:2"))
    }
}
