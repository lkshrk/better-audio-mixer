import Accelerate
import Atomics
import BamCore
import CoreAudio
import Foundation

/// Single hardware-clocked aggregate that captures every source tap together
/// with the selected output device, summing each tap × its live gain into the
/// output inside one IOProc. One clock domain (the output device drives the
/// aggregate), without an application-level capture/playback queue. Tap capture
/// readiness does not itself prove suppression of an app's original output.
final class RouterAggregate {
    enum BuildFailure: Equatable {
        case createAggregate(OSStatus)
        case createIOProc(OSStatus)
        case startIO(OSStatus)
        case unsupportedFormat
        case createLimiter
    }

    struct HealthSnapshot: Equatable {
        let fires: Int
        let inputBuffers: Int
        let inputChannels: Int
        let inputFrames: Int
        let outputBuffers: Int
        let outputChannels: Int
        let outputFrames: Int
        let outputPeak: Float
        let limiterHits: Int
        var limiterFailures: Int = 0

        var hasAdvancedIO: Bool { fires > 0 && outputFrames > 0 }
        var hasExpectedInput: Bool { inputBuffers > 0 && inputChannels > 0 && inputFrames > 0 }
    }

    struct SourceHealthSnapshot: Equatable {
        let sourceID: String
        let inputBlocks: Int
        let inputFrames: Int
        let meter: Float
        var sampleRate: Double
        var channels: Int
    }

    /// One captured source: its tap, channel count, live L/R gain and meter.
    final class Tap {
        let sourceID: String
        let proc: ProcessTap
        let channels: Int
        let format: AudioStreamBasicDescription
        let gains = AtomicStereoGain()
        let meter = AtomicFloat(RMSMeter.floorDB)
        let meterL = AtomicFloat(RMSMeter.floorDB)
        let meterR = AtomicFloat(RMSMeter.floorDB)
        let inputBlocks = ManagedAtomic<Int>(0)
        let inputFrames = ManagedAtomic<Int>(0)

        init(sourceID: String, proc: ProcessTap) {
            self.sourceID = sourceID
            self.proc = proc
            self.channels = max(1, Int(proc.format.mChannelsPerFrame))
            self.format = proc.format
        }
    }

    private let taps: [Tap]
    private let tapIndexByID: [String: Int]
    /// One writer (IOProc), atomic snapshots on the control thread. Tokens refer
    /// to callback starts, so an already-running callback cannot confirm an edit.
    final class CaptureReadiness {
        private let started = ManagedAtomic<UInt64>(0)
        private let completed = ManagedAtomic<UInt64>(0)
        private let inputBuffers = ManagedAtomic<Int>(0)
        private let inputChannels = ManagedAtomic<Int>(0)
        private let inputBytes = ManagedAtomic<Int>(0)
        private let outputBuffers = ManagedAtomic<Int>(0)
        private let outputChannels = ManagedAtomic<Int>(0)
        private let outputBytes = ManagedAtomic<Int>(0)
        func observe(input: UnsafeMutableAudioBufferListPointer, output: UnsafeMutableAudioBufferListPointer) {
            var inChannels = 0, inBytes = 0, outChannels = 0, outBytes = 0
            for buffer in input { inChannels += Int(buffer.mNumberChannels); inBytes += Int(buffer.mDataByteSize) }
            for buffer in output { outChannels += Int(buffer.mNumberChannels); outBytes += Int(buffer.mDataByteSize) }
            inputBuffers.store(input.count, ordering: .relaxed)
            inputChannels.store(inChannels, ordering: .relaxed)
            inputBytes.store(inBytes, ordering: .relaxed)
            outputBuffers.store(output.count, ordering: .relaxed)
            outputChannels.store(outChannels, ordering: .relaxed)
            outputBytes.store(outBytes, ordering: .relaxed)
        }
        // Fieldwise diagnostic observations only; never used to authorize playback.
        var diagnosticSummary: String {
            "started=\(started.load(ordering: .acquiring)) completed=\(completed.load(ordering: .acquiring)) input=\(inputBuffers.load(ordering: .relaxed))/\(inputChannels.load(ordering: .relaxed))/\(inputBytes.load(ordering: .relaxed)) output=\(outputBuffers.load(ordering: .relaxed))/\(outputChannels.load(ordering: .relaxed))/\(outputBytes.load(ordering: .relaxed))"
        }
        var token: UInt64 { started.load(ordering: .acquiring) }
        func beginCallback() -> UInt64 {
            started.wrappingIncrementThenLoad(ordering: .releasing)
        }
        func completeCallback(_ sequence: UInt64, valid: Bool) {
            completed.store(valid ? sequence : 0, ordering: .releasing)
        }
        func wait(after token: UInt64, timeout: TimeInterval) -> Bool {
            guard timeout.isFinite, timeout >= 0 else { return false }
            let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
            repeat {
                if completed.load(ordering: .acquiring) > token { return true }
                if ContinuousClock.now >= deadline { return false }
                Thread.sleep(forTimeInterval: min(0.001, timeout))
            } while true
        }
    }
    private let readiness = CaptureReadiness()
    var startupDiagnostics: String { "expectedTapChannels=\(taps.map(\.channels)) \(readiness.diagnosticSummary)" }
    var readinessToken: UInt64 { readiness.token }

