// Step-3 driver gate: prove TWO claimed BAM virtual devices carry INDEPENDENT PCM.
// Claims slot0 + slot1 via plugin MixConfig, renders a distinct sine into each device's
// OUTPUT (440 Hz -> slot0, 660 Hz -> slot1), captures each device's INPUT, and uses a
// Goertzel detector to confirm each capture is dominated by ITS OWN tone with negligible
// bleed from the other device. Proves per-device ring buffers are truly independent.
//
// Build: swiftc -O loopcheck2.swift -o loopcheck2 -framework CoreAudio -framework AudioToolbox -framework Foundation
// Run:   ./loopcheck2            (BAM.driver installed)
import AudioToolbox
import CoreAudio
import Foundation
import Darwin

let bundleID = "me.harke.bam.driver"
let sampleRate = 48000.0
let channels: UInt32 = 2
let freq0 = 440.0   // slot 0 tone
let freq1 = 660.0   // slot 1 tone

// ---- plugin claim plumbing (mirrors mixcfgcheck.swift) ----
func fourCC(_ s: String) -> AudioObjectPropertySelector {
    var r: UInt32 = 0
    for b in s.utf8 { r = (r << 8) | UInt32(b) }
    return r
}
let kMixConfig = fourCC("bmcf")

func gAddr(_ sel: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
}

func findPlugIn() -> AudioObjectID? {
    var a = gAddr(kAudioHardwarePropertyTranslateBundleIDToPlugIn)
    var cf = bundleID as CFString
    var pid: AudioObjectID = 0
    var s = UInt32(MemoryLayout<AudioObjectID>.size)
    let q = UInt32(MemoryLayout<CFString>.size)
    let st = withUnsafeMutablePointer(to: &cf) { qp -> OSStatus in
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, q, qp, &s, &pid)
    }
    return (st == noErr && pid != 0) ? pid : nil
}

func mixEntry(slot: Int, name: String) -> CFDictionary {
    var s = slot, c = 1, ch = 2
    let d: [CFString: CFTypeRef] = [
        "slot" as CFString: CFNumberCreate(nil, .sInt32Type, &s),
        "claimed" as CFString: CFNumberCreate(nil, .sInt32Type, &c),
        "name" as CFString: name as CFString,
        "channels" as CFString: CFNumberCreate(nil, .sInt32Type, &ch),
    ]
    return d as CFDictionary
}

func setConfig(_ plugin: AudioObjectID, _ entries: [CFDictionary]) -> OSStatus {
    var a = gAddr(kMixConfig)
    var arr = entries as CFArray
    return withUnsafeMutablePointer(to: &arr) { p in
        AudioObjectSetPropertyData(plugin, &a, 0, nil, UInt32(MemoryLayout<CFArray>.size), p)
    }
}

func findDevice(uid: String) -> AudioObjectID? {
    var addr = gAddr(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return nil }
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    var ids = [AudioObjectID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return nil }
    for id in ids {
        var ua = gAddr(kAudioDevicePropertyDeviceUID); var cf: Unmanaged<CFString>?
        var s = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        if AudioObjectGetPropertyData(id, &ua, 0, nil, &s, &cf) == noErr, (cf?.takeRetainedValue() as String?) == uid { return id }
    }
    return nil
}

func waitForDevice(uid: String, timeoutMs: Int = 5000) -> AudioObjectID? {
    var elapsed = 0
    while elapsed <= timeoutMs {
        if let id = findDevice(uid: uid) { return id }
        usleep(100_000); elapsed += 100
    }
    return nil
}

// ---- AUHAL render/capture ----
func makeASBD() -> AudioStreamBasicDescription {
    AudioStreamBasicDescription(
        mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 4 * channels, mFramesPerPacket: 1, mBytesPerFrame: 4 * channels,
        mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
}

func makeHAL(deviceID: AudioObjectID, input: Bool) -> AudioUnit? {
    var desc = AudioComponentDescription(
        componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
    guard let comp = AudioComponentFindNext(nil, &desc) else { return nil }
    var unit: AudioUnit?
    guard AudioComponentInstanceNew(comp, &unit) == noErr, let unit else { return nil }
    var enableIn: UInt32 = input ? 1 : 0
    var enableOut: UInt32 = input ? 0 : 1
    AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enableIn, 4)
    AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enableOut, 4)
    var dev = deviceID
    AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, 4)
    var asbd = makeASBD()
    if input {
        AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &asbd, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
    } else {
        AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &asbd, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
    }
    return unit
}

// Per-device state: render phase at its own freq + two Goertzel detectors (440, 660).
final class DevState {
    let renderFreq: Double
    var phase: Double = 0
    // Goertzel running state for each target.
    var s1_440 = 0.0, s2_440 = 0.0
    var s1_660 = 0.0, s2_660 = 0.0
    let coeff440 = 2.0 * cos(2.0 * Double.pi * freq0 / sampleRate)
    let coeff660 = 2.0 * cos(2.0 * Double.pi * freq1 / sampleRate)
    var sampleCount = 0
    var sumSquares = 0.0
    var inputUnit: AudioUnit?
    init(renderFreq: Double) { self.renderFreq = renderFreq }

