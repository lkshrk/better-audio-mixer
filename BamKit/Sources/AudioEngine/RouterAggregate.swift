import Accelerate
import Atomics
import BamCore
import CoreAudio
import Foundation

/// Single hardware-clocked aggregate that captures every source tap together
/// with the selected output device, summing each tap × its live gain into the
/// output inside one IOProc. One clock domain (the output device drives the
/// aggregate) → no ring buffer, no capture/playback clock split, no underrun
/// race. The taps are `.mutedWhenTapped`, so each captured app's own output is
/// silenced and only bam's summed mix reaches the hardware.
final class RouterAggregate {
    enum BuildFailure: Equatable {
        case createAggregate(OSStatus)
        case createIOProc(OSStatus)
        case startIO(OSStatus)
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
        let gainL = AtomicFloat(0)
        let gainR = AtomicFloat(0)
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
    /// Global input channel index → (owning tap, isRight). Built assuming the
    /// aggregate presents tap channels in tap-list order; confirmed at runtime
    /// via the diagnostic counters below.
    private let channelMap: [(tap: Int, right: Bool)]

    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var sumSqScratch: UnsafeMutablePointer<Float>?
    private var sumSqLScratch: UnsafeMutablePointer<Float>?
    private var sumSqRScratch: UnsafeMutablePointer<Float>?
    private var cntScratch: UnsafeMutablePointer<Int>?
    private var cntLScratch: UnsafeMutablePointer<Int>?
    private var cntRScratch: UnsafeMutablePointer<Int>?
    private var chTapScratch: UnsafeMutablePointer<Int>?
    private var chRightScratch: UnsafeMutablePointer<Int>?
    private var limiterGainScratch: UnsafeMutablePointer<Float>?
    /// Frames elapsed since this aggregate's IOProc started, used for the
    /// start-up fade-in. Single-writer (the audio thread), so a plain pointer is
    /// safe and lock-free; no atomic needed.
    private var playedScratch: UnsafeMutablePointer<Int>?
    // Lookahead limiter state — all preallocated in startIO, freed in teardown.
    private var laRingScratch: UnsafeMutablePointer<Float>?   // laFrames*2 floats (L then R section)
    private var laIdxScratch: UnsafeMutablePointer<Int>?      // write index [0, laFrames)
    private var laFramesScratch: UnsafeMutablePointer<Int>?   // lookahead depth in frames
    private var laEnvScratch: UnsafeMutablePointer<Float>?    // current envelope [0,1]
    private var laAttackScratch: UnsafeMutablePointer<Float>? // precomputed attack coeff
    private var laReleaseScratch: UnsafeMutablePointer<Float>?// precomputed release coeff

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
    private var buildFailure: BuildFailure?

    init?(outputUID: String, taps orderedTaps: [Tap], failure: inout BuildFailure?) {
        guard !orderedTaps.isEmpty else { return nil }
        self.taps = orderedTaps

        var idx: [String: Int] = [:]
        var cmap: [(tap: Int, right: Bool)] = []
        for (i, t) in orderedTaps.enumerated() {
            idx[t.sourceID] = i
            for c in 0..<t.channels { cmap.append((tap: i, right: c % 2 == 1)) }
        }
        self.tapIndexByID = idx
        self.channelMap = cmap

        guard createAggregate(outputUID: outputUID), startIO() else {
            failure = buildFailure
            teardown()
            return nil
        }
        failure = nil
    }

    deinit { teardown() }

    /// Effective per-source L/R gain, folded off the audio thread.
    func setGain(sourceID: String, l: Float, r: Float) {
        guard let i = tapIndexByID[sourceID] else { return }
        taps[i].gainL.store(l)
        taps[i].gainR.store(r)
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
            limiterHits: dLimiterHits.load(ordering: .relaxed)
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
            "router createAggregate out=\(outputUID, privacy: .private) taps=\(self.taps.count, privacy: .public) inChans=\(self.channelMap.count, privacy: .public) status=\(st, privacy: .public) aggID=\(self.aggregateID, privacy: .public)"
        )
        let ok = st == noErr && aggregateID != AudioObjectID(kAudioObjectUnknown)
        if !ok { buildFailure = .createAggregate(st) }
        return ok
    }