    /// Call on the control thread after applying gains/membership changes.
    /// This confirms render progress, not acoustic continuity or source mute.
    func waitUntilReady(after token: UInt64 = 0, timeout: TimeInterval = 0.5) -> Bool {
        readiness.wait(after: token, timeout: timeout)
    }

    func hasCompatibleTapFormats() -> Bool {
        taps.allSatisfy { tap in
            guard let current = tap.proc.currentFormat() else { return false }
            let frozen = tap.format
            return Self.supportsFormat(current)
                && current.mSampleRate == frozen.mSampleRate
                && current.mFormatFlags == frozen.mFormatFlags
                && current.mChannelsPerFrame == frozen.mChannelsPerFrame
                && current.mBytesPerFrame == frozen.mBytesPerFrame
                && current.mBytesPerPacket == frozen.mBytesPerPacket
                && current.mFramesPerPacket == frozen.mFramesPerPacket
        }
    }

    /// Null input slots represent inactive sources and retain channel positions.
    /// Actual sample values (including silence) are irrelevant to readiness.
    static func hasValidInputLayout(_ buffers: UnsafeMutableAudioBufferListPointer, channels: Int) -> Bool {
        var total = 0
        for buffer in buffers {
            let count = Int(buffer.mNumberChannels)
            guard count > 0, Int(buffer.mDataByteSize) % (MemoryLayout<Float>.size * count) == 0 else { return false }
            total += count
        }
        return channels > 0 && total == channels
    }

    /// Built once on the control thread from the IOProc configuration and every
    /// stream's virtual format. One mono ASBD cannot describe two mono streams.
    struct OutputLayout {
        let bufferChannels: [Int]
        let sampleRate: Double

        init?(bufferChannels: [Int], streamFormats: [AudioStreamBasicDescription]) {
            guard bufferChannels == [1] || bufferChannels == [2] || bufferChannels == [1, 1],
                  let first = streamFormats.first else { return nil }
            var expected: [Int] = []
            for format in streamFormats {
                guard RouterAggregate.supportsFormat(format), format.mSampleRate == first.mSampleRate else { return nil }
                if format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 {
                    expected.append(contentsOf: repeatElement(1, count: Int(format.mChannelsPerFrame)))
                } else {
                    expected.append(Int(format.mChannelsPerFrame))
                }
            }
            guard expected == bufferChannels else { return nil }
            self.bufferChannels = bufferChannels
            self.sampleRate = first.mSampleRate
        }
    }

    private static func outputLayout(device: AudioObjectID) -> OutputLayout? {
        var address = CA.address(kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioBufferList>.size else { return nil }
        let capacity = Int(size)
        let memory = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, memory) == noErr,
              Int(size) <= capacity, size >= MemoryLayout<AudioBufferList>.size else { return nil }
        let list = memory.assumingMemoryBound(to: AudioBufferList.self)
        let count = Int(list.pointee.mNumberBuffers)
        guard (1...2).contains(count),
              Int(size) >= MemoryLayout<AudioBufferList>.size + (count - 1) * MemoryLayout<AudioBuffer>.stride else { return nil }
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        let streams = CA.array(device, CA.address(kAudioDevicePropertyStreams, kAudioDevicePropertyScopeOutput),
                               of: AudioStreamID.self)
        guard (1...2).contains(streams.count) else { return nil }
        let formats = streams.map { stream in
            CA.value(stream, CA.address(kAudioStreamPropertyVirtualFormat), default: AudioStreamBasicDescription())
        }
        return OutputLayout(bufferChannels: buffers.map { Int($0.mNumberChannels) }, streamFormats: formats)
    }

