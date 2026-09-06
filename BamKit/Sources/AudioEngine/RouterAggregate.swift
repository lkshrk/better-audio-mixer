import Accelerate
import Atomics
import BamCore
import CoreAudio
import Foundation

/// Single hardware-clocked aggregate that captures every source tap together
/// with the selected output device, summing each tap × its live gain into the
/// output inside one IOProc. One clock domain (the output device drives the
/// aggregate), without an application-level capture/playback queue. The taps are `.mutedWhenTapped`, so each captured app's own output is
/// silenced and only bam's summed mix reaches the hardware.
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
        let sampleRate: Double
        let channels: Int
    }

    /// One captured source: its tap, channel count, live L/R gain and meter.
    final class Tap {
        let sourceID: String
        let proc: ProcessTap
        let channels: Int
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
        }
    }

    private let taps: [Tap]
    private let tapIndexByID: [String: Int]
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
    /// router can never step from silence to full level — a click/pop or, worse,
    /// a transient blast. Pure ear-safety net on top of tap-mute continuity.
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
        let planar = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let bytes = UInt32(MemoryLayout<Float>.size) * (planar ? 1 : channels)
        return format.mFormatID == kAudioFormatLinearPCM
            && format.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0
            && format.mBitsPerChannel == 32 && (channels == 1 || channels == 2)
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
            let format = tap.proc.currentFormat() ?? tap.proc.format
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
        let outputFormat = CA.value(aggregateID,
            CA.address(kAudioDevicePropertyStreamFormat, kAudioDevicePropertyScopeOutput),
            default: AudioStreamBasicDescription())
        guard Self.supportsFormat(outputFormat) else { buildFailure = .unsupportedFormat; return false }
        let outSR = outputFormat.mSampleRate
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

        let block: AudioDeviceIOBlock = { _, inInputData, _, outOutputData, outputTime in
            let callbackStart = mach_absolute_time()
            let inABL = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            let outABL = UnsafeMutableAudioBufferListPointer(outOutputData)
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

            var oz = 0
            while oz < outABL.count {
                let b = outABL[oz]
                if let data = b.mData {
                    let n = Int(b.mDataByteSize) / MemoryLayout<Float>.size
                    let p = data.assumingMemoryBound(to: Float.self)
                    var z = 0
                    while z < n { p[z] = 0; z += 1 }
                }
                oz += 1
            }
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
