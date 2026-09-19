import Foundation

/// Confirmed HAL writes block on listener semaphores; they run here so the engine actor stays responsive.
enum HardwareExecutor {
    private static let queue = DispatchQueue(label: "me.harke.bam.hardware", qos: .userInitiated)

    static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }
}
