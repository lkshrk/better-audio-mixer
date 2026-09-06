import CoreAudio
import Foundation

/// The production input-mixing path, usable without opening a tap or device.
/// Prepared off-thread; only the IOProc mutates ramps and meter scratch.
final class RouterInputMixer {
    let gains: [AtomicStereoGain]
    let count: Int
    let channelCount: Int
    private let channelTap: UnsafeMutablePointer<Int>
    private let channelSide: UnsafeMutablePointer<Int>
    private let leftRamp: UnsafeMutablePointer<GainRamp>
    private let rightRamp: UnsafeMutablePointer<GainRamp>
    let sumSq: UnsafeMutablePointer<Float>
    let sumSqL: UnsafeMutablePointer<Float>
    let sumSqR: UnsafeMutablePointer<Float>
    let frames: UnsafeMutablePointer<Int>
    let framesL: UnsafeMutablePointer<Int>
    let framesR: UnsafeMutablePointer<Int>

    init?(channels: [Int], gains: [AtomicStereoGain], sampleRate: Double) {
        guard !channels.isEmpty, channels.count == gains.count,
              channels.allSatisfy({ $0 == 1 || $0 == 2 }),
              sampleRate.isFinite, sampleRate > 0 else { return nil }
        self.gains = gains
        count = channels.count
        channelCount = channels.reduce(0, +)
        channelTap = .allocate(capacity: channelCount)
        channelSide = .allocate(capacity: channelCount)
        var offset = 0
        for (tap, channels) in channels.enumerated() {
            for side in 0..<channels {
                channelTap[offset] = tap
                channelSide[offset] = channels == 1 ? 2 : side
                offset += 1
            }
        }
        leftRamp = .allocate(capacity: count)
        rightRamp = .allocate(capacity: count)
        let ramp = GainRamp(length: max(1, Int((sampleRate * 0.005).rounded())))
        leftRamp.initialize(repeating: ramp, count: count)
        rightRamp.initialize(repeating: ramp, count: count)
        sumSq = .allocate(capacity: count); sumSq.initialize(repeating: 0, count: count)
        sumSqL = .allocate(capacity: count); sumSqL.initialize(repeating: 0, count: count)
        sumSqR = .allocate(capacity: count); sumSqR.initialize(repeating: 0, count: count)
        frames = .allocate(capacity: count); frames.initialize(repeating: 0, count: count)
        framesL = .allocate(capacity: count); framesL.initialize(repeating: 0, count: count)
        framesR = .allocate(capacity: count); framesR.initialize(repeating: 0, count: count)
    }

    deinit {
        channelTap.deallocate(); channelSide.deallocate()
        leftRamp.deinitialize(count: count); leftRamp.deallocate()
        rightRamp.deinitialize(count: count); rightRamp.deallocate()
        sumSq.deallocate(); sumSqL.deallocate(); sumSqR.deallocate()
        frames.deallocate(); framesL.deallocate(); framesR.deallocate()
    }

    /// Adds to already-zeroed output. Null input retains its channel positions.
    @discardableResult
    func mix(_ input: UnsafePointer<AudioBufferList>, left: UnsafeMutablePointer<Float>,
             right: UnsafeMutablePointer<Float>?, outputStride: Int, outputFrames: Int) -> Int {
        var tap = 0
        while tap < count {
            let target = gains[tap].load()
            leftRamp[tap].setTarget(Float(bitPattern: UInt32(truncatingIfNeeded: target)))
            rightRamp[tap].setTarget(Float(bitPattern: UInt32(truncatingIfNeeded: target >> 32)))
            sumSq[tap] = 0; sumSqL[tap] = 0; sumSqR[tap] = 0
            frames[tap] = 0; framesL[tap] = 0; framesR[tap] = 0
            tap += 1
        }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        var channel = 0
        var bufferIndex = 0
        while bufferIndex < buffers.count {
            let buffer = buffers[bufferIndex]
            bufferIndex += 1
            let channels = Int(buffer.mNumberChannels)
            let base = channel
            channel += channels
            guard channels > 0, let data = buffer.mData else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            let available = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            let n = min(available, outputFrames)
            guard n > 0 else { continue }
            var local = 0
            while local < channels, base + local < channelCount {
                let t = channelTap[base + local]
                let side = channelSide[base + local]
                let source = samples + local
                let ss = DSPKernels.sumOfSquaresVDSP(src: source, stride: channels, frames: n)
                let scale: Float = right == nil ? 0.5 : 1
                if side != 1 {
                    DSPKernels.sumRamped(src: source, stride: channels, ramp: &leftRamp[t], scale: scale,
                                         dst: left, dstStride: outputStride, frames: n)
                    sumSqL[t] += ss; framesL[t] += n
                }
                if side != 0 {
                    DSPKernels.sumRamped(src: source, stride: channels, ramp: &rightRamp[t], scale: scale,
                                         dst: right ?? left, dstStride: outputStride, frames: n)
                    sumSqR[t] += ss; framesR[t] += n
                }
                sumSq[t] += ss; frames[t] += n
                local += 1
            }
        }
        tap = 0
        while tap < count {
            // Silent/truncated buffers still consume time in a control ramp.
            leftRamp[tap].advance(max(0, outputFrames - framesL[tap]))
            rightRamp[tap].advance(max(0, outputFrames - framesR[tap]))
            tap += 1
        }
        return channel
    }
}
