import Atomics
import BamCore
import CoreAudio
import Foundation

/// Capture chain for one source: tap → private aggregate → IOProc.
///
/// Read-only mode (`outputDeviceUID == nil`): aggregate wraps only the tap; the
/// IOProc computes RMS into `slot`. App audio keeps flowing through its normal
/// output untouched.
///
/// Enforcing mode (`outputDeviceUID != nil`): the tap is created with
/// `.mutedWhenTapped` so the app's normal output is silenced; the aggregate adds
/// the output device as a sub-device, and the IOProc re-renders the tapped audio
/// scaled by `gain` to that device while still metering pre-gain RMS.
final class TapChain {
    let slot = AtomicFloat(RMSMeter.floorDB)
    let gain = AtomicFloat(1.0)

    private let tap: ProcessTap
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let outputDeviceUID: String?
    /// v3 capture sink: in read-only mode the IOProc writes tapped PCM here for
    /// the central Mixer to pull. nil = meter-only (v1/v2 behavior).
    private let ring: RingBuffer?
    private let ringChannels: Int
    private let ringScratch: UnsafeMutablePointer<Float>?
    private let ringScratchFrames = 8192
    private let fireCount = ManagedAtomic<Int>(0)
    private let dInN = ManagedAtomic<Int>(0)
    private let dOutN = ManagedAtomic<Int>(0)
    private let dInBufs = ManagedAtomic<Int>(0)
    private let dOutBufs = ManagedAtomic<Int>(0)
    private let dPeakIn = ManagedAtomic<UInt32>(0)
    private let dPeakOut = ManagedAtomic<UInt32>(0)

    init?(description: CATapDescription, outputDeviceUID: String? = nil, ring: RingBuffer? = nil) {
        // Mute the app's original output when this chain owns its audio: either
        // the v2 enforcing path (outputDeviceUID) or the v3 router (ring sink).
        // The router feeds audio back to hardware via a Monitor mix.
        description.muteBehavior = (outputDeviceUID != nil || ring != nil) ? .mutedWhenTapped : .unmuted
        self.outputDeviceUID = outputDeviceUID
        self.ring = ring
        guard let tap = ProcessTap(description: description) else { return nil }
        self.tap = tap
        self.ringChannels = ring != nil ? Int(tap.format.mChannelsPerFrame) : 0
        self.ringScratch = ring != nil
            ? UnsafeMutablePointer<Float>.allocate(capacity: ringScratchFrames * max(1, ringChannels))
            : nil
        guard createAggregate(), startIO() else {
            teardown()
            return nil
        }
    }

    deinit {
        teardown()
        ringScratch?.deallocate()
    }

    func setGain(_ value: Float) {
        gain.store(value)
    }

