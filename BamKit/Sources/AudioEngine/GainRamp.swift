/// Callback-owned finite linear ramp. Targets may change; elapsed time is samples.
struct GainRamp {
    private(set) var current: Float = 0
    private var target: Float = 0
    private var step: Float = 0
    private var remaining = 0
    let length: Int

    init(length: Int) { self.length = max(1, length) }

    var isRamping: Bool { remaining > 0 }

    mutating func setTarget(_ value: Float) {
        let value = value.isFinite ? value : 0
        guard value != target else { return }
        target = value
        remaining = max(1, length)
        step = (target - current) / Float(remaining)
    }

    @inline(__always) mutating func next() -> Float {
        if remaining > 0 {
            remaining -= 1
            current = remaining == 0 ? target : current + step
        }
        return current
    }

    mutating func advance(_ frames: Int) {
        var count = min(frames, remaining)
        while count > 0 { _ = next(); count -= 1 }
    }
}
