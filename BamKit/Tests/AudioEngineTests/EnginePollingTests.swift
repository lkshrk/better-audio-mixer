import XCTest
import Foundation
import BamCore
@testable import AudioEngine

final class EnginePollingTests: XCTestCase {
    func testPlayingScanDoesNotBlockEngineControls() async {
        let entered = expectation(description: "scan started")
        let responsive = expectation(description: "engine responded while scan blocked")
        let release = DispatchSemaphore(value: 0)
        let engine = CoreAudioEngine(polling: (playing: {
            entered.fulfill()
            release.wait()
            return ["playing.app"]
        }, processes: { [] }))
        let scan = Task { await engine.playingBundleIDs() }
        await fulfillment(of: [entered], timeout: 2)
        let controls = Task {
            await engine.updateRouterGains(config: BamConfig())
            _ = await engine.audioDiagnostics()
            responsive.fulfill()
        }
        await fulfillment(of: [responsive], timeout: 1)
        release.signal()
        await controls.value
        let playing = await scan.value
        XCTAssertEqual(playing, ["playing.app"])
    }

    func testHealthScanDoesNotBlockControlsAndDiscardsObsoleteResults() async {
        let entered = expectation(description: "health scan started")
        let responsive = expectation(description: "control invalidated scan without waiting")
        let release = DispatchSemaphore(value: 0)
        let engine = CoreAudioEngine(polling: (playing: { [] }, processes: {
            entered.fulfill()
            release.wait()
            return []
        }))
        await engine.installRouterForTests(resources: RouterAggregate.IOResources())
        await engine.configureRecoveryForTests(config: BamConfig(), hooks: .init(
            outputUIDs: [], willTearDown: {}, rebuild: { .ok }))
        let scan = Task { await engine.checkRouterHealthForTests() }
        await fulfillment(of: [entered], timeout: 2)
        let controls = Task {
            await engine.updateRouterGains(config: BamConfig())
            await engine.trackStartedRouter(signature: "new-route", outputUID: "render", deviceIDs: [:])
            responsive.fulfill()
        }
        await fulfillment(of: [responsive], timeout: 1)
        release.signal()
        await controls.value
        let continued = await scan.value
        XCTAssertFalse(continued, "Old observations cannot recover or mutate the new route")
    }

    func testPlayingIndicatorOnlyReadsMetadataForActiveProcesses() {
        var metadataReads: [UInt32] = []
        let playing = ProcessEnumerator.activeBundleIDs([1, 2, 3, 4, 5], isRunning: { $0 != 1 }, bundleID: {
            metadataReads.append($0)
            return $0 == 4 ? "" : $0 == 5 ? nil : "app"
        })
        XCTAssertEqual(playing, ["app"])
        XCTAssertEqual(metadataReads, [2, 3, 4, 5])
    }
}
