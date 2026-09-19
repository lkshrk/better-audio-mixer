import Accelerate
import Atomics
import BamCore
import CoreAudio
import Foundation

/// Single hardware-clocked aggregate that captures every source tap together
/// with the selected output device, summing each tap × its live gain into the
/// output inside one IOProc. Control-thread use is serialized by the engine's router gate.
final class RouterAggregate: @unchecked Sendable {
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
        var sampleRateMismatches: Int = 0
        var frameDivergenceCallbacks: Int = 0

        var hasAdvancedIO: Bool { fires > 0 && outputFrames > 0 }
        var hasExpectedInput: Bool { inputBuffers > 0 && inputChannels > 0 && inputFrames > 0 }
    }

    struct SourceHealthSnapshot: Equatable {
        let sourceID: String
        let inputFrames: Int
        var sampleRate: Double
        var channels: Int
    }

    /// One captured source: its tap and frozen format. Gains and meters live in the aggregate's cells.
    final class Tap: @unchecked Sendable {
        let sourceID: String
        let proc: ProcessTap
        let channels: Int
        let format: AudioStreamBasicDescription

        init(sourceID: String, proc: ProcessTap) {
            self.sourceID = sourceID
            self.proc = proc
            self.channels = max(1, Int(proc.format.mChannelsPerFrame))
            self.format = proc.format
        }
    }

    private let taps: [Tap]
    private let tapIndexByID: [String: Int]
    let cells: RouterAtomicCells

    /// One writer (IOProc), atomic snapshots on the control thread. Tokens refer
    /// to callback starts, so an already-running callback cannot confirm an edit.
    final class CaptureReadiness: Sendable {
        private let started = ManagedAtomic<UInt64>(0)
        private let completed = ManagedAtomic<UInt64>(0)
        var token: UInt64 { started.load(ordering: .acquiring) }
        var diagnosticSummary: String {
            "started=\(started.load(ordering: .acquiring)) completed=\(completed.load(ordering: .acquiring))"
        }
        func beginCallback() -> UInt64 {
            started.wrappingIncrementThenLoad(ordering: .releasing)
        }
        func completeCallback(_ sequence: UInt64, valid: Bool) {
            completed.store(valid ? sequence : 0, ordering: .releasing)
        }
        func wait(after token: UInt64, timeout: TimeInterval) async -> Bool {
            guard timeout.isFinite, timeout >= 0 else { return false }
            let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
            repeat {
                if completed.load(ordering: .acquiring) > token { return true }
                if ContinuousClock.now >= deadline { return false }
                try? await Task.sleep(for: .milliseconds(1))
            } while true
        }
    }
    private let readiness = CaptureReadiness()
    var readinessToken: UInt64 { readiness.token }
    /// Fieldwise diagnostic observations only; never used to authorize playback.
    var startupDiagnostics: String {
        "expectedTapChannels=\(taps.map(\.channels)) \(readiness.diagnosticSummary) "
            + "input=\(cells.load(.observedInputBuffers))/\(cells.load(.observedInputChannels))/\(cells.load(.observedInputBytes)) "
            + "output=\(cells.load(.observedOutputBuffers))/\(cells.load(.observedOutputChannels))/\(cells.load(.observedOutputBytes))"
    }

    /// Confirms render progress after a gain or membership edit, not acoustic continuity or source mute.
    func waitUntilReady(after token: UInt64 = 0, timeout: TimeInterval = 0.5) async -> Bool {
        await readiness.wait(after: token, timeout: timeout)
    }

    struct ReadinessObservation: Sendable {
        let formatsBefore: Bool
        let ready: Bool
        let formatsAfter: Bool
        var accepted: Bool { formatsBefore && ready && formatsAfter }
    }

    /// Formats are checked on both sides of the wait so a mid-edit format change cannot pass.
    func observeReadiness() async -> ReadinessObservation {
        let formatsBefore = hasCompatibleTapFormats()
        let ready = formatsBefore ? await waitUntilReady(after: readinessToken) : false
        return ReadinessObservation(formatsBefore: formatsBefore, ready: ready, formatsAfter: hasCompatibleTapFormats())
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

    @inline(__always)
    private static func observeLayout(input: UnsafeMutableAudioBufferListPointer,
                                      output: UnsafeMutableAudioBufferListPointer, into cells: RouterAtomicCells) {
        var inChannels = 0, inBytes = 0, outChannels = 0, outBytes = 0
        var index = 0
        while index < input.count {
            let buffer = input[index]
            inChannels += Int(buffer.mNumberChannels); inBytes += Int(buffer.mDataByteSize)
            index += 1
        }
        index = 0
        while index < output.count {
            let buffer = output[index]
            outChannels += Int(buffer.mNumberChannels); outBytes += Int(buffer.mDataByteSize)
            index += 1
        }
        cells.counter(.observedInputBuffers).store(input.count, ordering: .relaxed)
        cells.counter(.observedInputChannels).store(inChannels, ordering: .relaxed)
        cells.counter(.observedInputBytes).store(inBytes, ordering: .relaxed)
        cells.counter(.observedOutputBuffers).store(output.count, ordering: .relaxed)
        cells.counter(.observedOutputChannels).store(outChannels, ordering: .relaxed)
        cells.counter(.observedOutputBytes).store(outBytes, ordering: .relaxed)
    }

    /// Null input slots represent inactive sources and retain channel positions.
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

    /// Raw copy of `OutputLayout.bufferChannels` for the IOProc; avoids array traffic on the render thread.
    private final class RawOutputLayout {
        let channels: UnsafeMutablePointer<Int>
        let count: Int
        init(_ layout: OutputLayout) {
            count = layout.bufferChannels.count
            channels = .allocate(capacity: max(1, count))
            channels.initialize(from: layout.bufferChannels, count: count)
        }
        deinit { channels.deallocate() }
    }

    private static func outputLayout(device: AudioObjectID) -> OutputLayout? {
        guard let bufferChannels = CA.outputBufferChannels(device), (1...2).contains(bufferChannels.count) else { return nil }
        let streams = CA.array(device, CA.address(kAudioDevicePropertyStreams, kAudioDevicePropertyScopeOutput),
                               of: AudioStreamID.self)
        guard (1...2).contains(streams.count) else { return nil }
        let formats = streams.map { stream in
            CA.value(stream, CA.address(kAudioStreamPropertyVirtualFormat), default: AudioStreamBasicDescription())
        }
        return OutputLayout(bufferChannels: bufferChannels, streamFormats: formats)
    }

    static func validOutputFrames(_ buffers: UnsafeMutableAudioBufferListPointer,
                                  layout: OutputLayout) -> Int? {
        layout.bufferChannels.withUnsafeBufferPointer { channels in
            validOutputFrames(buffers, channels: channels.baseAddress, count: channels.count)
        }
    }

    @inline(__always)
    static func validOutputFrames(_ buffers: UnsafeMutableAudioBufferListPointer,
                                  channels: UnsafePointer<Int>?, count: Int) -> Int? {
        guard buffers.count == count, let channels else { return nil }
        var frames: Int?
        var index = 0
        while index < count {
            let buffer = buffers[index]
            let expected = channels[index]
            let bytes = MemoryLayout<Float>.size * expected
            guard Int(buffer.mNumberChannels) == expected, buffer.mData != nil,
                  buffer.mDataByteSize > 0, Int(buffer.mDataByteSize) % bytes == 0 else { return nil }
            let available = Int(buffer.mDataByteSize) / bytes
            if let frames, frames != available { return nil }
            frames = available
            index += 1
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
                    // A registered IOProc can survive a failed AudioDeviceStart; "not running" is safe to destroy.
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
    private(set) var aggregateID: AudioObjectID {
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

    /// Fade-in length in frames (~43 ms at 48 kHz) applied to the rendered path after the aggregate goes live.
    private static let fadeInFrames = 2048

    private var buildFailure: BuildFailure?

    init(taps orderedTaps: [Tap], resources: IOResources = IOResources()) {
        self.taps = orderedTaps
        self.resources = resources
        self.tapIndexByID = Dictionary(uniqueKeysWithValues: orderedTaps.enumerated().map { ($0.element.sourceID, $0.offset) })
        self.cells = RouterAtomicCells(count: orderedTaps.count)
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
        cells.storeGain(i, left: l, right: r)
    }

    func tapIndex(sourceID: String) -> Int? { tapIndexByID[sourceID] }

    /// Taps whose capture clock differs from the aggregate's output clock; drift compensation stays off.
    static func sampleRateMismatchCount(tapRates: [Double], outputRate: Double) -> Int {
        tapRates.filter { !$0.isFinite || abs($0 - outputRate) > 0.5 }.count
    }

    func healthSnapshot() -> HealthSnapshot {
        HealthSnapshot(
            fires: cells.load(.fires),
            inputBuffers: cells.load(.inputBuffers),
            inputChannels: cells.load(.inputChannels),
            inputFrames: cells.load(.inputFrames),
            outputBuffers: cells.load(.outputBuffers),
            outputChannels: cells.load(.outputChannels),
            outputFrames: cells.load(.outputFrames),
            outputPeak: Float(bitPattern: cells.outputPeak.load(ordering: .relaxed)),
            limiterHits: cells.load(.limiterHits),
            limiterFailures: cells.load(.limiterFailures),
            sampleRateMismatches: cells.load(.sampleRateMismatches),
            frameDivergenceCallbacks: cells.load(.frameDivergenceCallbacks)
        )
    }

    /// Atomics and frozen metadata only; live HAL format reads belong to the background health scan.
    func sourceHealthSnapshots() -> [SourceHealthSnapshot] {
        taps.enumerated().map { index, tap in
            let format = tap.proc.format
            return SourceHealthSnapshot(
                sourceID: tap.sourceID,
                inputFrames: cells.loadInputFrames(index),
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
        for tap in taps where tap.proc.format.mSampleRate != outSR {
            engineLog.error("router startIO: tap sample rate differs from output source=\(tap.sourceID, privacy: .public) tap=\(tap.proc.format.mSampleRate, privacy: .public) output=\(outSR, privacy: .public)")
        }
        let rateMismatches = Self.sampleRateMismatchCount(tapRates: taps.map(\.proc.format.mSampleRate), outputRate: outSR)
        cells.counter(.sampleRateMismatches).store(rateMismatches, ordering: .relaxed)
        let cells = self.cells
        guard let mixer = RouterInputMixer(channels: taps.map(\.channels), cells: cells, sampleRate: outSR) else {
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
        let rawLayout = RawOutputLayout(outputLayout)
        let readiness = self.readiness

        let block: AudioDeviceIOBlock = { _, inInputData, _, outOutputData, outputTime in
            let sequence = readiness.beginCallback()
            var valid = false
            defer { readiness.completeCallback(sequence, valid: valid) }
            let callbackStart = mach_absolute_time()
            let inABL = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            let outABL = UnsafeMutableAudioBufferListPointer(outOutputData)
            Self.observeLayout(input: inABL, output: outABL, into: cells)
            guard Self.hasValidInputLayout(inABL, channels: mixer.channelCount),
                  Self.validOutputFrames(outABL, channels: rawLayout.channels, count: rawLayout.count) != nil,
                  outABL.count > 0, let firstOutData = outABL[0].mData else {
                for buffer in outABL {
                    if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
                }
                return
            }
            let firstOut = outABL[0]
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
            if mixer.frameCountDiverged {
                cells.counter(.frameDivergenceCallbacks).wrappingIncrement(ordering: .relaxed)
            }

            var mt = 0
            while mt < nTaps {
                let rms = cnt[mt] > 0 ? (sumSq[mt] / Float(cnt[mt])).squareRoot() : 0
                let rmsL = cntL[mt] > 0 ? (sumSqL[mt] / Float(cntL[mt])).squareRoot() : rms
                let rmsR = cntR[mt] > 0 ? (sumSqR[mt] / Float(cntR[mt])).squareRoot() : rmsL
                cells.storeMeters(mt, rms: rms, left: rmsL, right: rmsR)
                if cnt[mt] > 0 {
                    cells.inputFrames(mt).wrappingIncrement(by: cnt[mt], ordering: .relaxed)
                }
                mt += 1
            }

            // Start-up fade-in runs before the limiter so its ramp survives an active limiter.
            let playedNow = lifetime.played
            if playedNow < fadeIn {
                let rampFrames = min(outFrames, fadeIn - playedNow)
                var step = Float(1) / Float(fadeIn)
                var rp = 0
                while rp < outABL.count {
                    let b = outABL[rp]
                    rp += 1
                    guard let data = b.mData else { continue }
                    let ch = max(1, Int(b.mNumberChannels))
                    let p = data.assumingMemoryBound(to: Float.self)
                    var lane = 0
                    while lane < ch {
                        var start = Float(playedNow) / Float(fadeIn)
                        vDSP_vrampmul(p + lane, vDSP_Stride(ch), &start, &step, p + lane, vDSP_Stride(ch), vDSP_Length(rampFrames))
                        lane += 1
                    }
                }
            }
            lifetime.played = min(fadeIn, playedNow + outFrames)

            let failuresBefore = limiter.renderFailures
            if limiter.process(left: out, right: outputRight, stride: outputStride, frames: outFrames) {
                cells.counter(.limiterHits).wrappingIncrement(ordering: .relaxed)
                diagnostics.interventions.store(CallbackDiagnostics.increment(diagnostics.interventions.load(ordering: .relaxed)), ordering: .relaxed)
            }
            diagnostics.inputOverCeiling.store(limiter.inputOverCeilingCallbacks, ordering: .relaxed)
            diagnostics.guardedSamples.store(limiter.guardedSamples, ordering: .relaxed)
            diagnostics.renderFailures.store(limiter.renderFailures, ordering: .relaxed)
            cells.counter(.limiterFailures).store(Int(truncatingIfNeeded: limiter.renderFailures), ordering: .relaxed)

            var peak: Float = 0
            if planarStereo {
                let nL = Int(outABL[0].mDataByteSize) / MemoryLayout<Float>.size
                peak = DSPKernels.peakMagnitudeVDSP(out, count: nL)
                if let rightOut {
                    let nR = Int(outABL[1].mDataByteSize) / MemoryLayout<Float>.size
                    peak = max(peak, DSPKernels.peakMagnitudeVDSP(rightOut, count: nR))
                }
            } else {
                let n = Int(outABL[0].mDataByteSize) / MemoryLayout<Float>.size
                peak = DSPKernels.peakMagnitudeVDSP(out, count: n)
            }
            cells.counter(.fires).wrappingIncrement(ordering: .relaxed)
            cells.counter(.inputBuffers).store(nBufs, ordering: .relaxed)
            cells.counter(.inputChannels).store(inChTotal, ordering: .relaxed)
            cells.counter(.inputFrames).store(outFrames, ordering: .relaxed)
            cells.counter(.outputBuffers).store(outABL.count, ordering: .relaxed)
            cells.counter(.outputChannels).store(firstOutCh, ordering: .relaxed)
            cells.counter(.outputFrames).store(outFrames, ordering: .relaxed)
            cells.outputPeak.store(peak.bitPattern, ordering: .relaxed)
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
        bamLog("router startIO createStatus=\(cst) startStatus=\(sst) expectInChans=\(mixer.channelCount) limiterDelay=\(limiter.delayFrames) rateMismatches=\(rateMismatches)")
        if sst != noErr { buildFailure = .startIO(sst) }

        Task { [cells] in
            for _ in 0..<6 {
                try? await Task.sleep(for: .seconds(2))
                let pk = Float(bitPattern: cells.outputPeak.load(ordering: .relaxed))
                bamLog("router fires=\(cells.load(.fires)) inBufs=\(cells.load(.inputBuffers)) inChTotal=\(cells.load(.inputChannels)) inFrames=\(cells.load(.inputFrames)) outBufs=\(cells.load(.outputBuffers)) outCh0=\(cells.load(.outputChannels)) outFrames=\(cells.load(.outputFrames)) outPeak=\(pk) limiterHits=\(cells.load(.limiterHits)) frameDivergence=\(cells.load(.frameDivergenceCallbacks))")
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
