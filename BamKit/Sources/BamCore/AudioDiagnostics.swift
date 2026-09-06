/// Best-effort independently sampled counters, not an acoustic dropout/latency measurement.
/// Callback statistics reset with each aggregate generation; build counters span engine lifetime.
public struct AudioDiagnostics: Codable, Sendable, Equatable {
    public var generation: Int = 0
    public var isRunning = false
    public var sampleRate: Double = 0
    public var limiterDelayFrames = 0
    /// Successfully processed callbacks with valid output frames; early invalid-buffer exits are excluded.
    public var callbackCount: UInt64 = 0
    public var lastFrames = 0
    public var minFrames = 0
    public var maxFrames = 0
    /// Render work through peak publication; excludes the following diagnostic counter publication.
    public var lastCallbackMilliseconds: Double = 0
    public var meanCallbackMilliseconds: Double = 0
    public var maxCallbackMilliseconds: Double = 0
    public var lastBudgetRatio: Double = 0
    public var meanBudgetRatio: Double = 0
    public var maxBudgetRatio: Double = 0
    public var overBufferBudgetCount: UInt64 = 0
    /// Valid output host timestamps compared with callback completion, only an estimate.
    public var outputHostTimeEstimateSamples: UInt64 = 0
    public var outputHostTimeEstimateMisses: UInt64 = 0
    public var limiterInputOrGuardCallbacks: UInt64 = 0
    public var limiterInputOverCeilingCallbacks: UInt64 = 0
    /// Native limiter guard counter: includes sanitized inputs and guarded output frames.
    public var limiterGuardedSamples: UInt64 = 0
    public var limiterRenderFailures: UInt64 = 0
    public var aggregateBuildAttempts: UInt64 = 0
    public var aggregateBuildSuccesses: UInt64 = 0
    public var aggregateBuildFailures: UInt64 = 0
    public var lastBuildMilliseconds: Double = 0
    public var maxBuildMilliseconds: Double = 0
    public init() {}
}