    private func startIO() -> Bool {
        let nTaps = taps.count
        let mapCount = channelMap.count

        let sumSq = UnsafeMutablePointer<Float>.allocate(capacity: max(1, nTaps))
        let sumSqL = UnsafeMutablePointer<Float>.allocate(capacity: max(1, nTaps))
        let sumSqR = UnsafeMutablePointer<Float>.allocate(capacity: max(1, nTaps))
        let cnt = UnsafeMutablePointer<Int>.allocate(capacity: max(1, nTaps))
        let cntL = UnsafeMutablePointer<Int>.allocate(capacity: max(1, nTaps))
        let cntR = UnsafeMutablePointer<Int>.allocate(capacity: max(1, nTaps))
        sumSq.initialize(repeating: 0, count: max(1, nTaps))
        sumSqL.initialize(repeating: 0, count: max(1, nTaps))
        sumSqR.initialize(repeating: 0, count: max(1, nTaps))
        cnt.initialize(repeating: 0, count: max(1, nTaps))
        cntL.initialize(repeating: 0, count: max(1, nTaps))
        cntR.initialize(repeating: 0, count: max(1, nTaps))
        sumSqScratch = sumSq
        sumSqLScratch = sumSqL
        sumSqRScratch = sumSqR
        cntScratch = cnt
        cntLScratch = cntL
        cntRScratch = cntR

        // Flat primitive channel map. The RT block indexes these instead of the
        // tuple array `channelMap`, so the audio thread never instantiates tuple
        // or Range generic metadata — doing so under the runtime's metadata lock
        // can deadlock against the actor thread blocked inside AudioDeviceStart.
        let chTap = UnsafeMutablePointer<Int>.allocate(capacity: max(1, mapCount))
        let chRight = UnsafeMutablePointer<Int>.allocate(capacity: max(1, mapCount))
        var mi = 0
        while mi < mapCount {
            chTap[mi] = channelMap[mi].tap
            chRight[mi] = channelMap[mi].right ? 1 : 0
            mi += 1
        }
        chTapScratch = chTap
        chRightScratch = chRight

        let played = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        played.initialize(to: 0)
        playedScratch = played
        let fadeIn = Self.fadeInFrames
        let limiterGain = UnsafeMutablePointer<Float>.allocate(capacity: 1)
        limiterGain.initialize(to: 1)
        limiterGainScratch = limiterGain

        let outSR = CA.float64(aggregateID, CA.address(kAudioDevicePropertyNominalSampleRate)) ?? 48000
        let laFrames = AudioLimiter.lookaheadFrames(sampleRate: outSR, lookaheadMs: 1.5)
        // Two sections: [0, laFrames) = L channel, [laFrames, 2*laFrames) = R channel.
        let laRing = UnsafeMutablePointer<Float>.allocate(capacity: laFrames * 2)
        laRing.initialize(repeating: 0, count: laFrames * 2)
        laRingScratch = laRing
        let laIdx = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        laIdx.initialize(to: 0)
        laIdxScratch = laIdx
        let laFramesPtr = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        laFramesPtr.initialize(to: laFrames)
        laFramesScratch = laFramesPtr
        let laEnv = UnsafeMutablePointer<Float>.allocate(capacity: 1)
        laEnv.initialize(to: 1)
        laEnvScratch = laEnv
        let laAttack = UnsafeMutablePointer<Float>.allocate(capacity: 1)
        laAttack.initialize(to: AudioLimiter.attackCoeff(sampleRate: outSR, ms: 1))
        laAttackScratch = laAttack
        let laRelease = UnsafeMutablePointer<Float>.allocate(capacity: 1)
        laRelease.initialize(to: AudioLimiter.releaseCoeff(sampleRate: outSR, ms: 100))
        laReleaseScratch = laRelease

        let gainL = taps.map(\.gainL)
        let gainR = taps.map(\.gainR)
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
        let laRingC = laRing, laIdxC = laIdx, laFramesC = laFrames
        let laEnvC = laEnv, laAttackC = laAttack, laReleaseC = laRelease

        let block: AudioDeviceIOBlock = { _, inInputData, _, outOutputData, _ in
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
            var tz = 0
            while tz < nTaps {
                sumSq[tz] = 0
                sumSqL[tz] = 0
                sumSqR[tz] = 0
                cnt[tz] = 0
                cntL[tz] = 0
                cntR[tz] = 0
                tz += 1
            }

            // Walk input as one flat channel sequence in ABL order, which equals
            // tap-list order. Each channel sums into the output L or R by its
            // tap's gain; pre-gain RMS feeds that tap's meter.
            var globalCh = 0
            var inChTotal = 0
            let nBufs = inABL.count
            var bi = 0
            while bi < nBufs {
                let buf = inABL[bi]
                bi += 1
                guard let data = buf.mData else { continue }
                let bch = Int(buf.mNumberChannels)
                guard bch > 0 else { continue }
                inChTotal += bch
                let bframes = Int(buf.mDataByteSize) / (MemoryLayout<Float>.size * bch)
                let p = data.assumingMemoryBound(to: Float.self)
                let frames = bframes < outFrames ? bframes : outFrames
                var localCh = 0
                while localCh < bch {
                    let gc = globalCh + localCh
                    if gc < mapCount {
                        let tIdx = chTap[gc]
                        let isR = chRight[gc] == 1
                        let g = isR ? gainR[tIdx].load() : gainL[tIdx].load()
                        let srcBase = p + localCh
                        let ss: Float
                        if planarStereo, isR, let rightOut {
                            DSPKernels.sumScaledVDSP(src: srcBase, stride: bch, gain: g,
                                                     dst: rightOut, dstStride: 1, frames: frames)
                            ss = DSPKernels.sumOfSquaresVDSP(src: srcBase, stride: bch, frames: frames)
                        } else if planarStereo {
                            DSPKernels.sumScaledVDSP(src: srcBase, stride: bch, gain: g,
                                                     dst: out, dstStride: 1, frames: frames)
                            ss = DSPKernels.sumOfSquaresVDSP(src: srcBase, stride: bch, frames: frames)
                        } else {
                            let dstCh = firstOutCh >= 2 ? (isR ? 1 : 0) : 0
                            DSPKernels.sumScaledVDSP(src: srcBase, stride: bch, gain: g,
                                                     dst: out + dstCh, dstStride: firstOutCh, frames: frames)
                            ss = DSPKernels.sumOfSquaresVDSP(src: srcBase, stride: bch, frames: frames)
                        }
                        sumSq[tIdx] += ss
                        cnt[tIdx] += frames
                        if isR {
                            sumSqR[tIdx] += ss
                            cntR[tIdx] += frames
                        } else {
                            sumSqL[tIdx] += ss
                            cntL[tIdx] += frames
                        }
                    }
                    localCh += 1
                }
                globalCh += bch
            }

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
            let playedNow = played[0]
            var rp = 0
            while rp < outABL.count {
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
            played[0] = playedNow + outFrames

            // Lookahead limiter: delay output by laFrames through a per-channel ring,
            // compute incoming peak, drive envelope, apply to the delayed output.
            // Ring layout: [0, la) = L-channel frames, [la, 2*la) = R-channel frames.
            // Each "slot" holds one mono sample; both channels advance the same index
            // so latency is identical — the accepted ~1.5 ms tradeoff for no pumping.
            let la = laFramesC
            let writeIdx = laIdxC[0]

            // Peak over the incoming (pre-delay) output to drive the look-ahead.
            var incomingPeak: Float = 0
            if planarStereo {
                let nL = Int(outABL[0].mDataByteSize) / MemoryLayout<Float>.size
                if let dL = outABL[0].mData {
                    let pkL = DSPKernels.peakMagnitudeVDSP(dL.assumingMemoryBound(to: Float.self), count: nL)
                    if pkL > incomingPeak { incomingPeak = pkL }
                }
                if let dR = rightOutData {
                    let nR = Int(outABL[1].mDataByteSize) / MemoryLayout<Float>.size
                    let pkR = DSPKernels.peakMagnitudeVDSP(dR.assumingMemoryBound(to: Float.self), count: nR)
                    if pkR > incomingPeak { incomingPeak = pkR }
                }
            } else {
                let n = Int(outABL[0].mDataByteSize) / MemoryLayout<Float>.size
                if let d = outABL[0].mData {
                    let pk = DSPKernels.peakMagnitudeVDSP(d.assumingMemoryBound(to: Float.self), count: n)
                    if pk > incomingPeak { incomingPeak = pk }
                }
            }

            let target = AudioLimiter.targetGain(forPeak: incomingPeak, ceiling: 1.0)
            let env = AudioLimiter.nextEnvelope(current: laEnvC[0], targetGain: target,
                                                attackCoeff: laAttackC[0], releaseCoeff: laReleaseC[0])
            laEnvC[0] = env
            if env < 1 { dLimiterHits.wrappingIncrement(ordering: .relaxed) }

            // Swap current output with ring contents, then scale by envelope.
            if planarStereo {
                // L channel in ring[0..<la], R channel in ring[la..<2*la].
                if let dL = outABL[0].mData {
                    let pL = dL.assumingMemoryBound(to: Float.self)
                    var fi = 0
                    while fi < outFrames {
                        let slot = (writeIdx + fi) % la
                        let delayed = laRingC[slot]
                        laRingC[slot] = pL[fi]
                        pL[fi] = delayed
                        fi += 1
                    }
                    var gs = env
                    vDSP_vsmul(pL, 1, &gs, pL, 1, vDSP_Length(outFrames))
                }
                if let dR = rightOutData {
                    let pR = dR.assumingMemoryBound(to: Float.self)
                    var fi = 0
                    while fi < outFrames {
                        let slot = la + (writeIdx + fi) % la
                        let delayed = laRingC[slot]
                        laRingC[slot] = pR[fi]
                        pR[fi] = delayed
                        fi += 1
                    }
                    var gs = env
                    vDSP_vsmul(pR, 1, &gs, pR, 1, vDSP_Length(outFrames))
                }
            } else {
                // Interleaved: delay frame-by-frame. L ring[0..<la], R ring[la..<2*la].
                // For mono (firstOutCh==1) only the L ring is used.
                let p = out
                if firstOutCh == 1 {
                    var fi = 0
                    while fi < outFrames {
                        let slot = (writeIdx + fi) % la
                        let delayed = laRingC[slot]
                        laRingC[slot] = p[fi]
                        p[fi] = delayed
                        fi += 1
                    }
                    var gs = env
                    vDSP_vsmul(p, 1, &gs, p, 1, vDSP_Length(outFrames))
                } else {
                    // Interleaved stereo: deinterleave into L/R rings, delay, reinterleave.
                    var fi = 0
                    while fi < outFrames {
                        let slotL = (writeIdx + fi) % la
                        let slotR = la + (writeIdx + fi) % la
                        let delayedL = laRingC[slotL]
                        let delayedR = laRingC[slotR]
                        laRingC[slotL] = p[fi * firstOutCh]
                        laRingC[slotR] = p[fi * firstOutCh + 1]
                        p[fi * firstOutCh]     = delayedL * env
                        p[fi * firstOutCh + 1] = delayedR * env
                        fi += 1
                    }
                }
            }
            laIdxC[0] = (writeIdx + outFrames) % la

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
        }

        let cst = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil, block)
        guard cst == noErr, ioProcID != nil else {
            bamLog("router createIOProc FAILED status=\(cst)")
            buildFailure = .createIOProc(cst)
            return false
        }
        let sst = AudioDeviceStart(aggregateID, ioProcID)
        bamLog("router startIO createStatus=\(cst) startStatus=\(sst) expectInChans=\(mapCount)")
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

    private func teardown() {
        if let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        sumSqScratch?.deallocate(); sumSqScratch = nil
        sumSqLScratch?.deallocate(); sumSqLScratch = nil
        sumSqRScratch?.deallocate(); sumSqRScratch = nil
        cntScratch?.deallocate(); cntScratch = nil
        cntLScratch?.deallocate(); cntLScratch = nil
        cntRScratch?.deallocate(); cntRScratch = nil
        chTapScratch?.deallocate(); chTapScratch = nil
        chRightScratch?.deallocate(); chRightScratch = nil
        playedScratch?.deallocate(); playedScratch = nil
        limiterGainScratch?.deallocate(); limiterGainScratch = nil
        laRingScratch?.deallocate(); laRingScratch = nil
        laIdxScratch?.deallocate(); laIdxScratch = nil
        laFramesScratch?.deallocate(); laFramesScratch = nil
        laEnvScratch?.deallocate(); laEnvScratch = nil
        laAttackScratch?.deallocate(); laAttackScratch = nil
        laReleaseScratch?.deallocate(); laReleaseScratch = nil
    }
}
