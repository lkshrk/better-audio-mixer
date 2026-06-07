import XCTest

final class RouterHealthPolicySourceTests: XCTestCase {
    func testRouterHealthDoesNotRecoverFromSilentRender() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = packageRoot.appendingPathComponent("Sources/AudioEngine/CoreAudioEngine.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(source.contains("silent render"))
        XCTAssertFalse(source.contains("renderSilentSamples"))
        XCTAssertFalse(source.contains("healthOutputSilencePeak"))
    }
}
