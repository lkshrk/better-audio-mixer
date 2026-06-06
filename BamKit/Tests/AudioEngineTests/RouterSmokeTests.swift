import XCTest
import CoreAudio
import AudioToolbox
import BamCore
@testable import AudioEngine

/// Live end-to-end smoke: routes the "Everything Else" remainder source to a
/// claimed BAM device via the real `CoreAudioEngine.startRouter`, then captures
/// that device and reports RMS. Opt-in (set `BAM_SMOKE=1`) and meant to be run
/// while system audio is playing — confirms real app audio reaches a BAM
/// virtual device through the full router. Quality is verified by ear.
final class RouterSmokeTests: XCTestCase {
    private let bundleID = "me.harke.bam.driver"
    private let sr = 48_000.0

    private func fourCC(_ s: String) -> AudioObjectPropertySelector {
        var r: UInt32 = 0; for b in s.utf8 { r = (r << 8) | UInt32(b) }; return r
    }
    private func gAddr(_ sel: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }
    private func findPlugIn() -> AudioObjectID? {
        var a = gAddr(kAudioHardwarePropertyTranslateBundleIDToPlugIn)
        var cf = bundleID as CFString
        var pid = AudioObjectID(0)
        var s = UInt32(MemoryLayout<AudioObjectID>.size)
        let q = UInt32(MemoryLayout<CFString>.size)
        let st = withUnsafeMutablePointer(to: &cf) { qp in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, q, qp, &s, &pid)
        }
        return (st == noErr && pid != 0) ? pid : nil
    }
    private func setConfig(_ plugin: AudioObjectID, _ entries: [CFDictionary]) -> OSStatus {
        var a = gAddr(fourCC("bmcf"))
        var arr = entries as CFArray
        return withUnsafeMutablePointer(to: &arr) { p in
            AudioObjectSetPropertyData(plugin, &a, 0, nil, UInt32(MemoryLayout<CFArray>.size), p)
        }
    }
    private func claimSlot0(_ plugin: AudioObjectID) -> OSStatus {
        var sl = 0, c = 1, ch = 2
        let entry: [CFString: CFTypeRef] = [
            "slot" as CFString: CFNumberCreate(nil, .sInt32Type, &sl),
            "claimed" as CFString: CFNumberCreate(nil, .sInt32Type, &c),
            "name" as CFString: "Smoke" as CFString,
            "channels" as CFString: CFNumberCreate(nil, .sInt32Type, &ch),
        ]
        return setConfig(plugin, [entry as CFDictionary])
    }

    private final class Capture {
        var unit: AudioUnit?
        var samples = 0, sumSq = 0.0, peak = 0.0
        var rms: Double { samples > 0 ? (sumSq / Double(samples)).squareRoot() : 0 }
    }
    private let captureCB: AURenderCallback = { ctx, flags, ts, bus, frames, _ in
        let cap = Unmanaged<Capture>.fromOpaque(ctx).takeUnretainedValue()
        guard let unit = cap.unit else { return noErr }
        var abl = AudioBufferList(mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: frames * 4 * 2, mData: nil))
        let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(frames) * 4 * 2, alignment: 16)
        defer { buf.deallocate() }
        abl.mBuffers.mData = buf
        guard AudioUnitRender(unit, UnsafeMutablePointer(mutating: flags), ts, bus, frames, &abl) == noErr
        else { return noErr }
        let p = buf.assumingMemoryBound(to: Float.self)
        for i in 0..<Int(frames) * 2 {
            let v = Double(p[i]); cap.sumSq += v * v; cap.peak = max(cap.peak, abs(v))
        }
        cap.samples += Int(frames) * 2
        return noErr
    }
    private func makeCapture(deviceID: AudioObjectID, cap: Capture) -> AudioUnit? {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { return nil }
        var u: AudioUnit?
        guard AudioComponentInstanceNew(comp, &u) == noErr, let u else { return nil }
        var enIn: UInt32 = 1, enOut: UInt32 = 0
        AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enIn, 4)
        AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enOut, 4)
        var dev = deviceID
        AudioUnitSetProperty(u, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, 4)
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sr, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
                             &asbd, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        var cb = AURenderCallbackStruct(inputProc: captureCB,
                                        inputProcRefCon: Unmanaged.passUnretained(cap).toOpaque())
        AudioUnitSetProperty(u, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                             &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard AudioUnitInitialize(u) == noErr else { return nil }
        cap.unit = u
        return u
    }

    func testRemainderRoutesToBAMDeviceLive() async throws {
        guard ProcessInfo.processInfo.environment["BAM_SMOKE"] == "1" else {
            throw XCTSkip("Set BAM_SMOKE=1 and play system audio to run the live router smoke.")
        }
        guard let plugin = findPlugIn() else { throw XCTSkip("BAM driver not installed.") }
        XCTAssertEqual(claimSlot0(plugin), noErr)
        defer { _ = setConfig(plugin, []) }
        // Wait for publication.
        var tries = 0
        while ProcessEnumerator.deviceID(forUID: "BAM_UID_0") == nil, tries < 50 {
            usleep(100_000); tries += 1
        }
        guard let dev = ProcessEnumerator.deviceID(forUID: "BAM_UID_0") else {
            return XCTFail("BAM_UID_0 not published")
        }

        let config = BamConfig(
            sources: [Source(id: "all", name: "Everything Else", kind: .rest)],
            mixes: [Mix(id: "m0", name: "Mix0", dest: .virtualSlot(0),
                        sends: [Send(source: "all")])],
            pans: ["all": 0.5]
        )
        let engine = CoreAudioEngine()
        let failed = await engine.startRouter(config: config).failedMixIDs
        XCTAssertTrue(failed.isEmpty, "router failed mixes: \(failed)")
        defer { Task { await engine.stopRouter() } }

        let cap = Capture()
        guard let u = makeCapture(deviceID: dev, cap: cap) else { return XCTFail("capture failed") }
        XCTAssertEqual(AudioOutputUnitStart(u), noErr)
        try await Task.sleep(for: .seconds(3)) // play audio now
        AudioOutputUnitStop(u); AudioUnitUninitialize(u); AudioComponentInstanceDispose(u)

        print("RouterSmoke BAM_UID_0: rms=\(cap.rms) peak=\(cap.peak) samples=\(cap.samples)")
        XCTAssertGreaterThan(cap.rms, 0.0005,
            "No audio captured on BAM_UID_0 — was system audio playing during the 3s window?")
    }

    /// Monitor-mix roundtrip: routes the muted "Everything Else" remainder back to
    /// the default hardware output. Capture taps run `.mutedWhenTapped`, so the
    /// app's original output is silenced and the only audible path is the router →
    /// Monitor mix → speakers. Verifies by ear that audio stays full-fidelity
    /// (bass intact, no SRC) and that mute+monitor roundtrips without dropout.
    /// Opt-in (`BAM_SMOKE=1`); play music during the 10s window.
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
        let failed = await engine.startRouter(config: config).failedMixIDs
        XCTAssertTrue(failed.isEmpty, "Monitor mix failed to open hardware \(outUID): \(failed)")
        defer { Task { await engine.stopRouter() } }

        print("MonitorSmoke: routing remainder → \(outUID). Music should stay full-fidelity for 10s.")
        try await Task.sleep(for: .seconds(10)) // listen now
    }
}
