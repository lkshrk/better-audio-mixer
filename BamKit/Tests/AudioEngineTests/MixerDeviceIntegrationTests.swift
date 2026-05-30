import XCTest
import CoreAudio
import AudioToolbox
@testable import AudioEngine

/// End-to-end on-device proof: synthetic tones → RingBuffer → Mixer →
/// VirtualDeviceClient → claimed BAM device → AUHAL capture → Goertzel.
/// Verifies each mix carries ONLY its routed source's tone (routing +
/// per-device independence through the real Swift engine). Requires the BAM
/// driver installed; skips otherwise so CI without the driver stays green.
final class MixerDeviceIntegrationTests: XCTestCase {
    private let bundleID = "me.harke.bam.driver"
    private let sr = 48_000.0
    private let freq0 = 440.0
    private let freq1 = 660.0

    private func fourCC(_ s: String) -> AudioObjectPropertySelector {
        var r: UInt32 = 0; for b in s.utf8 { r = (r << 8) | UInt32(b) }; return r
    }
    private func gAddr(_ sel: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    /// True if a `bam` (or `bam dev`) menu-bar app is running. Such a process
    /// holds the BAM device outputs and would contend with this test's loopback.
    private func bamAppRunning() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-x", "bam"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        return p.terminationStatus == 0 && !out.isEmpty
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

    private func mixEntry(slot: Int, claimed: Int, name: String, channels: Int) -> CFDictionary {
        var sl = slot, c = claimed, ch = channels
        let d: [CFString: CFTypeRef] = [
            "slot" as CFString: CFNumberCreate(nil, .sInt32Type, &sl),
            "claimed" as CFString: CFNumberCreate(nil, .sInt32Type, &c),
            "name" as CFString: name as CFString,
            "channels" as CFString: CFNumberCreate(nil, .sInt32Type, &ch),
        ]
        return d as CFDictionary
    }

    private func setConfig(_ plugin: AudioObjectID, _ entries: [CFDictionary]) -> OSStatus {
        var a = gAddr(fourCC("bmcf"))
        var arr = entries as CFArray
        return withUnsafeMutablePointer(to: &arr) { p in
            AudioObjectSetPropertyData(plugin, &a, 0, nil, UInt32(MemoryLayout<CFArray>.size), p)
        }
    }

    private func devicePresent(_ uid: String) -> Bool {
        VirtualDeviceClient.deviceID(forUID: uid) != nil
    }

    private func waitFor(_ uid: String, present want: Bool, timeoutMs: Int = 5000) -> Bool {
        var e = 0
        while e <= timeoutMs { if devicePresent(uid) == want { return true }; usleep(100_000); e += 100 }
        return false
    }

    // Capture side: one AUHAL input unit + Goertzel state.
    private final class Capture {
        var unit: AudioUnit?
        var s1_440 = 0.0, s2_440 = 0.0, s1_660 = 0.0, s2_660 = 0.0
        let c440: Double, c660: Double
        var samples = 0, sumSq = 0.0
        let sr: Double
        init(sr: Double, f0: Double, f1: Double) {
            self.sr = sr
            c440 = 2.0 * cos(2.0 * .pi * f0 / sr)
            c660 = 2.0 * cos(2.0 * .pi * f1 / sr)
        }
        func feed(_ x: Double) {
            let a = x + c440 * s1_440 - s2_440; s2_440 = s1_440; s1_440 = a
            let b = x + c660 * s1_660 - s2_660; s2_660 = s1_660; s1_660 = b
            sumSq += x * x; samples += 1
        }
        var p440: Double { s1_440*s1_440 + s2_440*s2_440 - c440*s1_440*s2_440 }
        var p660: Double { s1_660*s1_660 + s2_660*s2_660 - c660*s1_660*s2_660 }
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
        let st = AudioUnitRender(unit, UnsafeMutablePointer(mutating: flags), ts, bus, frames, &abl)
        guard st == noErr else { return noErr }
        let p = buf.assumingMemoryBound(to: Float.self)
        for i in 0..<Int(frames) { cap.feed(Double(p[i * 2])) } // left channel
        return noErr
    }

    private func makeCaptureUnit(deviceID: AudioObjectID, cap: Capture) -> AudioUnit? {
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

    func testTwoMixesRouteIndependentTonesThroughEngine() throws {
        guard let plugin = findPlugIn() else {
            throw XCTSkip("BAM driver not installed — skipping on-device integration test.")
        }
        // The running app drives the same BAM device output; a second writer on the
        // device breaks the loopback. This test needs exclusive driver access.
        if bamAppRunning() {
            throw XCTSkip("bam is running — quit it so the integration test can own the BAM devices.")
        }
        let uid0 = "BAM_UID_0", uid1 = "BAM_UID_1"
        // Claim two slots.
        XCTAssertEqual(setConfig(plugin, [
            mixEntry(slot: 0, claimed: 1, name: "Stream", channels: 2),
            mixEntry(slot: 1, claimed: 1, name: "Chat", channels: 2),
        ]), noErr)
        XCTAssertTrue(waitFor(uid0, present: true), "BAM_UID_0 not published")
        XCTAssertTrue(waitFor(uid1, present: true), "BAM_UID_1 not published")
        defer { _ = setConfig(plugin, []) }

        // Engine: tone0→mix0 (dev0), tone1→mix1 (dev1).
        let mixer = Mixer(channels: 2, sampleRate: sr, slackMs: 85, maxFrames: 4096)
        let ring0 = mixer.ring(for: "tone0")
        let ring1 = mixer.ring(for: "tone1")
        let failed = mixer.configure(mixes: [
            MixSpec(id: "mix0", destUID: uid0, master: 1,
                    sends: [MixSendSpec(sourceID: "tone0", level: 1, muted: false)]),
            MixSpec(id: "mix1", destUID: uid1, master: 1,
                    sends: [MixSendSpec(sourceID: "tone1", level: 1, muted: false)]),
        ], pans: ["tone0": 0.5, "tone1": 0.5], solo: nil)
        XCTAssertTrue(failed.isEmpty, "mix destinations failed to open: \(failed)")
        defer { mixer.stop() }

        // Feed each ring its tone from a background writer.
        let stop = ManagedAtomicBox()
        let inc0 = 2.0 * .pi * freq0 / sr
        let inc1 = 2.0 * .pi * freq1 / sr
        let writer = Thread {
            var ph0 = 0.0, ph1 = 0.0
            let block = 512
            var b0 = [Float](repeating: 0, count: block * 2)
            var b1 = [Float](repeating: 0, count: block * 2)
            while !stop.value {
                for f in 0..<block {
                    let v0 = Float(sin(ph0) * 0.5); ph0 += inc0; if ph0 > 2 * .pi { ph0 -= 2 * .pi }
                    let v1 = Float(sin(ph1) * 0.5); ph1 += inc1; if ph1 > 2 * .pi { ph1 -= 2 * .pi }
                    b0[f*2] = v0; b0[f*2+1] = v0
                    b1[f*2] = v1; b1[f*2+1] = v1
                }
                b0.withUnsafeBufferPointer { ring0.write($0.baseAddress!, frames: block) }
                b1.withUnsafeBufferPointer { ring1.write($0.baseAddress!, frames: block) }
                usleep(5_000) // ~240 frames @ 48k; stay ahead of the readers
            }
        }
        writer.start()
        defer { stop.value = true }

        // Capture each device.
        let cap0 = Capture(sr: sr, f0: freq0, f1: freq1)
        let cap1 = Capture(sr: sr, f0: freq0, f1: freq1)
        guard let dev0 = VirtualDeviceClient.deviceID(forUID: uid0),
              let dev1 = VirtualDeviceClient.deviceID(forUID: uid1),
              let u0 = makeCaptureUnit(deviceID: dev0, cap: cap0),
              let u1 = makeCaptureUnit(deviceID: dev1, cap: cap1) else {
            return XCTFail("capture units failed")
        }
        XCTAssertEqual(AudioOutputUnitStart(u0), noErr)
        XCTAssertEqual(AudioOutputUnitStart(u1), noErr)
        usleep(800_000) // settle + accumulate
        AudioOutputUnitStop(u0); AudioOutputUnitStop(u1)
        AudioUnitUninitialize(u0); AudioUnitUninitialize(u1)
        AudioComponentInstanceDispose(u0); AudioComponentInstanceDispose(u1)

        // dev0 must carry 440 (own) ≫ 660 (other); dev1 the reverse.
        XCTAssertGreaterThan(cap0.rms, 0.01, "dev0 silent")
        XCTAssertGreaterThan(cap1.rms, 0.01, "dev1 silent")
        let r0 = cap0.p440 / max(cap0.p660, 1e-9)
        let r1 = cap1.p660 / max(cap1.p440, 1e-9)
        XCTAssertGreaterThan(r0, 5.0, "dev0 cross-bleed")
        XCTAssertGreaterThan(r1, 5.0, "dev1 cross-bleed")
    }
}

/// Tiny thread-safe bool flag for the writer thread.
private final class ManagedAtomicBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _v = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _v }
        set { lock.lock(); _v = newValue; lock.unlock() }
    }
}
