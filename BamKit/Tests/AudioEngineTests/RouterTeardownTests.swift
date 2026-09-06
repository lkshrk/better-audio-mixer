import CoreAudio
import XCTest
@testable import AudioEngine

final class RouterTeardownTests: XCTestCase {
    func testRegisteredCallbackWithFailedStartCanBeDestroyedAndRetried() {
        var calls: [String] = []
        var failDestroy = true
        let resources = RouterAggregate.IOResources(operations: .init(
            stop: { _, _ in calls.append("stop"); return kAudioHardwareNotRunningError },
            destroyIOProc: { _, _ in
                calls.append("callback")
                return failDestroy ? -1 : noErr
            }, destroyAggregate: { _ in calls.append("aggregate"); return noErr }, isGone: { _ in false }))
        resources.aggregateID = 42
        resources.ioProcID = { _, _, _, _, _, _, _ in noErr }
        XCTAssertFalse(resources.close())
        XCTAssertEqual(calls, ["stop", "callback"])
        XCTAssertNotNil(resources.ioProcID)
        failDestroy = false
        calls.removeAll()
        XCTAssertTrue(resources.close())
        XCTAssertEqual(calls, ["callback", "aggregate"])
        XCTAssertNil(resources.ioProcID)
        XCTAssertEqual(resources.aggregateID, kAudioObjectUnknown)
    }

    func testCallbackOwnsFadeStateUntilSuccessfulCallbackDestruction() {
        var state: RouterAggregate.CallbackLifetime? = .init(taps: [])
        weak var observedState = state
        var retainedCallback: (() -> Int)? = { [state = state!] in
            state.played += 1
            return state.played
        }
        var fail = true
        let resources = RouterAggregate.IOResources(operations: .init(
            stop: { _, _ in noErr }, destroyIOProc: { _, _ in
                if fail { return -1 }
                retainedCallback = nil
                return noErr
            }, destroyAggregate: { _ in noErr }, isGone: { _ in false }))
        resources.aggregateID = 42
        resources.ioProcID = { _, _, _, _, _, _, _ in noErr }
        state = nil
        XCTAssertFalse(resources.close())
        XCTAssertNotNil(observedState)
        XCTAssertEqual(retainedCallback?(), 1)
        fail = false
        XCTAssertTrue(resources.close())
        XCTAssertNil(observedState)
    }

    func testEachFailureRetainsItsHandleAndRetryResumesAtFailedStage() {
        for failedStage in ["stop", "callback", "aggregate"] {
            var calls: [String] = []
            var fail = true
            func operation(_ stage: String) -> OSStatus {
                calls.append(stage)
                return fail && stage == failedStage ? -1 : noErr
            }
            let resources = RouterAggregate.IOResources(operations: .init(
                stop: { _, _ in operation("stop") },
                destroyIOProc: { _, _ in operation("callback") },
                destroyAggregate: { _ in operation("aggregate") }, isGone: { _ in false }))
            resources.aggregateID = 42
            resources.ioProcID = { _, _, _, _, _, _, _ in noErr }
            XCTAssertFalse(resources.close())
            XCTAssertEqual(resources.aggregateID, 42)
            XCTAssertEqual(resources.ioProcID == nil, failedStage == "aggregate")
            fail = false
            calls.removeAll()
            XCTAssertTrue(resources.close())
            let expected = Array(["stop", "callback", "aggregate"].drop(while: { $0 != failedStage }))
            XCTAssertEqual(calls, expected)
            XCTAssertEqual(resources.aggregateID, kAudioObjectUnknown)
            XCTAssertNil(resources.ioProcID)
            calls.removeAll()
            XCTAssertTrue(resources.close())
            XCTAssertTrue(calls.isEmpty)
        }
    }

    func testOnlyVerifiedMissingDevicePermitsClearingFailedHandles() {
        var gone = false
        let resources = RouterAggregate.IOResources(operations: .init(
            stop: { _, _ in -1 }, destroyIOProc: { _, _ in XCTFail("Must stop first"); return -1 },
            destroyAggregate: { _ in XCTFail("Must stop first"); return -1 }, isGone: { _ in gone }))
        resources.aggregateID = 42
        resources.ioProcID = { _, _, _, _, _, _, _ in noErr }
        XCTAssertFalse(resources.close())
        gone = true
        XCTAssertTrue(resources.close())
        XCTAssertNil(resources.ioProcID)
        XCTAssertEqual(resources.aggregateID, kAudioObjectUnknown)
    }

    func testFailedBuildWithoutCallbackStillRetainsAggregateForRetry() {
        var fail = true
        let resources = RouterAggregate.IOResources(operations: .init(
            stop: { _, _ in XCTFail("No callback"); return -1 },
            destroyIOProc: { _, _ in XCTFail("No callback"); return -1 },
            destroyAggregate: { _ in fail ? -1 : noErr }, isGone: { _ in false }))
        resources.aggregateID = 42
        let router = RouterAggregate(taps: [], resources: resources)
        XCTAssertFalse(router.close())
        XCTAssertEqual(resources.aggregateID, 42)
        fail = false
        XCTAssertTrue(router.close())
    }
}
