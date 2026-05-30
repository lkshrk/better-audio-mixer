// Spike gate: prove BAM virtual device round-trips PCM.
// Plays a 440 Hz sine into the BAM device's OUTPUT, simultaneously captures the
// device's INPUT, and reports RMS for each. Nonzero capture RMS == loopback works.
//
// Build: swiftc -O loopcheck.swift -o loopcheck -framework CoreAudio -framework AudioToolbox
// Run:   ./loopcheck            (BAM.driver must be installed)
import AudioToolbox
import CoreAudio
import Darwin

let targetUID = "BAM_UID"
let sampleRate = 48000.0
let channels: UInt32 = 2

func findDevice(uid: String) -> AudioObjectID? {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return nil }
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    var ids = [AudioObjectID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return nil }
    for id in ids {
        var uidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var cfUID: Unmanaged<CFString>?
        var s = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &uidAddr, 0, nil, &s, &cfUID) == noErr,
              let got = cfUID?.takeRetainedValue() as String? else { continue }
        if got == uid { return id }
    }
    return nil
}

func makeASBD() -> AudioStreamBasicDescription {
    AudioStreamBasicDescription(
        mSampleRate: sampleRate,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 4 * channels,
        mFramesPerPacket: 1,
        mBytesPerFrame: 4 * channels,
        mChannelsPerFrame: channels,
        mBitsPerChannel: 32,
        mReserved: 0)
}

func makeHAL(deviceID: AudioObjectID, input: Bool) -> AudioUnit? {
    var desc = AudioComponentDescription(
        componentType: kAudioUnitType_Output,
        componentSubType: kAudioUnitSubType_HALOutput,
        componentManufacturer: kAudioUnitManufacturer_Apple,
        componentFlags: 0, componentFlagsMask: 0)
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

// Shared phase + capture accumulator.
final class State {
    var phase: Double = 0
    var sumSquares: Double = 0
    var count: Int = 0
    var outFrames: Int = 0
}
let state = State()

let renderCB: AURenderCallback = { ctx, _, _, _, frames, ioData in
    let st = Unmanaged<State>.fromOpaque(ctx).takeUnretainedValue()
    guard let abl = ioData else { return noErr }
    let buffers = UnsafeMutableAudioBufferListPointer(abl)
    let inc = 2.0 * Double.pi * 440.0 / sampleRate
    for i in 0..<Int(frames) {
        let v = Float(sin(st.phase) * 0.5)
        st.phase += inc
        if st.phase > 2 * .pi { st.phase -= 2 * .pi }
        for b in buffers {
            let p = b.mData!.assumingMemoryBound(to: Float.self)
            p[i] = v
        }
    }
    st.outFrames += Int(frames)
    return noErr
}

var inputUnit: AudioUnit?
let inputCB: AURenderCallback = { ctx, flags, ts, bus, frames, _ in
    let st = Unmanaged<State>.fromOpaque(ctx).takeUnretainedValue()
    guard let unit = inputUnit else { return noErr }
    var abl = AudioBufferList(
        mNumberBuffers: 1,
        mBuffers: AudioBuffer(mNumberChannels: channels, mDataByteSize: frames * 4 * channels, mData: nil))
    let buf = malloc(Int(frames * 4 * channels))!
    abl.mBuffers.mData = buf
    defer { free(buf) }
    let st2 = AudioUnitRender(unit, UnsafeMutablePointer(mutating: flags), ts, bus, frames, &abl)
    if st2 == noErr {
        let p = buf.assumingMemoryBound(to: Float.self)
        let n = Int(frames * channels)
        for i in 0..<n { let s = Double(p[i]); st.sumSquares += s * s; st.count += 1 }
    }
    return noErr
}

guard let dev = findDevice(uid: targetUID) else {
    FileHandle.standardError.write("FAIL: device UID \(targetUID) not found. Is BAM.driver installed?\n".data(using: .utf8)!)
    exit(2)
}
print("Found BAM device id=\(dev)")

guard let outUnit = makeHAL(deviceID: dev, input: false),
      let inUnit = makeHAL(deviceID: dev, input: true) else {
    FileHandle.standardError.write("FAIL: could not create HAL units\n".data(using: .utf8)!)
    exit(3)
}
inputUnit = inUnit

let ctx = Unmanaged.passUnretained(state).toOpaque()
var rcb = AURenderCallbackStruct(inputProc: renderCB, inputProcRefCon: ctx)
AudioUnitSetProperty(outUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &rcb, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
var icb = AURenderCallbackStruct(inputProc: inputCB, inputProcRefCon: ctx)
AudioUnitSetProperty(inUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &icb, UInt32(MemoryLayout<AURenderCallbackStruct>.size))

guard AudioUnitInitialize(outUnit) == noErr, AudioUnitInitialize(inUnit) == noErr else {
    FileHandle.standardError.write("FAIL: AudioUnitInitialize\n".data(using: .utf8)!)
    exit(4)
}
guard AudioOutputUnitStart(inUnit) == noErr, AudioOutputUnitStart(outUnit) == noErr else {
    FileHandle.standardError.write("FAIL: AudioOutputUnitStart\n".data(using: .utf8)!)
    exit(5)
}

Thread.sleep(forTimeInterval: 2.0)
AudioOutputUnitStop(outUnit)
AudioOutputUnitStop(inUnit)

let rms = state.count > 0 ? (state.sumSquares / Double(state.count)).squareRoot() : 0
print("played frames=\(state.outFrames) captured samples=\(state.count) captureRMS=\(rms)")
if rms > 0.01 {
    print("PASS: BAM loopback works — captured the sine written to the device.")
    exit(0)
} else {
    print("FAIL: capture silent — device not round-tripping PCM.")
    exit(1)
}
