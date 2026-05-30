import XCTest
@testable import BamCore

final class EmojiInputTests: XCTestCase {
    func testEmptyYieldsNil() {
        XCTAssertNil(EmojiInput.lastGrapheme(of: ""))
    }

    func testSingleEmojiKept() {
        XCTAssertEqual(EmojiInput.lastGrapheme(of: "🎮"), "🎮")
    }

    func testKeepsOnlyNewestGlyph() {
        // Viewer appends to existing text; we want just the last pick.
        XCTAssertEqual(EmojiInput.lastGrapheme(of: "🎮🎧"), "🎧")
    }

    func testGraphemeClusterIsOne() {
        // Skin-toned / ZWJ emoji is a single user-perceived character.
        XCTAssertEqual(EmojiInput.lastGrapheme(of: "👍🏽"), "👍🏽")
    }

    func testAsciiCharSurvives() {
        XCTAssertEqual(EmojiInput.lastGrapheme(of: "x"), "x")
    }
}
