import Foundation

public enum RouterRecoveryEvent: Sendable, Equatable {
    case attempting(reason: String, attempt: Int)
    case paused(reason: String, attempts: Int, window: TimeInterval, cooldown: TimeInterval)
    case recovered
}

public enum RecoveryReason: String, Sendable, Equatable, CaseIterable {
    case aggregateStalled
    case outputFormatDrift
    case tapFormatDrift
    case sourceTapStalled
}

public struct RouterRecoveryPolicy: Sendable, Equatable {
    public var maxAttempts: Int
    public var window: TimeInterval
    public var cooldown: TimeInterval

    private var attempts: [RecoveryReason: [Date]] = [:]
    private var paused: [RecoveryReason: Date] = [:]

    public init(maxAttempts: Int = 3, window: TimeInterval = 120, cooldown: TimeInterval = 300) {
        self.maxAttempts = max(1, maxAttempts)
        self.window = window
        self.cooldown = cooldown
    }

    public mutating func recordAttempt(reason: RecoveryReason, now: Date = Date()) -> RouterRecoveryEvent {
        if let until = paused[reason], now < until {
            return .paused(reason: reason.rawValue, attempts: attempts[reason]?.count ?? 0,
                           window: window, cooldown: cooldown)
        }
        var recent = (attempts[reason] ?? []).filter { now.timeIntervalSince($0) <= window }
        guard recent.count < maxAttempts else {
            attempts[reason] = recent
            paused[reason] = now.addingTimeInterval(cooldown)
            return .paused(reason: reason.rawValue, attempts: recent.count,
                           window: window, cooldown: cooldown)
        }
        recent.append(now)
        attempts[reason] = recent
        paused[reason] = nil
        return .attempting(reason: reason.rawValue, attempt: recent.count)
    }

    public func pausedUntil(for reason: RecoveryReason) -> Date? {
        paused[reason]
    }

    public mutating func reset() {
        attempts.removeAll()
        paused.removeAll()
    }
}
