import Atomics
import BamCore
import Darwin

/// One render-thread writer. Allocate and initialize the Mach timebase before IO starts.
/// Relaxed readers obtain approximate field-wise snapshots without blocking rendering.
final class CallbackDiagnostics {
    let sampleRate: Double
    let limiterDelayFrames: Int
    private let millisecondsPerTick: Double
    private let count = ManagedAtomic<UInt64>(0)
    private let lastFrames = ManagedAtomic<Int>(0)
    private let minFrames = ManagedAtomic<Int>(Int.max)
    private let maxFrames = ManagedAtomic<Int>(0)
    private let lastMS = ManagedAtomic<UInt64>(0)
    private let meanMS = ManagedAtomic<UInt64>(0)
    private let maxMS = ManagedAtomic<UInt64>(0)
    private let lastRatio = ManagedAtomic<UInt64>(0)
    private let meanRatio = ManagedAtomic<UInt64>(0)
    private let maxRatio = ManagedAtomic<UInt64>(0)
    private let overBudget = ManagedAtomic<UInt64>(0)
    private let hostSamples = ManagedAtomic<UInt64>(0)
    private let hostMisses = ManagedAtomic<UInt64>(0)
    let interventions = ManagedAtomic<UInt64>(0)
    let inputOverCeiling = ManagedAtomic<UInt64>(0)
    let guardedSamples = ManagedAtomic<UInt64>(0)
    let renderFailures = ManagedAtomic<UInt64>(0)

    init(sampleRate: Double, limiterDelayFrames: Int, millisecondsPerTick: Double? = nil) {
        self.sampleRate = sampleRate
        self.limiterDelayFrames = limiterDelayFrames
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        self.millisecondsPerTick = millisecondsPerTick ?? Double(timebase.numer) / Double(timebase.denom) / 1_000_000
        _ = mach_absolute_time()
    }

    static func increment(_ value: UInt64) -> UInt64 { value == .max ? value : value + 1 }
    private func increment(_ counter: ManagedAtomic<UInt64>) {
        counter.store(Self.increment(counter.load(ordering: .relaxed)), ordering: .relaxed)
    }

    func record(start: UInt64, end: UInt64, frames: Int, outputHostTime: UInt64?) {
        guard end >= start, frames > 0, sampleRate.isFinite, sampleRate > 0,
              millisecondsPerTick.isFinite, millisecondsPerTick > 0 else { return }
        let elapsed = Double(end - start) * millisecondsPerTick
        let ratio = elapsed / (Double(frames) / sampleRate * 1000)
        guard elapsed.isFinite, ratio.isFinite else { return }
        increment(count)
        let n = Double(count.load(ordering: .relaxed))
        lastFrames.store(frames, ordering: .relaxed)
        minFrames.store(min(frames, minFrames.load(ordering: .relaxed)), ordering: .relaxed)
        maxFrames.store(max(frames, maxFrames.load(ordering: .relaxed)), ordering: .relaxed)
        update(elapsed, last: lastMS, mean: meanMS, maximum: maxMS, count: n)
        update(ratio, last: lastRatio, mean: meanRatio, maximum: maxRatio, count: n)
        if ratio > 1 { increment(overBudget) }
        if let outputHostTime, outputHostTime > 0 {
            increment(hostSamples)
            if end > outputHostTime { increment(hostMisses) }
        }
    }

    private func update(_ value: Double, last: ManagedAtomic<UInt64>, mean: ManagedAtomic<UInt64>,
                        maximum: ManagedAtomic<UInt64>, count: Double) {
        last.store(value.bitPattern, ordering: .relaxed)
        let prior = Double(bitPattern: mean.load(ordering: .relaxed))
        mean.store((prior + (value - prior) / count).bitPattern, ordering: .relaxed)
        maximum.store(max(value, Double(bitPattern: maximum.load(ordering: .relaxed))).bitPattern, ordering: .relaxed)
    }

    func snapshot() -> AudioDiagnostics {
        var result = AudioDiagnostics()
        result.sampleRate = sampleRate
        result.limiterDelayFrames = limiterDelayFrames
        result.callbackCount = count.load(ordering: .relaxed)
        result.lastFrames = lastFrames.load(ordering: .relaxed)
        let minimum = minFrames.load(ordering: .relaxed)
        result.minFrames = minimum == .max ? 0 : minimum
        result.maxFrames = maxFrames.load(ordering: .relaxed)
        result.lastCallbackMilliseconds = Double(bitPattern: lastMS.load(ordering: .relaxed))
        result.meanCallbackMilliseconds = Double(bitPattern: meanMS.load(ordering: .relaxed))
        result.maxCallbackMilliseconds = Double(bitPattern: maxMS.load(ordering: .relaxed))
        result.lastBudgetRatio = Double(bitPattern: lastRatio.load(ordering: .relaxed))
        result.meanBudgetRatio = Double(bitPattern: meanRatio.load(ordering: .relaxed))
        result.maxBudgetRatio = Double(bitPattern: maxRatio.load(ordering: .relaxed))
        result.overBufferBudgetCount = overBudget.load(ordering: .relaxed)
        result.outputHostTimeEstimateSamples = hostSamples.load(ordering: .relaxed)
        result.outputHostTimeEstimateMisses = hostMisses.load(ordering: .relaxed)
        result.limiterInputOrGuardCallbacks = interventions.load(ordering: .relaxed)
        result.limiterInputOverCeilingCallbacks = inputOverCeiling.load(ordering: .relaxed)
        result.limiterGuardedSamples = guardedSamples.load(ordering: .relaxed)
        result.limiterRenderFailures = renderFailures.load(ordering: .relaxed)
        return result
    }
}