    private func createAggregate() -> Bool {
        var dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "bam-\(tap.uuid)",
            kAudioAggregateDeviceUIDKey: "bam-agg-\(tap.uuid)",
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceTapAutoStartKey: 1,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tap.uuid,
                    kAudioSubTapDriftCompensationKey: 0,
                ]
            ],
        ]
        if let outputDeviceUID {
            dict[kAudioAggregateDeviceMainSubDeviceKey] = outputDeviceUID
            dict[kAudioAggregateDeviceSubDeviceListKey] = [
                [kAudioSubDeviceUIDKey: outputDeviceUID]
            ]
        }
        let st = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &aggregateID)
        let f = tap.format
        bamLog("createAggregate out=\(outputDeviceUID ?? "nil") status=\(st) aggID=\(aggregateID) tapFmt sr=\(f.mSampleRate) ch=\(f.mChannelsPerFrame) bits=\(f.mBitsPerChannel) flags=\(f.mFormatFlags)")
        return st == noErr && aggregateID != AudioObjectID(kAudioObjectUnknown)
    }

    private func startIO() -> Bool {
        let slot = self.slot
        let gain = self.gain
        let enforcing = outputDeviceUID != nil

        let fireCount = self.fireCount
        let dInN = self.dInN, dOutN = self.dOutN, dInBufs = self.dInBufs, dOutBufs = self.dOutBufs
        let dPeakIn = self.dPeakIn, dPeakOut = self.dPeakOut
        let ring = self.ring
        let ringChannels = self.ringChannels
        let ringScratch = self.ringScratch
        let ringScratchFrames = self.ringScratchFrames
        let block: AudioDeviceIOBlock = { _, inInputData, _, outOutputData, _ in
            fireCount.wrappingIncrement(ordering: .relaxed)
            let inABL = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inInputData)
            )
            let g = gain.load()
            var sumSquares: Float = 0
            var count = 0
            var peakIn: Float = 0
            var peakOut: Float = 0

            if enforcing {
                let outABL = UnsafeMutableAudioBufferListPointer(outOutputData)
                dInBufs.store(inABL.count, ordering: .relaxed)
                dOutBufs.store(outABL.count, ordering: .relaxed)
                if let ib = inABL.first { dInN.store(Int(ib.mDataByteSize) / MemoryLayout<Float>.size, ordering: .relaxed) }
                if let ob = outABL.first { dOutN.store(Int(ob.mDataByteSize) / MemoryLayout<Float>.size, ordering: .relaxed) }
                for (i, inBuf) in inABL.enumerated() {
                    guard let src = inBuf.mData else { continue }
                    let inN = Int(inBuf.mDataByteSize) / MemoryLayout<Float>.size
                    let s = src.assumingMemoryBound(to: Float.self)
                    if i < outABL.count, let dst = outABL[i].mData {
                        let outN = Int(outABL[i].mDataByteSize) / MemoryLayout<Float>.size
                        let d = dst.assumingMemoryBound(to: Float.self)
                        let n = min(inN, outN)
                        for j in 0..<n {
                            let v = s[j]
                            sumSquares += v * v
                            peakIn = max(peakIn, abs(v))
                            let o = v * g
                            peakOut = max(peakOut, abs(o))
                            d[j] = o
                        }
                        if outN > n {
                            for j in n..<outN { d[j] = 0 }
                        }
                        count += n
                    } else {
                        for j in 0..<inN { sumSquares += s[j] * s[j] }
                        count += inN
                    }
                }
            } else {
                for buffer in inABL {
                    guard let data = buffer.mData else { continue }
                    let n = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                    let ptr = data.assumingMemoryBound(to: Float.self)
                    for j in 0..<n { sumSquares += ptr[j] * ptr[j] }
                    count += n
                }
                // v3 capture: interleave tapped input into the source ring.
                if let ring, let scratch = ringScratch, ringChannels > 0 {
                    let ch = ringChannels
                    if inABL.count == 1, let data = inABL[0].mData {
                        // Already interleaved (typical tap layout): write directly.
                        let frames = Int(inABL[0].mDataByteSize) / (MemoryLayout<Float>.size * ch)
                        ring.write(data.assumingMemoryBound(to: Float.self), frames: frames)
                    } else {
                        // Non-interleaved planar buffers → interleave into scratch.
                        var frames = Int.max
                        for b in inABL {
                            frames = min(frames, Int(b.mDataByteSize) / MemoryLayout<Float>.size)
                        }
                        frames = min(frames, ringScratchFrames)
                        var planes: [UnsafePointer<Float>?] = []
                        planes.reserveCapacity(inABL.count)
                        for b in inABL {
                            let p = b.mData?.assumingMemoryBound(to: Float.self)
                            planes.append(p.map { UnsafePointer<Float>($0) })
                        }
                        interleavePlanar(planes, frames: frames, channels: ch, into: scratch)
                        ring.write(scratch, frames: frames)
                    }
                }
            }

            if enforcing {
                if peakIn > Float(bitPattern: dPeakIn.load(ordering: .relaxed)) {
                    dPeakIn.store(peakIn.bitPattern, ordering: .relaxed)
                }
                if peakOut > Float(bitPattern: dPeakOut.load(ordering: .relaxed)) {
                    dPeakOut.store(peakOut.bitPattern, ordering: .relaxed)
                }
            }
            let rms = count > 0 ? (sumSquares / Float(count)).squareRoot() : 0
            slot.store(RMSMeter.dbFS(rms: rms))
        }

        let cst = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil, block)
        guard cst == noErr, ioProcID != nil else {
            bamLog("createIOProc FAILED status=\(cst)")
            return false
        }
        let sst = AudioDeviceStart(aggregateID, ioProcID)
        bamLog("startIO enforcing=\(enforcing) createStatus=\(cst) startStatus=\(sst)")
        let fc = fireCount
        let aggID = aggregateID
        Task {
            for _ in 0..<6 {
                try? await Task.sleep(for: .seconds(2))
                let sr = CA.float64(aggID, CA.address(kAudioDevicePropertyNominalSampleRate)) ?? -1
                let pIn = Float(bitPattern: dPeakIn.load(ordering: .relaxed))
                let pOut = Float(bitPattern: dPeakOut.load(ordering: .relaxed))
                bamLog("fires=\(fc.load(ordering: .relaxed)) aggSR=\(sr) inBufs=\(dInBufs.load(ordering: .relaxed)) outBufs=\(dOutBufs.load(ordering: .relaxed)) inN=\(dInN.load(ordering: .relaxed)) outN=\(dOutN.load(ordering: .relaxed)) peakIn=\(pIn) peakOut=\(pOut)")
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
    }
}
