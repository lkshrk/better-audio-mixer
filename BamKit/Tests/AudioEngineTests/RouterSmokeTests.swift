import XCTest
import CoreAudio
import AudioToolbox
import BamCore
@testable import AudioEngine

/// Live Monitor-mix smoke: routes the muted remainder back to the default hardware output. Opt-in (`BAM_SMOKE=1`); verify by ear that bass and fidelity survive.
final class RouterSmokeTests: XCTestCase {
    func testRemainderMonitorsToHardwareLive() async throws {
        guard ProcessInfo.processInfo.environment["BAM_SMOKE"] == "1" else {
            throw XCTSkip("Set BAM_SMOKE=1 and play music to run the Monitor-mix smoke.")
        }
        guard let outUID = ProcessEnumerator.defaultOutputDeviceUID() else {
            throw XCTSkip("No default output device.")
        }

        let config = BamConfig(
            sources: [Source(id: "all", name: "Everything Else", kind: .rest)],
            mixes: [Mix(id: "mon", name: "Monitor", dest: .hardware(uid: outUID),
                        sends: [Send(source: "all")])],
            pans: ["all": 0.5]
        )
        let engine = CoreAudioEngine()
        try await startProtected(engine, config: config)

        print("MonitorSmoke: routing remainder → \(outUID). Music should stay full-fidelity for 10s.")
        try await Task.sleep(for: .seconds(10)) // listen now
    }
}
