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
