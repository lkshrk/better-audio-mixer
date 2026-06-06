import Foundation

public enum RouterRecoveryEvent: Sendable, Equatable {
    case attempting(reason: String, attempt: Int)
    case paused(reason: String, attempts: Int, window: TimeInterval, cooldown: TimeInterval)
    case recovered
}

public struct RouterRecoveryPolicy: Sendable, Equatable {
    public var maxAttempts: Int
    public var window: TimeInterval
    public var cooldown: TimeInterval

    private var attempts: [Date] = []
    private var pausedUntil: Date?

    public init(maxAttempts: Int = 3, window: TimeInterval = 120, cooldown: TimeInterval = 300) {
        self.maxAttempts = max(1, maxAttempts)
        self.window = window
        self.cooldown = cooldown
    }

    public mutating func recordAttempt(reason: String, now: Date = Date()) -> RouterRecoveryEvent {
        if let pausedUntil, now < pausedUntil {
            return .paused(reason: reason, attempts: attempts.count, window: window, cooldown: cooldown)
        }

        attempts = attempts.filter { now.timeIntervalSince($0) <= window }
        guard attempts.count < maxAttempts else {
            pausedUntil = now.addingTimeInterval(cooldown)
            return .paused(reason: reason, attempts: attempts.count, window: window, cooldown: cooldown)
        }

        attempts.append(now)
        return .attempting(reason: reason, attempt: attempts.count)
    }

    public mutating func reset() {
        attempts.removeAll()
        pausedUntil = nil
    }
}
