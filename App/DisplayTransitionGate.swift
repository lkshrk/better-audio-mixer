import Foundation

/// Merges overlapping display power and mode transitions into one begin/end pair.
@MainActor
final class DisplayTransitionGate {
    enum Reason: Hashable, Sendable {
        case screensAsleep, systemAsleep, locked, reconfiguring
    }

    private var open = Set<Reason>()
    private var endTask: Task<Void, Never>?
    private var active = false
    private let settle: Duration
    private let sleep: @MainActor (Duration) async throws -> Void
    private let onBegin: @MainActor () -> Void
    private let onEnd: @MainActor () -> Void

    init(settle: Duration = .milliseconds(1500),
         sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         onBegin: @escaping @MainActor () -> Void,
         onEnd: @escaping @MainActor () -> Void) {
        self.settle = settle
        self.sleep = sleep
        self.onBegin = onBegin
        self.onEnd = onEnd
    }

    var isActive: Bool { active }

    func begin(_ reason: Reason) {
        endTask?.cancel(); endTask = nil
        open.insert(reason)
        guard !active else { return }
        active = true
        onBegin()
    }

    /// Reconfiguration callbacks arrive in bursts; the end waits for a quiet period so one change yields one end.
    func end(_ reason: Reason) {
        open.remove(reason)
        guard active, open.isEmpty else { return }
        endTask?.cancel()
        endTask = Task { [weak self, settle, sleep] in
            do { try await sleep(settle) } catch { return }
            guard let self, !Task.isCancelled, self.open.isEmpty, self.active else { return }
            self.active = false
            self.endTask = nil
            self.onEnd()
        }
    }
}
