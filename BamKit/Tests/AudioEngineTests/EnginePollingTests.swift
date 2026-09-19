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

    func testPlayingIndicatorReadsMetadataOncePerObjectAndOnlyRunningFlagsAfterwards() {
        let metadataReads = LockedList()
        let runningReads = LockedList()
        let cache = ProcessSnapshotCache(ttl: .zero, readers: .init(
            objectIDs: { [1, 2, 3] },
            info: { id in
                metadataReads.append(id)
                return AudioProcessInfo(objectID: id, pid: pid_t(id), bundleID: id == 3 ? "" : "app.\(id)", isRunningOutput: id != 1)
            },
            isRunningOutput: { id in runningReads.append(id); return id != 1 }))
        let first = cache.snapshot().filter { $0.isRunningOutput && !$0.bundleID.isEmpty }.map(\.bundleID)
        XCTAssertEqual(Set(first), ["app.2"])
        XCTAssertEqual(metadataReads.values, [1, 2, 3])
        _ = cache.snapshot(now: .now.advanced(by: .seconds(1)))
        XCTAssertEqual(metadataReads.values, [1, 2, 3], "metadata is immutable for a live object and never re-read")
        XCTAssertEqual(runningReads.values, [1, 2, 3], "a later poll re-reads only the running flag")
    }
}

private final class LockedList: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [UInt32] = []
    var values: [UInt32] { lock.withLock { stored } }
    func append(_ value: UInt32) { lock.withLock { stored.append(value) } }
}
