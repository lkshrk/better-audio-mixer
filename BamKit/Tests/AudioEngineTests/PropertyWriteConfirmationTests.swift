import XCTest
import BamCore
@testable import AudioEngine

final class PropertyWriteConfirmationTests: XCTestCase {
    func testUnmutedVolumeTimeoutAutomaticallyRequestsMuteOutsideLock() {
        let state = CA.HardwareWriteState()
        var muted = false
        var writes = 0
        var muteRequests = 0
        func protect() {
            // Reentering the shared state proves protection runs outside its lock.
            XCTAssertFalse(state.perform(uid: "device", device: 7, protectingMute: true) { force, _ in
                XCTAssertTrue(force)
                muteRequests += 1
                muted = true
                return true
            })
        }
        XCTAssertFalse(state.perform(uid: "device", device: 7, protectingMute: false, onFailure: protect) { _, accepted in
            writes += 1
            accepted() // Higher volume was accepted; its notification never arrived.
            return false
        })
        XCTAssertTrue(muted)
        XCTAssertEqual(muteRequests, 1)
        XCTAssertFalse(state.perform(uid: "device", device: 7, protectingMute: false, onFailure: protect) { _, _ in
            writes += 1 // A later zero target must not clear the pending-write latch.
            return true
        })
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(muteRequests, 2)
    }

    func testForcedWriteRejectsAlreadyQueuedNotificationAndMatchingReadback() {
        var writes = 0
        XCTAssertFalse(CA.confirmWrite(isCurrent: { true }, matches: { true },
            subscribe: { signal in signal(); return {} },
            write: { writes += 1; return true }, forceWrite: true,
            wait: { signal, _ in signal.wait(timeout: .now()) == .success }))
        XCTAssertEqual(writes, 1, "stale matching readback must not skip reprotection")
    }

    func testForcedWriteAcceptsNotificationObservedAfterRequest() {
        var notify: (@Sendable () -> Void)?
        XCTAssertTrue(CA.confirmWrite(isCurrent: { true }, matches: { true },
            subscribe: { signal in notify = signal; return {} },
            write: { notify?(); return true }, forceWrite: true,
            wait: { signal, _ in signal.wait(timeout: .now()) == .success }))
    }

    func testDelayedUnmuteCannotBeCancelledByStaleTrueOrAuthorizeFutureProtection() {
        let state = CA.HardwareWriteState()
        var muted = true
        XCTAssertFalse(state.perform(uid: "device", device: 7, protectingMute: false) { force, accepted in
            CA.confirmWrite(isCurrent: { true }, matches: { !muted },
                subscribe: { _ in {} }, write: { accepted(); return true },
                forceWrite: force, wait: { _, _ in false })
        })
        var muteRequests = 0
        func reprotect() -> Bool {
            state.perform(uid: "device", device: 7, protectingMute: true) { force, accepted in
                XCTAssertTrue(force)
                return CA.confirmWrite(isCurrent: { true }, matches: { muted },
                    subscribe: { _ in {} }, write: {
                        muteRequests += 1
                        muted = true
                        accepted()
                        return true
                    }, forceWrite: force, wait: { _, _ in true })
            }
        }
        XCTAssertFalse(reprotect(), "even forced true acknowledgement cannot cancel the older release")
        XCTAssertEqual(muteRequests, 1, "stale true did not skip the replacement request")
        muted = false // The original accepted unmute arrives after the forced mute acknowledgement.
        XCTAssertFalse(reprotect(), "the uncertain identity cannot authorize a later rebuild")
        XCTAssertEqual(muteRequests, 2)
        XCTAssertTrue(muted)
        XCTAssertFalse(state.perform(uid: "device", device: 7, protectingMute: false) { _, _ in
            XCTFail("further release must be blocked"); return true
        })
        XCTAssertTrue(state.perform(uid: "device", device: 8, protectingMute: true) { force, _ in
            XCTAssertFalse(force); return true
        }, "a distinct AudioObjectID has no pending request from the old device")
    }