    static func validOutputFrames(_ buffers: UnsafeMutableAudioBufferListPointer,
                                  layout: OutputLayout) -> Int? {
        guard buffers.count == layout.bufferChannels.count else { return nil }
        var frames: Int?
        for index in buffers.indices {
            let buffer = buffers[index]
            let count = layout.bufferChannels[index]
            let bytes = MemoryLayout<Float>.size * count
            guard Int(buffer.mNumberChannels) == count, buffer.mData != nil,
                  buffer.mDataByteSize > 0, Int(buffer.mDataByteSize) % bytes == 0 else { return nil }
            let available = Int(buffer.mDataByteSize) / bytes
            if let frames, frames != available { return nil }
            frames = available
        }
        return frames
    }
    /// Control-thread resource owner. Each successful close stage is committed
    /// separately; failed handles remain available for the next protected retry.
    final class IOResources {
        struct Operations {
            var stop: (AudioObjectID, AudioDeviceIOProcID) -> OSStatus
            var destroyIOProc: (AudioObjectID, AudioDeviceIOProcID) -> OSStatus
            var destroyAggregate: (AudioObjectID) -> OSStatus
            var isGone: (AudioObjectID) -> Bool

            static var live: Operations { Operations(stop: { AudioDeviceStop($0, $1) },
                destroyIOProc: { AudioDeviceDestroyIOProcID($0, $1) },
                destroyAggregate: { AudioHardwareDestroyAggregateDevice($0) },
                isGone: { id in
                    var address = CA.address(kAudioObjectPropertyClass)
                    var value = AudioClassID(0)
                    var size = UInt32(MemoryLayout<AudioClassID>.size)
                    return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
                        == kAudioHardwareBadObjectError
                }) }
        }
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        var ioProcID: AudioDeviceIOProcID?
        private var stopped = false
        private let operations: Operations
        init(operations: Operations = .live) { self.operations = operations }

        func close() -> Bool {
            guard aggregateID != kAudioObjectUnknown else { return true }
            if let ioProcID {
                if !stopped {
                    let status = operations.stop(aggregateID, ioProcID)
                    // A registered IOProc can survive a failed AudioDeviceStart.
                    // HAL's explicit "hardware isn't running" result also proves
                    // it is safe to proceed to callback destruction.
                    guard status == noErr || status == kAudioHardwareNotRunningError else {
                        return resolveFailure(status)
                    }
                    stopped = true
                }
                let status = operations.destroyIOProc(aggregateID, ioProcID)
                guard status == noErr else { return resolveFailure(status) }
                self.ioProcID = nil
            }
            let status = operations.destroyAggregate(aggregateID)
            guard status == noErr else { return resolveFailure(status) }
            aggregateID = AudioObjectID(kAudioObjectUnknown)
            return true
        }

        private func resolveFailure(_ status: OSStatus) -> Bool {
            guard operations.isGone(aggregateID) else {
                bamLog("router close failed status=\(status) aggregate=\(aggregateID); retaining handles", level: .error)
                return false
            }
            ioProcID = nil
            aggregateID = AudioObjectID(kAudioObjectUnknown)
            return true
        }
    }

    private let resources: IOResources
    private var aggregateID: AudioObjectID {
        get { resources.aggregateID }
        set { resources.aggregateID = newValue }
    }
    private var ioProcID: AudioDeviceIOProcID? {
        get { resources.ioProcID }
        set { resources.ioProcID = newValue }
    }
    private var inputMixer: RouterInputMixer?
    private var limiter: NativePeakLimiter?
    private var diagnostics: CallbackDiagnostics?
    func audioDiagnostics() -> AudioDiagnostics? { diagnostics?.snapshot() }
    /// Captured by HAL's block, so fade state and process taps outlive even a
    /// failed callback destruction. Only the render thread writes played.
    final class CallbackLifetime {
        let taps: [Tap]
        var played = 0
        init(taps: [Tap]) { self.taps = taps }
    }

