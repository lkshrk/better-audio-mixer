import CoreAudio
import AudioToolbox
import Foundation

/// Fills `frames` interleaved samples into `dst` (channel count fixed at client
/// creation). Runs on the audio render thread — must be lock-free and
/// allocation-free.
typealias MixRenderBlock = @Sendable (_ frames: Int, _ dst: UnsafeMutablePointer<Float>) -> Void

/// Render side of one mix: opens a claimed BAM virtual device (by UID) as an
/// AUHAL output unit and drives its render callback from a `MixRenderBlock`.
/// The consuming app (OBS / Discord / a recorder) selecting that device reads
/// back exactly what we render. Proven independent per device (loopcheck2).
final class VirtualDeviceClient {
    private final class Context {
        let render: MixRenderBlock
        init(_ render: @escaping MixRenderBlock) { self.render = render }
    }

    let deviceUID: String
    let deviceID: AudioObjectID
    let channels: Int
    let sampleRate: Double
    private let unit: AudioUnit
    private let context: Context
    private var started = false

    init?(deviceUID: String, channels: Int = 2, sampleRate: Double = 48_000, render: @escaping MixRenderBlock) {
        guard let id = Self.deviceID(forUID: deviceUID) else { return nil }
        self.deviceUID = deviceUID
        self.deviceID = id
        self.channels = channels
        self.sampleRate = sampleRate
        self.context = Context(render)

        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0
        )
        guard let comp = AudioComponentFindNext(nil, &desc) else { return nil }
        var u: AudioUnit?
        guard AudioComponentInstanceNew(comp, &u) == noErr, let u else { return nil }
        self.unit = u

        var enableIn: UInt32 = 0
        var enableOut: UInt32 = 1
        AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enableIn, 4)
        AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enableOut, 4)
        var dev = id
        AudioUnitSetProperty(u, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, 4)

        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channels),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(4 * channels),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        guard AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                                   &asbd, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)) == noErr else {
            AudioComponentInstanceDispose(u)
            return nil
        }

        var cb = AURenderCallbackStruct(
            inputProc: Self.renderCallback,
            inputProcRefCon: Unmanaged.passUnretained(context).toOpaque()
        )
        guard AudioUnitSetProperty(u, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                                   &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size)) == noErr,
              AudioUnitInitialize(u) == noErr else {
            AudioComponentInstanceDispose(u)
            return nil
        }
    }

    deinit {
        if started { AudioOutputUnitStop(unit) }
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
    }

    func start() -> Bool {
        guard !started else { return true }
        let st = AudioOutputUnitStart(unit)
        started = st == noErr
        return started
    }

    func stop() {
        guard started else { return }
        AudioOutputUnitStop(unit)
        started = false
    }

    private static let renderCallback: AURenderCallback = { ctx, _, _, _, frames, ioData in
        let context = Unmanaged<Context>.fromOpaque(ctx).takeUnretainedValue()
        guard let abl = ioData else { return noErr }
        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        guard let first = buffers.first, let data = first.mData else { return noErr }
        context.render(Int(frames), data.assumingMemoryBound(to: Float.self))
        return noErr
    }

    /// Resolve a device UID to its AudioObjectID by scanning the global list.
    static func deviceID(forUID uid: String) -> AudioObjectID? {
        let addr = CA.address(kAudioHardwarePropertyDevices)
        let ids = CA.array(AudioObjectID(kAudioObjectSystemObject), addr, of: AudioObjectID.self)
        for id in ids {
            let u = CA.cfString(id, CA.address(kAudioDevicePropertyDeviceUID))
            if u == uid { return id }
        }
        return nil
    }
}
