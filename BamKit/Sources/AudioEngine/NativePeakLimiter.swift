import AudioToolbox

/// Single-render-thread owner. Construct, reset, and destroy only while rendering is quiescent.
final class NativePeakLimiter {
    private var unit: AudioUnit?
    private let maximumFrames: Int
    private let inputLeft: UnsafeMutablePointer<Float>
    private let inputRight: UnsafeMutablePointer<Float>
    private let outputLeft: UnsafeMutablePointer<Float>
    private let outputRight: UnsafeMutablePointer<Float>
    private let buffers: UnsafeMutableAudioBufferListPointer
    private var sampleTime = 0.0
    private var inputFrames = 0
    private(set) var delayFrames = 0
    private(set) var guardedSamples: UInt64 = 0
    private(set) var renderFailures: UInt64 = 0
    private(set) var inputOverCeilingCallbacks: UInt64 = 0

    init?(sampleRate: Double, maximumFrames: Int) {
        guard sampleRate.isFinite, sampleRate >= 8000, sampleRate <= 384000,
              maximumFrames > 0, maximumFrames <= 65536 else { return nil }
        self.maximumFrames = maximumFrames
        inputLeft = .allocate(capacity: maximumFrames)
        inputRight = .allocate(capacity: maximumFrames)
        outputLeft = .allocate(capacity: maximumFrames)
        outputRight = .allocate(capacity: maximumFrames)
        inputLeft.initialize(repeating: 0, count: maximumFrames)
        inputRight.initialize(repeating: 0, count: maximumFrames)
        outputLeft.initialize(repeating: 0, count: maximumFrames)
        outputRight.initialize(repeating: 0, count: maximumFrames)
        buffers = AudioBufferList.allocate(maximumBuffers: 2)
        var description = AudioComponentDescription(componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_PeakLimiter, componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description),
              AudioComponentInstanceNew(component, &unit) == noErr, let unit else { return nil }
        var format = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        for scope in [kAudioUnitScope_Input, kAudioUnitScope_Output] {
            guard AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, scope, 0,
                &format, UInt32(MemoryLayout.size(ofValue: format))) == noErr else { return nil }
        }
        var maximum = UInt32(maximumFrames)
        guard AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global,
            0, &maximum, UInt32(MemoryLayout.size(ofValue: maximum))) == noErr,
            AudioUnitSetParameter(unit, kLimiterParam_AttackTime, kAudioUnitScope_Global, 0, 0.0015, 0) == noErr,
            AudioUnitSetParameter(unit, kLimiterParam_DecayTime, kAudioUnitScope_Global, 0, 0.05, 0) == noErr,
            AudioUnitSetParameter(unit, kLimiterParam_PreGain, kAudioUnitScope_Global, 0, 0, 0) == noErr else { return nil }
        var callback = AURenderCallbackStruct(inputProc: { reference, _, _, _, frames, data in
            guard let data else { return kAudio_ParamError }
            let owner = Unmanaged<NativePeakLimiter>.fromOpaque(reference).takeUnretainedValue()
            let input = UnsafeMutableAudioBufferListPointer(data)
            guard frames <= owner.inputFrames, input.count == 2 else { return kAudio_ParamError }
            input[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: frames * 4, mData: owner.inputLeft)
            input[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: frames * 4, mData: owner.inputRight)
            return noErr
        }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        guard AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input,
            0, &callback, UInt32(MemoryLayout.size(ofValue: callback))) == noErr,
            AudioUnitInitialize(unit) == noErr else { return nil }
        var latency = 0.0
        var size = UInt32(MemoryLayout<Double>.size)
        guard AudioUnitGetProperty(unit, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0,
            &latency, &size) == noErr, latency.isFinite, latency >= 0, latency <= 1 else { return nil }
        delayFrames = Int((latency * sampleRate).rounded(.down))
        // Exercise the native render path before the device IOProc first enters it.
        process(left: inputLeft, right: inputRight, stride: 1, frames: min(maximumFrames, 128))
        guard renderFailures == 0, reset() else { return nil }
    }

    deinit {
        if let unit { AudioUnitUninitialize(unit); AudioComponentInstanceDispose(unit) }
        inputLeft.deallocate(); inputRight.deallocate(); outputLeft.deallocate(); outputRight.deallocate()
        buffers.unsafeMutablePointer.deallocate()
    }

    /// Returns true when input exceeded the ceiling or a safety guard intervened.
    @discardableResult
    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?, stride: Int, frames: Int) -> Bool {
        guard frames > 0 else { return false }
        guard stride > 0 else {
            left.pointee = 0; right?.pointee = 0
            renderFailures &+= 1; return true
        }
        guard frames <= maximumFrames, let unit else {
            silence(left, right, stride, frames); renderFailures &+= 1; return true
        }
        var limited = false
        var inputOverCeiling = false
        inputFrames = frames
        for frame in 0..<frames {
            let l = left[frame * stride], r = right?[frame * stride] ?? l
            inputOverCeiling = inputOverCeiling || (l.isFinite && abs(l) > 1) || (r.isFinite && abs(r) > 1)
            limited = limited || !l.isFinite || !r.isFinite || abs(l) > 1 || abs(r) > 1
            inputLeft[frame] = sanitize(l); inputRight[frame] = sanitize(r)
        }
        if inputOverCeiling, inputOverCeilingCallbacks != .max { inputOverCeilingCallbacks += 1 }
        buffers[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: outputLeft)
        buffers[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: outputRight)
        var timestamp = AudioTimeStamp(); timestamp.mSampleTime = sampleTime; timestamp.mFlags = .sampleTimeValid
        var flags: AudioUnitRenderActionFlags = []
        let status = AudioUnitRender(unit, &flags, &timestamp, 0, UInt32(frames), buffers.unsafeMutablePointer)
        sampleTime += Double(frames)
        guard status == noErr else { silence(left, right, stride, frames); renderFailures &+= 1; return true }
        for frame in 0..<frames {
            let l = outputLeft[frame], r = outputRight[frame]
            guard l.isFinite && r.isFinite else {
                silence(left, right, stride, frames); guardedSamples &+= 1; renderFailures &+= 1; return true
            }
        }
        for frame in 0..<frames {
            let l = outputLeft[frame], r = outputRight[frame]
            if abs(l) > 1 || abs(r) > 1 { limited = true; guardedSamples &+= 1 }
            left[frame * stride] = min(1, max(-1, l))
            right?[frame * stride] = min(1, max(-1, r))
        }
        return limited
    }

    private func sanitize(_ value: Float) -> Float {
        guard value.isFinite else { guardedSamples &+= 1; return 0 }
        // ponytail: bound native detector input to 1024; larger supported levels
        // would require detector normalization, not unbounded native arithmetic.
        guard abs(value) <= 1024 else { guardedSamples &+= 1; return min(1024, max(-1024, value)) }
        return value
    }

    private func silence(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>?, _ stride: Int, _ frames: Int) {
        for frame in 0..<frames { left[frame * stride] = 0; right?[frame * stride] = 0 }
    }

    @discardableResult
    func reset() -> Bool {
        guard let unit else { return false }
        guard AudioUnitReset(unit, kAudioUnitScope_Global, 0) == noErr else { return false }
        sampleTime = 0
        return true
    }
}
