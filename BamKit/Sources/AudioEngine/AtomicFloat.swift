import Atomics

/// Lock-free Float cell shared between the IOProc thread and control/meter code.
final class AtomicFloat: Sendable {
    private let bits: ManagedAtomic<UInt32>

    init(_ initial: Float) {
        bits = ManagedAtomic<UInt32>(initial.bitPattern)
    }

    func store(_ value: Float) {
        bits.store(value.bitPattern, ordering: .relaxed)
    }

    func load() -> Float {
        Float(bitPattern: bits.load(ordering: .relaxed))
    }
}

/// One publication for both channels, so a callback cannot observe half a pan edit.
final class AtomicStereoGain: Sendable {
    private let bits = ManagedAtomic<UInt64>(0)

    func store(left: Float, right: Float) {
        let l = left.isFinite ? left : 0
        let r = right.isFinite ? right : 0
        bits.store(UInt64(l.bitPattern) | (UInt64(r.bitPattern) << 32), ordering: .relaxed)
    }

    func load() -> UInt64 { bits.load(ordering: .relaxed) }
}