    /// Fade-in length in frames (~43 ms at 48 kHz). The summed output is ramped
    /// 0→1 over the first taps after the aggregate goes live so a freshly started
    /// router reduces startup clicks in its own rendered path. This does not
    /// protect against original audio bypassing that path.
    private static let fadeInFrames = 2048

    // RT→log diagnostics (written relaxed on the audio thread, read by a Task).
    private let dFires = ManagedAtomic<Int>(0)
    private let dInBufs = ManagedAtomic<Int>(0)
    private let dInCh0 = ManagedAtomic<Int>(0)
    private let dInChTotal = ManagedAtomic<Int>(0)
    private let dInFrames = ManagedAtomic<Int>(0)
    private let dOutBufs = ManagedAtomic<Int>(0)
    private let dOutCh = ManagedAtomic<Int>(0)
    private let dOutFrames = ManagedAtomic<Int>(0)
    private let dOutPeak = ManagedAtomic<UInt32>(0)
    private let dLimiterHits = ManagedAtomic<Int>(0)
    private let dLimiterFailures = ManagedAtomic<Int>(0)
    private var buildFailure: BuildFailure?

    init(taps orderedTaps: [Tap], resources: IOResources = IOResources()) {
        self.taps = orderedTaps
        self.resources = resources
        self.tapIndexByID = Dictionary(uniqueKeysWithValues: orderedTaps.enumerated().map { ($0.element.sourceID, $0.offset) })
    }

    /// The engine owns this object before starting. A failed start therefore
    /// cannot discard handles whose cleanup also fails.
    func start(outputUID: String, failure: inout BuildFailure?) -> Bool {
        guard !taps.isEmpty, taps.allSatisfy({ Self.supportsFormat($0.proc.format) }) else {
            failure = .unsupportedFormat
            return false
        }
        guard createAggregate(outputUID: outputUID), startIO() else {
            failure = buildFailure
            return false
        }
        failure = nil
        return true
    }

    deinit { _ = close() }

    /// Only layouts the callback interprets intentionally; never reinterpret PCM integers.
    static func supportsFormat(_ format: AudioStreamBasicDescription) -> Bool {
        let channels = format.mChannelsPerFrame
        guard channels == 1 || channels == 2 else { return false }
        let planar = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let bytes = UInt32(MemoryLayout<Float>.size) * (planar ? 1 : channels)
        return format.mFormatID == kAudioFormatLinearPCM
            && format.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0
            && format.mBitsPerChannel == 32
            && format.mBytesPerFrame == bytes && format.mFramesPerPacket == 1
            && format.mBytesPerPacket == bytes
            && format.mSampleRate.isFinite && format.mSampleRate >= 8000 && format.mSampleRate <= 384000
    }

    /// Effective per-source L/R gain, folded off the audio thread.
    func setGain(sourceID: String, l: Float, r: Float) {
        guard let i = tapIndexByID[sourceID] else { return }
        taps[i].gains.store(left: l, right: r)
    }

    func meter(sourceID: String) -> Float {
        guard let i = tapIndexByID[sourceID] else { return RMSMeter.floorDB }
        return taps[i].meter.load()
    }

    func stereoMeter(sourceID: String) -> (left: Float, right: Float) {
        guard let i = tapIndexByID[sourceID] else { return (RMSMeter.floorDB, RMSMeter.floorDB) }
        return (taps[i].meterL.load(), taps[i].meterR.load())
    }

    func healthSnapshot() -> HealthSnapshot {
        HealthSnapshot(
            fires: dFires.load(ordering: .relaxed),
            inputBuffers: dInBufs.load(ordering: .relaxed),
            inputChannels: dInChTotal.load(ordering: .relaxed),
            inputFrames: dInFrames.load(ordering: .relaxed),
            outputBuffers: dOutBufs.load(ordering: .relaxed),
            outputChannels: dOutCh.load(ordering: .relaxed),
            outputFrames: dOutFrames.load(ordering: .relaxed),
            outputPeak: Float(bitPattern: dOutPeak.load(ordering: .relaxed)),
            limiterHits: dLimiterHits.load(ordering: .relaxed),
            limiterFailures: dLimiterFailures.load(ordering: .relaxed)
        )
    }

