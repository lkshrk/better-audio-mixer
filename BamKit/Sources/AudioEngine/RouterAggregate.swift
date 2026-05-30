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
    /// One captured source: its tap, channel count, live L/R gain and meter.
    final class Tap {
        let sourceID: String
        let proc: ProcessTap
        let channels: Int
        let gainL = AtomicFloat(0)
        let gainR = AtomicFloat(0)
        let meter = AtomicFloat(RMSMeter.floorDB)

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
    private var cntScratch: UnsafeMutablePointer<Int>?
    private var chTapScratch: UnsafeMutablePointer<Int>?
    private var chRightScratch: UnsafeMutablePointer<Int>?
    /// Frames elapsed since this aggregate's IOProc started, used for the
    /// start-up fade-in. Single-writer (the audio thread), so a plain pointer is
    /// safe and lock-free; no atomic needed.
    private var playedScratch: UnsafeMutablePointer<Int>?

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
    private let dOutCh = ManagedAtomic<Int>(0)
    private let dOutFrames = ManagedAtomic<Int>(0)
    private let dOutPeak = ManagedAtomic<UInt32>(0)

    init?(outputUID: String, taps orderedTaps: [Tap]) {
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
            teardown()
            return nil
        }
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

    private func createAggregate(outputUID: String) -> Bool {
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
        bamLog("router createAggregate out=\(outputUID) taps=\(taps.count) inChans=\(channelMap.count) status=\(st) aggID=\(aggregateID)")
        return st == noErr && aggregateID != AudioObjectID(kAudioObjectUnknown)
    }

    private func startIO() -> Bool {
        let nTaps = taps.count
        let mapCount = channelMap.count

        let sumSq = UnsafeMutablePointer<Float>.allocate(capacity: max(1, nTaps))
        let cnt = UnsafeMutablePointer<Int>.allocate(capacity: max(1, nTaps))
        sumSq.initialize(repeating: 0, count: max(1, nTaps))
        cnt.initialize(repeating: 0, count: max(1, nTaps))
        sumSqScratch = sumSq
        cntScratch = cnt

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

        let gainL = taps.map(\.gainL)
        let gainR = taps.map(\.gainR)
        let meters = taps.map(\.meter)

        let dFires = self.dFires, dInBufs = self.dInBufs, dInCh0 = self.dInCh0
        let dInChTotal = self.dInChTotal, dInFrames = self.dInFrames
        let dOutCh = self.dOutCh, dOutFrames = self.dOutFrames, dOutPeak = self.dOutPeak

        let block: AudioDeviceIOBlock = { _, inInputData, _, outOutputData, _ in
            let inABL = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            let outABL = UnsafeMutableAudioBufferListPointer(outOutputData)
            guard outABL.count > 0 else { return }
            let outBuf = outABL[0]
            guard let outData = outBuf.mData else { return }
            let outCh = Int(outBuf.mNumberChannels)
            guard outCh > 0 else { return }
            let outFrames = Int(outBuf.mDataByteSize) / (MemoryLayout<Float>.size * outCh)
            let out = outData.assumingMemoryBound(to: Float.self)
            let outTotal = outFrames * outCh

            var z = 0
            while z < outTotal { out[z] = 0; z += 1 }
            var tz = 0
            while tz < nTaps { sumSq[tz] = 0; cnt[tz] = 0; tz += 1 }

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
                        let dstCh = outCh >= 2 ? (isR ? 1 : 0) : 0
                        var ss: Float = 0
                        var f = 0
                        while f < frames {
                            let s = p[f * bch + localCh]
                            ss += s * s
                            out[f * outCh + dstCh] += s * g
                            f += 1
                        }
                        sumSq[tIdx] += ss
                        cnt[tIdx] += frames
                    }
                    localCh += 1
                }
                globalCh += bch
            }

            var mt = 0
            while mt < nTaps {
                let rms = cnt[mt] > 0 ? (sumSq[mt] / Float(cnt[mt])).squareRoot() : 0
                meters[mt].store(RMSMeter.dbFS(rms: rms))
                mt += 1
            }

            // Start-up fade-in (declick) + hard limiter (anti-overflow), folded
            // with the peak scan. The ramp lifts the first `fadeIn` frames 0→1 so
            // a freshly started aggregate never steps from silence to full level;
            // the ±1 clamp bounds summed overflow so stacked sources clip cleanly
            // instead of wrapping. Both are pure RT arithmetic, no locks/IO.
            let playedNow = played[0]
            var peak: Float = 0
            var pz = 0
            while pz < outTotal {
                let frame = pz / outCh
                let r = playedNow + frame
                let ramp = r >= fadeIn ? 1 : Float(r) / Float(fadeIn)
                var v = out[pz] * ramp
                if v > 1 { v = 1 } else if v < -1 { v = -1 }
                out[pz] = v
                let a = v < 0 ? -v : v
                if a > peak { peak = a }
                pz += 1
            }
            played[0] = playedNow + outFrames
            dFires.wrappingIncrement(ordering: .relaxed)
            dInBufs.store(nBufs, ordering: .relaxed)
            dInCh0.store(nBufs > 0 ? Int(inABL[0].mNumberChannels) : 0, ordering: .relaxed)
            dInChTotal.store(inChTotal, ordering: .relaxed)
            dInFrames.store(outFrames, ordering: .relaxed)
            dOutCh.store(outCh, ordering: .relaxed)
            dOutFrames.store(outFrames, ordering: .relaxed)
            if peak > Float(bitPattern: dOutPeak.load(ordering: .relaxed)) {
                dOutPeak.store(peak.bitPattern, ordering: .relaxed)
            }
        }

        let cst = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil, block)
        guard cst == noErr, ioProcID != nil else {
            bamLog("router createIOProc FAILED status=\(cst)")
            return false
        }
        let sst = AudioDeviceStart(aggregateID, ioProcID)
        bamLog("router startIO createStatus=\(cst) startStatus=\(sst) expectInChans=\(mapCount)")

        Task { [dFires, dInBufs, dInCh0, dInChTotal, dInFrames, dOutCh, dOutFrames, dOutPeak] in
            for _ in 0..<6 {
                try? await Task.sleep(for: .seconds(2))
                let pk = Float(bitPattern: dOutPeak.load(ordering: .relaxed))
                bamLog("router fires=\(dFires.load(ordering: .relaxed)) inBufs=\(dInBufs.load(ordering: .relaxed)) inCh0=\(dInCh0.load(ordering: .relaxed)) inChTotal=\(dInChTotal.load(ordering: .relaxed)) inFrames=\(dInFrames.load(ordering: .relaxed)) outCh=\(dOutCh.load(ordering: .relaxed)) outFrames=\(dOutFrames.load(ordering: .relaxed)) outPeak=\(pk)")
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
        cntScratch?.deallocate(); cntScratch = nil
        chTapScratch?.deallocate(); chTapScratch = nil
        chRightScratch?.deallocate(); chRightScratch = nil
        playedScratch?.deallocate(); playedScratch = nil
    }
}