    func testUnconfirmedWriteLatchExpiresAfterSettleWindow() {
        let state = CA.HardwareWriteState(settleWindow: 0)
        XCTAssertFalse(state.perform(uid: "device", device: 7, protectingMute: false) { _, accepted in
            accepted(); return false
        })
        var writes = 0
        XCTAssertTrue(state.perform(uid: "device", device: 7, protectingMute: false) { force, _ in
            XCTAssertFalse(force)
            writes += 1
            return true
        }, "a settled device accepts new writes again")
        XCTAssertEqual(writes, 1)
    }

    func testUnacceptedReleaseFailureDoesNotLatchPendingHardwareRequest() {
        let state = CA.HardwareWriteState()
        XCTAssertFalse(state.perform(uid: "device", device: 7, protectingMute: false) { _, _ in false })
        XCTAssertTrue(state.perform(uid: "device", device: 7, protectingMute: true) { force, _ in
            XCTAssertFalse(force); return true
        })
    }

    func testAcceptedVolumeTimeoutBlocksMatchingScalarAndUnmuteRetries() {
        let state = CA.HardwareWriteState()
        var volume: Float = 0.12
        XCTAssertFalse(state.perform(uid: "device", device: 7, protectingMute: false) { force, accepted in
            CA.confirmWrite(isCurrent: { true }, matches: { CA.volumeMatches(volume, target: 1) },
                subscribe: { _ in {} }, write: { accepted(); return true },
                forceWrite: force, wait: { _, _ in false })
        })
        for _ in 0..<2 { // Both a scalar restore and an unmute use this same unsafe-write gate.
            XCTAssertFalse(state.perform(uid: "device", device: 7, protectingMute: false) { _, _ in
                XCTFail("matching old scalar cannot clear a pending higher-volume request"); return true
            })
        }
        var muteRequests = 0
        XCTAssertFalse(state.perform(uid: "device", device: 7, protectingMute: true) { force, accepted in
            XCTAssertTrue(force)
            muteRequests += 1
            accepted()
            return true
        })
        volume = 1 // Late application remains possible even after the mute request was confirmed.
        XCTAssertEqual(volume, 1)
        XCTAssertEqual(muteRequests, 1)
        XCTAssertFalse(state.perform(uid: "device", device: 7, protectingMute: false) { _, _ in
            XCTFail("must keep the device protected"); return true
        })
    }

    func testAlreadyCorrectStateDoesNotRequireAWriteOrNotification() {
        XCTAssertTrue(CA.confirmWrite(isCurrent: { true }, matches: { true },
            subscribe: { _ in XCTFail("no pending write"); return nil },
            write: { XCTFail("already correct"); return false }))
    }

    func testDelayedAcknowledgementRequiresNotificationAndMatchingReadback() {
        var value = false
        var subscribed = false
        var removed = false
        var waits = 0
        XCTAssertTrue(CA.confirmWrite(isCurrent: { true }, matches: { value },
            subscribe: { _ in subscribed = true; return { removed = true } },
            write: { XCTAssertTrue(subscribed); return true },
            wait: { _, _ in
                waits += 1
                if waits == 2 { value = true }
                return true
            }))
        XCTAssertEqual(waits, 2, "first notification had stale readback")
        XCTAssertTrue(removed)
    }

    func testSetterSuccessAndChangedReadbackWithoutNotificationTimeOut() {
        var value = false
        var removed = false
        XCTAssertFalse(CA.confirmWrite(isCurrent: { true }, matches: { value },
            subscribe: { _ in { removed = true } },
            write: { value = true; return true }, wait: { _, _ in false }))
        XCTAssertTrue(removed)
    }

    func testStaleNotificationNeverAcknowledgesWrongValue() {
        var waits = 0
        XCTAssertFalse(CA.confirmWrite(isCurrent: { true }, matches: { false },
            subscribe: { _ in {} }, write: { true }, wait: { _, _ in
                waits += 1
                return waits == 1
            }))
        XCTAssertEqual(waits, 2)
    }

    func testIdentityChangeBeforeWriteAndDuringAcknowledgementFails() {
        var current = true
        XCTAssertFalse(CA.confirmWrite(isCurrent: { current }, matches: { false },
            subscribe: { _ in current = false; return {} },
            write: { XCTFail("replaced device"); return true }))
        current = true
        XCTAssertFalse(CA.confirmWrite(isCurrent: { current }, matches: { false },
            subscribe: { _ in {} }, write: { true }, wait: { _, _ in current = false; return true }))
        XCTAssertFalse(CA.confirmWrite(isCurrent: { false }, matches: { true },
            subscribe: { _ in XCTFail("unknown identity"); return nil }, write: { false }))
    }

