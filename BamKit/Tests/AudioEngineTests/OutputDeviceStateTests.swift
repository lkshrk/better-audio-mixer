import XCTest
import BamCore
import CoreAudio
@testable import AudioEngine

final class OutputDeviceStateTests: XCTestCase {
    func testMasterVolumeUsesCalibrationAcrossZeroAndCapsCommonGainAtHeadroom() {
        let calibration = OutputDeviceState(uid: "output", deviceID: 17,
            volumes: [1: 0.2, 2: 0.8, 3: 0.1, 4: 0.5], mutes: [0: false])
        let silent = calibration.withVolume(0)
        XCTAssertEqual(silent.volumes, [1: 0, 2: 0, 3: 0, 4: 0])
        let raised = calibration.withVolume(0.2)
        for (element, expected) in [UInt32(1): Float(0.1), 2: 0.4, 3: 0.05, 4: 0.25] {
            XCTAssertEqual(raised.volumes[element]!, expected, accuracy: 0.000001)
        }
        let ceiling = calibration.withVolume(1)
        XCTAssertEqual(ceiling.volumes, [1: 0.25, 2: 1, 3: 0.125, 4: 0.625])
        XCTAssertEqual(ceiling.mutes, calibration.mutes)
        XCTAssertEqual(calibration.withVolume(.nan), calibration)
        XCTAssertEqual(silent.withVolume(0.3).volumes, [1: 0.3, 2: 0.3, 3: 0.3, 4: 0.3])
    }

    func testCaptureAndRestorePreserveAllChannelCalibrationAndPartialMute() throws {
        let originalVolumes: [UInt32: Float] = [1: 0.2, 2: 0.8, 3: 0.35, 4: 0.6]
        let originalMutes: [UInt32: Bool] = [1: false, 2: true, 3: false, 4: true]
        let state = try XCTUnwrap(CoreAudioEngine.captureDeviceState(
            uid: "output", deviceID: 17, channels: 4,
            volume: { originalVolumes[$0] }, mute: { originalMutes[$0] },
            settable: { _, element in element > 0 && element <= 4 }))
        XCTAssertEqual(state.volumes, originalVolumes)
        XCTAssertEqual(state.mutes, originalMutes)
        XCTAssertFalse(state.muted, "partially muted hardware must have exact states restored")
        var current = state
        current.volumes = current.volumes.mapValues { _ in 0 }
        current.mutes = current.mutes.mapValues { _ in true }
        var volumes: [UInt32: Float] = [:]
        var mutes: [UInt32: Bool] = [:]
        let result = CoreAudioEngine.writeDeviceState(state, current: current, restoreVolume: true, restoreMute: true,
            volume: { volumes[$0] = $1; return true },
            mute: { element, value in
                XCTAssertEqual(volumes, originalVolumes, "all calibrated volumes precede every mute release")
                mutes[element] = value
                return true
            })
        XCTAssertEqual(result, .applied)
        XCTAssertEqual(volumes, originalVolumes)
        XCTAssertEqual(mutes, originalMutes)
    }

    func testMainVolumeAndChannelMuteUseIndependentElementSets() throws {
        let state = try XCTUnwrap(CoreAudioEngine.captureDeviceState(
            uid: "output", deviceID: 17, channels: 2,
            volume: { $0 == 0 ? 0.4 : nil }, mute: { $0 == 2 },
            settable: { selector, element in selector == kAudioDevicePropertyVolumeScalar ? element == 0 : element > 0 }))
        XCTAssertEqual(state.volumes, [0: 0.4])
        XCTAssertEqual(state.mutes, [1: false, 2: true])
    }

    func testIncompleteCaptureCannotAuthorizeMutation() {
        XCTAssertNil(CoreAudioEngine.captureDeviceState(uid: "output", deviceID: 17, channels: 4,
            volume: { $0 < 3 ? 0.4 : nil }, mute: { _ in false }, settable: { _, element in element > 0 }))
        XCTAssertNil(CoreAudioEngine.captureDeviceState(uid: "output", deviceID: 17, channels: 2,
            volume: { _ in .nan }, mute: { _ in false }, settable: { _, _ in true }))
    }

    func testChangedIdentityShapeAndInvalidValuesFailBeforeAnyWrite() {
        let state = OutputDeviceState(uid: "output", deviceID: 17, volumes: [1: 0.2, 2: 0.8], mutes: [0: false])
        var missing = state
        missing.volumes[2] = nil
        let replacement = OutputDeviceState(uid: "output", deviceID: 18, volumes: state.volumes, mutes: state.mutes)
        for current in [missing, replacement] {
            XCTAssertEqual(CoreAudioEngine.writeDeviceState(state, current: current, restoreVolume: true, restoreMute: true,
                volume: { _, _ in XCTFail("must not write"); return true },
                mute: { _, _ in XCTFail("must not unmute"); return true }), .failed)
        }
        var invalid = state
        invalid.volumes[1] = .infinity
        XCTAssertEqual(CoreAudioEngine.writeDeviceState(invalid, current: state, restoreVolume: true, restoreMute: true,
            volume: { _, _ in XCTFail("must not write"); return true },
            mute: { _, _ in XCTFail("must not unmute"); return true }), .failed)
    }

    func testFailedVolumeRestoreNeverUnmutes() {
        let state = OutputDeviceState(uid: "output", deviceID: 17, volumes: [1: 0.2, 2: 0.8], mutes: [0: false])
        XCTAssertEqual(CoreAudioEngine.writeDeviceState(state, current: state, restoreVolume: true, restoreMute: true,
            volume: { _, _ in false }, mute: { _, _ in XCTFail("must stay protected"); return true }), .failed)
    }
}
