import Atomics

/// Lock-free Float cell shared between the IOProc (RT thread) and a non-RT
/// reader/writer. Used for meter level (IOProc writes) and output gain (control
/// writes, IOProc reads). Single value, relaxed ordering — torn reads impossible
/// on aligned 32-bit slots.
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
