import Atomics

/// One contiguous block of lock-free cells shared by the IOProc, the control thread and the meter sampler.
final class RouterAtomicCells: @unchecked Sendable {
    enum Counter: Int, CaseIterable {
        case fires, inputBuffers, inputChannels, inputFrames, outputBuffers, outputChannels, outputFrames
        case limiterHits, limiterFailures, sampleRateMismatches, frameDivergenceCallbacks
        case observedInputBuffers, observedInputChannels, observedInputBytes
        case observedOutputBuffers, observedOutputChannels, observedOutputBytes
    }

    let count: Int
    private let gains: UnsafeMutablePointer<UnsafeAtomic<UInt64>.Storage>
    private let meters: UnsafeMutablePointer<UnsafeAtomic<UInt32>.Storage>
    private let frames: UnsafeMutablePointer<UnsafeAtomic<Int>.Storage>
    private let counters: UnsafeMutablePointer<UnsafeAtomic<Int>.Storage>
    private let peak: UnsafeMutablePointer<UnsafeAtomic<UInt32>.Storage>

    init(count: Int) {
        self.count = max(0, count)
        gains = .allocate(capacity: max(1, self.count))
        meters = .allocate(capacity: max(1, self.count * 3))
        frames = .allocate(capacity: max(1, self.count))
        counters = .allocate(capacity: Counter.allCases.count)
        peak = .allocate(capacity: 1)
        for i in 0..<self.count {
            (gains + i).initialize(to: .init(0))
            (frames + i).initialize(to: .init(0))
        }
        for i in 0..<(self.count * 3) { (meters + i).initialize(to: .init(0)) }
        for i in 0..<Counter.allCases.count { (counters + i).initialize(to: .init(0)) }
        peak.initialize(to: .init(0))
    }

    deinit {
        gains.deinitialize(count: count); gains.deallocate()
        meters.deinitialize(count: count * 3); meters.deallocate()
        frames.deinitialize(count: count); frames.deallocate()
        counters.deinitialize(count: Counter.allCases.count); counters.deallocate()
        peak.deinitialize(count: 1); peak.deallocate()
    }

    @inline(__always) func gain(_ tap: Int) -> UnsafeAtomic<UInt64> { UnsafeAtomic(at: gains + tap) }
    @inline(__always) func meter(_ tap: Int, _ side: Int) -> UnsafeAtomic<UInt32> { UnsafeAtomic(at: meters + tap * 3 + side) }
    @inline(__always) func inputFrames(_ tap: Int) -> UnsafeAtomic<Int> { UnsafeAtomic(at: frames + tap) }
    @inline(__always) func counter(_ id: Counter) -> UnsafeAtomic<Int> { UnsafeAtomic(at: counters + id.rawValue) }
    @inline(__always) var outputPeak: UnsafeAtomic<UInt32> { UnsafeAtomic(at: peak) }

    func storeGain(_ tap: Int, left: Float, right: Float) {
        guard tap >= 0, tap < count else { return }
        let l = left.isFinite ? left : 0
        let r = right.isFinite ? right : 0
        gain(tap).store(UInt64(l.bitPattern) | (UInt64(r.bitPattern) << 32), ordering: .relaxed)
    }

    @inline(__always) func storeMeters(_ tap: Int, rms: Float, left: Float, right: Float) {
        meter(tap, 0).store(rms.bitPattern, ordering: .relaxed)
        meter(tap, 1).store(left.bitPattern, ordering: .relaxed)
        meter(tap, 2).store(right.bitPattern, ordering: .relaxed)
    }

    func loadMeters(_ tap: Int) -> (rms: Float, left: Float, right: Float) {
        guard tap >= 0, tap < count else { return (0, 0, 0) }
        return (Float(bitPattern: meter(tap, 0).load(ordering: .relaxed)),
                Float(bitPattern: meter(tap, 1).load(ordering: .relaxed)),
                Float(bitPattern: meter(tap, 2).load(ordering: .relaxed)))
    }

    func loadInputFrames(_ tap: Int) -> Int {
        guard tap >= 0, tap < count else { return 0 }
        return inputFrames(tap).load(ordering: .relaxed)
    }

    func load(_ id: Counter) -> Int { counter(id).load(ordering: .relaxed) }
}