    func sourceHealthSnapshots() -> [SourceHealthSnapshot] {
        taps.map { tap in
            // This hot snapshot reads atomics and frozen metadata only. Live HAL
            // format observation belongs to the background health scan.
            let format = tap.proc.format
            return SourceHealthSnapshot(
                sourceID: tap.sourceID,
                inputBlocks: tap.inputBlocks.load(ordering: .relaxed),
                inputFrames: tap.inputFrames.load(ordering: .relaxed),
                meter: tap.meter.load(),
                sampleRate: format.mSampleRate,
                channels: Int(format.mChannelsPerFrame)
            )
        }
    }

    private func createAggregate(outputUID: String) -> Bool {
        let signpostID = engineSignposter.makeSignpostID()
        let signpostState = engineSignposter.beginInterval("RouterAggregate.create", id: signpostID)
        defer { engineSignposter.endInterval("RouterAggregate.create", signpostState) }

        let tapList = taps.map {
            [kAudioSubTapUIDKey: $0.proc.uuid, kAudioSubTapDriftCompensationKey: 0] as [String: Any]
        }
        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "bam-router",
            kAudioAggregateDeviceUIDKey: "bam-router-agg",
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceTapAutoStartKey: 1,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: tapList,
        ]
        let st = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &aggregateID)
        engineLog.debug(
            "router createAggregate out=\(outputUID, privacy: .private) taps=\(self.taps.count, privacy: .public) status=\(st, privacy: .public) aggID=\(self.aggregateID, privacy: .public)"
        )
        let ok = st == noErr && aggregateID != AudioObjectID(kAudioObjectUnknown)
        if !ok { buildFailure = .createAggregate(st) }
        return ok
    }

    private func startIO() -> Bool {
        let nTaps = taps.count
        guard let outputLayout = Self.outputLayout(device: aggregateID) else {
            buildFailure = .unsupportedFormat; return false
        }
        let outSR = outputLayout.sampleRate
        guard let mixer = RouterInputMixer(channels: taps.map(\.channels), gains: taps.map(\.gains), sampleRate: outSR) else {
            buildFailure = .unsupportedFormat; return false
        }
        // Negotiate native storage before AudioDeviceStart; never resize in the IOProc.
        let range = CA.value(aggregateID, CA.address(kAudioDevicePropertyBufferFrameSizeRange), default: AudioValueRange())
        let currentFrames = Int(CA.uint32(aggregateID, CA.address(kAudioDevicePropertyBufferFrameSize)))
        let maxFrames = range.mMaximum.isFinite && range.mMaximum > 0 && range.mMaximum <= 65536
            ? max(currentFrames, Int(range.mMaximum.rounded(.up))) : max(currentFrames, 4096)
        guard let limiter = NativePeakLimiter(sampleRate: outSR, maximumFrames: maxFrames) else {
            buildFailure = .createLimiter; return false
        }
        inputMixer = mixer
        self.limiter = limiter
        let diagnostics = CallbackDiagnostics(sampleRate: outSR, limiterDelayFrames: limiter.delayFrames)
        self.diagnostics = diagnostics
        let sumSq = mixer.sumSq, sumSqL = mixer.sumSqL, sumSqR = mixer.sumSqR
        let cnt = mixer.frames, cntL = mixer.framesL, cntR = mixer.framesR

        let lifetime = CallbackLifetime(taps: taps)
        let fadeIn = Self.fadeInFrames
        let meters = taps.map(\.meter)
        let metersL = taps.map(\.meterL)
        let metersR = taps.map(\.meterR)
        let tapInputBlocks = taps.map(\.inputBlocks)
        let tapInputFrames = taps.map(\.inputFrames)

        let dFires = self.dFires, dInBufs = self.dInBufs, dInCh0 = self.dInCh0
        let dInChTotal = self.dInChTotal, dInFrames = self.dInFrames
        let dOutBufs = self.dOutBufs, dOutCh = self.dOutCh
        let dOutFrames = self.dOutFrames, dOutPeak = self.dOutPeak
        let dLimiterHits = self.dLimiterHits
        let dLimiterFailures = self.dLimiterFailures
        let readiness = self.readiness

        let block: AudioDeviceIOBlock = { _, inInputData, _, outOutputData, outputTime in
            let sequence = readiness.beginCallback()
            var valid = false
            defer { readiness.completeCallback(sequence, valid: valid) }
            let callbackStart = mach_absolute_time()
            let inABL = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            let outABL = UnsafeMutableAudioBufferListPointer(outOutputData)
            readiness.observe(input: inABL, output: outABL)
            // Silence every supplied output even when its layout is rejected.
            for buffer in outABL {
                if let data = buffer.mData {
                    memset(data, 0, Int(buffer.mDataByteSize))
                }
            }
            guard Self.hasValidInputLayout(inABL, channels: mixer.channelCount),
                  Self.validOutputFrames(outABL, layout: outputLayout) != nil else { return }
            guard outABL.count > 0 else { return }
            let firstOut = outABL[0]
            guard let firstOutData = firstOut.mData else { return }
            let firstOutCh = Int(firstOut.mNumberChannels)
            guard firstOutCh > 0 else { return }
            let outFrames0 = Int(firstOut.mDataByteSize) / (MemoryLayout<Float>.size * firstOutCh)
            var outFrames = outFrames0
            var planarStereo = false
            var rightOutData: UnsafeMutableRawPointer?
            if outABL.count >= 2, firstOutCh == 1, Int(outABL[1].mNumberChannels) == 1, let right = outABL[1].mData {
                planarStereo = true
                rightOutData = right
                let rightFrames = Int(outABL[1].mDataByteSize) / MemoryLayout<Float>.size
                if rightFrames < outFrames { outFrames = rightFrames }
            }
            let out = firstOutData.assumingMemoryBound(to: Float.self)
            let rightOut = rightOutData?.assumingMemoryBound(to: Float.self)

            let nBufs = inABL.count
            let outputRight = planarStereo ? rightOut : (firstOutCh == 2 ? out + 1 : nil)
            let outputStride = planarStereo ? 1 : firstOutCh
            let inChTotal = mixer.mix(inInputData, left: out, right: outputRight,
                                       outputStride: outputStride, outputFrames: outFrames)

            var mt = 0
            while mt < nTaps {
                let rms = cnt[mt] > 0 ? (sumSq[mt] / Float(cnt[mt])).squareRoot() : 0
                let rmsL = cntL[mt] > 0 ? (sumSqL[mt] / Float(cntL[mt])).squareRoot() : rms
                let rmsR = cntR[mt] > 0 ? (sumSqR[mt] / Float(cntR[mt])).squareRoot() : rmsL
                meters[mt].store(RMSMeter.dbFS(rms: rms))
                metersL[mt].store(RMSMeter.dbFS(rms: rmsL))
                metersR[mt].store(RMSMeter.dbFS(rms: rmsR))
                if cnt[mt] > 0 {
                    let frames = tapInputFrames[mt].load(ordering: .relaxed)
                    tapInputFrames[mt].store(frames &+ cnt[mt], ordering: .relaxed)
                    tapInputBlocks[mt].wrappingIncrement(ordering: .relaxed)
                }
                mt += 1
            }

            // Start-up fade-in (declick). Applied before the lookahead limiter so
            // the ramp is preserved even if the limiter is active on startup.
            let playedNow = lifetime.played
            var rp = 0
            while playedNow < fadeIn, rp < outABL.count {
                let b = outABL[rp]
                if let data = b.mData {
                    let ch = max(1, Int(b.mNumberChannels))
                    let n = Int(b.mDataByteSize) / MemoryLayout<Float>.size
                    let p = data.assumingMemoryBound(to: Float.self)
                    var i = 0
                    while i < n {
                        let frame = i / ch
                        let r = playedNow + frame
                        let ramp = r >= fadeIn ? Float(1) : Float(r) / Float(fadeIn)
                        p[i] *= ramp
                        i += 1
                    }
                }
                rp += 1
            }
            lifetime.played = min(fadeIn, playedNow + outFrames)

            let failuresBefore = limiter.renderFailures
            if limiter.process(left: out, right: outputRight, stride: outputStride, frames: outFrames) {
                dLimiterHits.wrappingIncrement(ordering: .relaxed)
                diagnostics.interventions.store(CallbackDiagnostics.increment(diagnostics.interventions.load(ordering: .relaxed)), ordering: .relaxed)
            }
            diagnostics.inputOverCeiling.store(limiter.inputOverCeilingCallbacks, ordering: .relaxed)
            diagnostics.guardedSamples.store(limiter.guardedSamples, ordering: .relaxed)
            diagnostics.renderFailures.store(limiter.renderFailures, ordering: .relaxed)
            dLimiterFailures.store(Int(truncatingIfNeeded: limiter.renderFailures), ordering: .relaxed)

            // Post-limiter peak for diagnostics.
            var peak: Float = 0
            if planarStereo {
                let nL = Int(outABL[0].mDataByteSize) / MemoryLayout<Float>.size
                if let dL = outABL[0].mData {
                    let pk = DSPKernels.peakMagnitudeVDSP(dL.assumingMemoryBound(to: Float.self), count: nL)
                    if pk > peak { peak = pk }
                }
                if let dR = rightOutData {
                    let nR = Int(outABL[1].mDataByteSize) / MemoryLayout<Float>.size
                    let pk = DSPKernels.peakMagnitudeVDSP(dR.assumingMemoryBound(to: Float.self), count: nR)
                    if pk > peak { peak = pk }
                }
            } else {
                let n = Int(outABL[0].mDataByteSize) / MemoryLayout<Float>.size
                if let d = outABL[0].mData {
                    peak = DSPKernels.peakMagnitudeVDSP(d.assumingMemoryBound(to: Float.self), count: n)
                }
            }
            dFires.wrappingIncrement(ordering: .relaxed)
            dInBufs.store(nBufs, ordering: .relaxed)
            dInCh0.store(nBufs > 0 ? Int(inABL[0].mNumberChannels) : 0, ordering: .relaxed)
            dInChTotal.store(inChTotal, ordering: .relaxed)
            dInFrames.store(outFrames, ordering: .relaxed)
            dOutBufs.store(outABL.count, ordering: .relaxed)
            dOutCh.store(firstOutCh, ordering: .relaxed)
            dOutFrames.store(outFrames, ordering: .relaxed)
            dOutPeak.store(peak.bitPattern, ordering: .relaxed)
            diagnostics.record(start: callbackStart, end: mach_absolute_time(), frames: outFrames,
                outputHostTime: outputTime.pointee.mFlags.contains(.hostTimeValid) ? outputTime.pointee.mHostTime : nil)
            valid = limiter.renderFailures == failuresBefore
        }

        let cst = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil, block)
        guard cst == noErr, ioProcID != nil else {
            bamLog("router createIOProc FAILED status=\(cst)")
            buildFailure = .createIOProc(cst)
            return false
        }
        let sst = AudioDeviceStart(aggregateID, ioProcID)
        bamLog("router startIO createStatus=\(cst) startStatus=\(sst) expectInChans=\(mixer.channelCount) limiterDelay=\(limiter.delayFrames)")
        if sst != noErr { buildFailure = .startIO(sst) }

        Task { [dFires, dInBufs, dInCh0, dInChTotal, dInFrames, dOutBufs, dOutCh, dOutFrames, dOutPeak, dLimiterHits] in
            for _ in 0..<6 {
                try? await Task.sleep(for: .seconds(2))
                let pk = Float(bitPattern: dOutPeak.load(ordering: .relaxed))
                bamLog("router fires=\(dFires.load(ordering: .relaxed)) inBufs=\(dInBufs.load(ordering: .relaxed)) inCh0=\(dInCh0.load(ordering: .relaxed)) inChTotal=\(dInChTotal.load(ordering: .relaxed)) inFrames=\(dInFrames.load(ordering: .relaxed)) outBufs=\(dOutBufs.load(ordering: .relaxed)) outCh0=\(dOutCh.load(ordering: .relaxed)) outFrames=\(dOutFrames.load(ordering: .relaxed)) outPeak=\(pk) limiterHits=\(dLimiterHits.load(ordering: .relaxed))")
            }
        }
        return sst == noErr
    }

    @discardableResult
    func close() -> Bool {
        guard resources.close() else { return false }
        inputMixer = nil
        limiter = nil
        return true
    }
}
