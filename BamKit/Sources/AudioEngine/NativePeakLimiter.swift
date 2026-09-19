import Accelerate
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
    /// Detector input is bounded to 1024; larger levels would need detector normalization.
    private static let inputBound: Float = 1024

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
        inputFrames = frames
        let n = vDSP_Length(frames)
        var zero: Float = 0
        vDSP_vsadd(left, stride, &zero, inputLeft, 1, n)
        if let right {
            vDSP_vsadd(right, stride, &zero, inputRight, 1, n)
        } else {
            memcpy(inputRight, inputLeft, frames * MemoryLayout<Float>.size)
        }
        var guarded: UInt64 = 0
        var peakIn = max(DSPKernels.peakMagnitudeVDSP(inputLeft, count: frames),
                         DSPKernels.peakMagnitudeVDSP(inputRight, count: frames))
        if !Self.allFinite(inputLeft, n) || !Self.allFinite(inputRight, n) || peakIn > Self.inputBound {
            guarded += sanitize(inputLeft, frames) + sanitize(inputRight, frames)
            peakIn = max(DSPKernels.peakMagnitudeVDSP(inputLeft, count: frames),
                         DSPKernels.peakMagnitudeVDSP(inputRight, count: frames))
        }
        let inputOverCeiling = peakIn > 1
        var limited = inputOverCeiling || guarded > 0
        if inputOverCeiling, inputOverCeilingCallbacks != .max { inputOverCeilingCallbacks += 1 }
        buffers[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: outputLeft)
        buffers[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: outputRight)
        var timestamp = AudioTimeStamp(); timestamp.mSampleTime = sampleTime; timestamp.mFlags = .sampleTimeValid
        var flags: AudioUnitRenderActionFlags = []
        let status = AudioUnitRender(unit, &flags, &timestamp, 0, UInt32(frames), buffers.unsafeMutablePointer)
        sampleTime += Double(frames)
        guard status == noErr else {
            silence(left, right, stride, frames); guardedSamples &+= guarded; renderFailures &+= 1; return true
        }
        guard Self.allFinite(outputLeft, n), Self.allFinite(outputRight, n) else {
            silence(left, right, stride, frames); guardedSamples &+= guarded &+ 1; renderFailures &+= 1; return true
        }
        let peakOut = max(DSPKernels.peakMagnitudeVDSP(outputLeft, count: frames),
                          DSPKernels.peakMagnitudeVDSP(outputRight, count: frames))
        if peakOut > 1 {
            limited = true
            var frame = 0
            while frame < frames {
                if abs(outputLeft[frame]) > 1 || abs(outputRight[frame]) > 1 { guarded &+= 1 }
                frame += 1
            }
        }
        var low: Float = -1, high: Float = 1
        vDSP_vclip(outputLeft, 1, &low, &high, left, vDSP_Stride(stride), n)
        if let right { vDSP_vclip(outputRight, 1, &low, &high, right, vDSP_Stride(stride), n) }
        guardedSamples &+= guarded
        return limited
    }

    @inline(__always)
    private static func allFinite(_ buffer: UnsafePointer<Float>, _ n: vDSP_Length) -> Bool {
        var sum: Float = 0
        vDSP_sve(buffer, 1, &sum, n)
        return sum.isFinite
    }

    private func sanitize(_ buffer: UnsafeMutablePointer<Float>, _ frames: Int) -> UInt64 {
        var guarded: UInt64 = 0
        var frame = 0
        while frame < frames {
            let value = buffer[frame]
            if !value.isFinite {
                buffer[frame] = 0; guarded &+= 1
            } else if abs(value) > Self.inputBound {
                buffer[frame] = min(Self.inputBound, max(-Self.inputBound, value)); guarded &+= 1
            }
            frame += 1
        }
        return guarded
    }

    private func silence(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>?, _ stride: Int, _ frames: Int) {
        DSPKernels.clearVDSP(left, stride: stride, frames: frames)
        if let right { DSPKernels.clearVDSP(right, stride: stride, frames: frames) }
    }

    @discardableResult
    func reset() -> Bool {
        guard let unit else { return false }
        guard AudioUnitReset(unit, kAudioUnitScope_Global, 0) == noErr else { return false }
        sampleTime = 0
        return true
    }
}