    func testListenerAndSetterFailuresFailClosedAndRemoveListener() {
        XCTAssertFalse(CA.confirmWrite(isCurrent: { true }, matches: { false },
            subscribe: { _ in nil }, write: { XCTFail("no listener"); return true }))
        var removed = false
        XCTAssertFalse(CA.confirmWrite(isCurrent: { true }, matches: { false },
            subscribe: { _ in { removed = true } }, write: { false },
            wait: { _, _ in XCTFail("setter failed"); return true }))
        XCTAssertTrue(removed)
    }

    func testHardwareRoundingHasBoundedToleranceAndExactSafetyEndpoints() {
        XCTAssertTrue(CA.volumeMatches(0.121502, target: 0.12))
        XCTAssertFalse(CA.volumeMatches(0.15, target: 0.12))
        XCTAssertTrue(CA.volumeMatches(0.121502, target: 0.121502))
        XCTAssertFalse(CA.volumeMatches(0.001, target: 0))
        XCTAssertFalse(CA.volumeMatches(0.999, target: 1))
        XCTAssertFalse(CA.volumeMatches(0.0011, target: 0.001))
        XCTAssertFalse(CA.volumeMatches(nil, target: 0))
        XCTAssertFalse(CA.volumeMatches(.nan, target: 0.12))
    }

    func testQuantizedReadbackConfirmsLandingButNotSkipping() {
        XCTAssertFalse(CA.volumeMatches(0.164604, target: 0.166667))
        XCTAssertTrue(CA.volumeLanded(0.164604, target: 0.166667), "USB dB-step readback")
        XCTAssertTrue(CA.volumeLanded(0.1875, target: 0.166667), "1/16-step readback")
        XCTAssertFalse(CA.volumeLanded(0.25, target: 0.12))
        XCTAssertFalse(CA.volumeLanded(1, target: 0.12))
        XCTAssertFalse(CA.volumeLanded(0.001, target: 0))
        XCTAssertFalse(CA.volumeLanded(0.999, target: 1))
        XCTAssertFalse(CA.volumeLanded(nil, target: 0.12))
    }

    func testLandedReadbackAcceptsWriteThatMatchesLoosely() {
        var notify: (@Sendable () -> Void)?
        var volume: Float = 0
        XCTAssertTrue(CA.confirmWrite(isCurrent: { true },
            matches: { CA.volumeMatches(volume, target: 0.166667) },
            landed: { CA.volumeLanded(volume, target: 0.166667) },
            subscribe: { signal in notify = signal; return {} },
            write: { volume = 0.164604; notify?(); return true },
            wait: { signal, _ in signal.wait(timeout: .now()) == .success }))
    }

    func testUnconfirmedChannelVolumeNeverReleasesAnyMute() {
        let state = OutputDeviceState(uid: "device", deviceID: 7,
            volumes: [1: 0.12, 2: 0.25], mutes: [1: false, 2: false])
        var completed: [UInt32] = []
        XCTAssertEqual(CoreAudioEngine.writeDeviceState(state, current: state, restoreVolume: true, restoreMute: true,
            volume: { element, _ in
                if element == 1 { completed.append(element); return true }
                return CA.confirmWrite(isCurrent: { true }, matches: { false },
                    subscribe: { _ in {} }, write: { true }, wait: { _, _ in false })
            }, mute: { _, _ in XCTFail("unconfirmed volume must stay muted"); return true }), .failed)
        XCTAssertEqual(completed, [1])
    }

    func testPartialMuteRestoreReprotectsAllChannels() {
        let state = OutputDeviceState(uid: "device", deviceID: 7,
            volumes: [0: 0.12], mutes: [1: false, 2: false])
        var protected: [UInt32] = []
        XCTAssertEqual(CoreAudioEngine.writeDeviceState(state, current: state, restoreVolume: false, restoreMute: true,
            volume: { _, _ in true }, mute: { element, muted in
                if muted { protected.append(element); return true }
                return element == 1
            }), .failed)
        XCTAssertEqual(protected, [1, 2])
    }
}