    func feed(_ x: Double) {
        let s0a = x + coeff440 * s1_440 - s2_440; s2_440 = s1_440; s1_440 = s0a
        let s0b = x + coeff660 * s1_660 - s2_660; s2_660 = s1_660; s1_660 = s0b
        sumSquares += x * x; sampleCount += 1
    }
    var power440: Double { s1_440*s1_440 + s2_440*s2_440 - coeff440*s1_440*s2_440 }
    var power660: Double { s1_660*s1_660 + s2_660*s2_660 - coeff660*s1_660*s2_660 }
    var rms: Double { sampleCount > 0 ? (sumSquares / Double(sampleCount)).squareRoot() : 0 }
}

let renderCB: AURenderCallback = { ctx, _, _, _, frames, ioData in
    let st = Unmanaged<DevState>.fromOpaque(ctx).takeUnretainedValue()
    guard let abl = ioData else { return noErr }
    let buffers = UnsafeMutableAudioBufferListPointer(abl)
    let inc = 2.0 * Double.pi * st.renderFreq / sampleRate
    for i in 0..<Int(frames) {
        let v = Float(sin(st.phase) * 0.5)
        st.phase += inc
        if st.phase > 2 * .pi { st.phase -= 2 * .pi }
        for b in buffers { b.mData!.assumingMemoryBound(to: Float.self)[i] = v }
    }
    return noErr
}

let inputCB: AURenderCallback = { ctx, flags, ts, bus, frames, _ in
    let st = Unmanaged<DevState>.fromOpaque(ctx).takeUnretainedValue()
    guard let unit = st.inputUnit else { return noErr }
    var abl = AudioBufferList(mNumberBuffers: 1,
        mBuffers: AudioBuffer(mNumberChannels: channels, mDataByteSize: frames * 4 * channels, mData: nil))
    let buf = malloc(Int(frames * 4 * channels))!
    abl.mBuffers.mData = buf
    defer { free(buf) }
    if AudioUnitRender(unit, UnsafeMutablePointer(mutating: flags), ts, bus, frames, &abl) == noErr {
        let p = buf.assumingMemoryBound(to: Float.self)
        // Channel 0 only (interleaved stereo).
        var i = 0
        while i < Int(frames * channels) { st.feed(Double(p[i])); i += Int(channels) }
    }
    return noErr
}

// ---- run ----
guard let plugin = findPlugIn() else {
    FileHandle.standardError.write("FAIL: BAM plugin not found.\n".data(using: .utf8)!); exit(2)
}
let cfg = setConfig(plugin, [mixEntry(slot: 0, name: "Stream"), mixEntry(slot: 1, name: "Chat")])
guard cfg == noErr else { FileHandle.standardError.write("FAIL: setConfig status=\(cfg)\n".data(using: .utf8)!); exit(2) }

guard let dev0 = waitForDevice(uid: "BAM_UID_0"), let dev1 = waitForDevice(uid: "BAM_UID_1") else {
    FileHandle.standardError.write("FAIL: claimed devices did not publish.\n".data(using: .utf8)!)
    _ = setConfig(plugin, []); exit(2)
}
print("Claimed dev0(BAM_UID_0)=\(dev0) dev1(BAM_UID_1)=\(dev1)")

let st0 = DevState(renderFreq: freq0)
let st1 = DevState(renderFreq: freq1)

func wire(_ st: DevState, _ dev: AudioObjectID) -> Bool {
    guard let outU = makeHAL(deviceID: dev, input: false), let inU = makeHAL(deviceID: dev, input: true) else { return false }
    st.inputUnit = inU
    let ctx = Unmanaged.passUnretained(st).toOpaque()
    var rcb = AURenderCallbackStruct(inputProc: renderCB, inputProcRefCon: ctx)
    AudioUnitSetProperty(outU, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &rcb, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
    var icb = AURenderCallbackStruct(inputProc: inputCB, inputProcRefCon: ctx)
    AudioUnitSetProperty(inU, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &icb, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
    guard AudioUnitInitialize(outU) == noErr, AudioUnitInitialize(inU) == noErr else { return false }
    guard AudioOutputUnitStart(inU) == noErr, AudioOutputUnitStart(outU) == noErr else { return false }
    return true
}

guard wire(st0, dev0), wire(st1, dev1) else {
    FileHandle.standardError.write("FAIL: could not wire HAL units.\n".data(using: .utf8)!)
    _ = setConfig(plugin, []); exit(3)
}

Thread.sleep(forTimeInterval: 2.0)

// Unclaim before reporting (leave the system clean).
_ = setConfig(plugin, [])

func report(_ name: String, _ st: DevState) -> Bool {
    // dominant = power at own tone; bleed = power at the other device's tone.
    let own = st.renderFreq == freq0 ? st.power440 : st.power660
    let bleed = st.renderFreq == freq0 ? st.power660 : st.power440
    let ratio = bleed > 0 ? own / bleed : Double.infinity
    print(String(format: "%@: rms=%.4f ownTonePow=%.1f otherTonePow=%.1f ratio=%.1f", name, st.rms, own, bleed, ratio))
    return st.rms > 0.01 && ratio > 5.0
}

let ok0 = report("dev0(440)", st0)
let ok1 = report("dev1(660)", st1)

if ok0 && ok1 {
    print("PASS: each BAM device carries its OWN tone with no cross-bleed — per-device PCM is independent.")
    exit(0)
} else {
    print("FAIL: device PCM not independent (silent capture or cross-bleed between rings).")
    exit(1)
}
